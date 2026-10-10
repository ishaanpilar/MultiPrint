import Foundation

/// Stops a print run as far as software can.
///
/// Cancelling in CUPS alone isn't enough for network printers: CUPS hands the whole job to the printer within
/// seconds, after which the job is gone from the Mac's queue while the printer keeps printing from its memory.
/// So this also asks the printer itself (IPP Cancel-My-Jobs) to drop every job sent from this user account.
enum PrintCanceller {
    enum PrinterAnswer {
        case cancelled
        case nothingToCancel
        case notNetworkPrinter
        case unreachable(String)
    }

    struct Report {
        var cancelledOnMac: Int
        var printer: PrinterAnswer

        var message: String {
            let mac = cancelledOnMac == 0 ? nil : "Removed \(cancelledOnMac) job\(cancelledOnMac == 1 ? "" : "s") waiting on this Mac."
            switch printer {
            case .cancelled:
                return [mac, "The printer accepted the cancel. A sheet already moving through it will still finish."].compactMap { $0 }.joined(separator: " ")
            case .nothingToCancel:
                if let mac { return "\(mac) The printer had nothing else left from you." }
                return "Nothing left to cancel. The printer already finished everything it was sent. If it's still printing, press Stop/Cancel on the printer."
            case .notNetworkPrinter:
                return (mac ?? "Nothing was waiting on this Mac.") + " If the printer is still printing, press Stop/Cancel on the printer."
            case let .unreachable(reason):
                return (mac ?? "Nothing was waiting on this Mac.") + " Couldn't reach the printer to cancel there (\(reason)). Press Stop/Cancel on the printer."
            }
        }
    }

    static func stop(queue: String) async -> Report {
        await Task.detached {
            let waiting = activeJobCount(queue: queue)
            _ = try? PrintService.cancelAll(queue: queue)
            let answer: PrinterAnswer
            switch printerURI(queue: queue) {
            case let .found(uri): answer = cancelMyJobs(at: uri)
            case .notFound: answer = .unreachable("it wasn't found on the network")
            case .notNetwork: answer = .notNetworkPrinter
            }
            return Report(cancelledOnMac: waiting, printer: answer)
        }.value
    }

    // MARK: - Steps

    private static func activeJobCount(queue: String) -> Int {
        let output = (try? shell("/usr/bin/lpstat", ["-o", queue])) ?? ""
        return output.split(separator: "\n").filter { $0.hasPrefix("\(queue)-") }.count
    }

    /// The printer's own ipp(s):// address. CUPS often stores a Bonjour `dnssd://` address instead,
    /// which has to be resolved first.
    private enum Address {
        case found(String)
        case notFound
        case notNetwork
    }

    private static func printerURI(queue: String) -> Address {
        // "device for Brother_DCP_T436W: dnssd://Brother%20DCP-T436W._ipps._tcp.local./?uuid=…"
        guard let line = try? shell("/usr/bin/lpstat", ["-v", queue]),
              let range = line.range(of: ": ")
        else { return .notNetwork }
        let device = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        if device.hasPrefix("ipp://") || device.hasPrefix("ipps://") { return .found(device) }
        guard device.hasPrefix("dnssd://"),
              let host = URLComponents(string: device)?.percentEncodedHost?.removingPercentEncoding
        else { return .notNetwork }

        // "Brother DCP-T436W._ipps._tcp.local."
        for type in ["_ipps._tcp", "_ipp._tcp"] {
            guard let marker = host.range(of: ".\(type)") else { continue }
            let name = String(host[..<marker.lowerBound])
            return resolve(name: name, type: type).map(Address.found) ?? .notFound
        }
        return .notNetwork
    }

    /// Resolves a Bonjour printer with `dns-sd -L`, which prints the host, port and the TXT record's `rp=` path.
    private static func resolve(name: String, type: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-L", name, type, "local"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var text = ""
        let done = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            lock.lock()
            text += chunk
            let complete = text.contains("can be reached at") && text.contains("rp=")
            lock.unlock()
            if complete { done.signal() }
        }
        guard (try? process.run()) != nil else { return nil }
        _ = done.wait(timeout: .now() + 4) // dns-sd never exits on its own
        process.terminate()
        pipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        defer { lock.unlock() }
        // "… can be reached at BRWD8B32FCE1BD5.local.:443 (interface 11)"
        guard let at = text.range(of: "can be reached at ") else { return nil }
        let address = text[at.upperBound...].prefix { $0 != " " && $0 != "\n" }
        let path = text.range(of: "rp=").map { String(text[$0.upperBound...].prefix { $0 != " " && $0 != "\n" }) } ?? "ipp/print"
        return "\(type == "_ipps._tcp" ? "ipps" : "ipp")://\(address)/\(path)"
    }

    private static func cancelMyJobs(at uri: String) -> PrinterAnswer {
        let test = FileManager.default.temporaryDirectory.appendingPathComponent("multiprint-cancel-\(UUID().uuidString).test")
        let script = """
        {
          NAME "Cancel-My-Jobs"
          OPERATION Cancel-My-Jobs
          GROUP operation-attributes-tag
          ATTR charset attributes-charset utf-8
          ATTR naturalLanguage attributes-natural-language en
          ATTR uri printer-uri $uri
          ATTR name requesting-user-name $user
        }
        """
        guard (try? script.write(to: test, atomically: true, encoding: .utf8)) != nil else { return .unreachable("couldn't prepare the request") }
        defer { try? FileManager.default.removeItem(at: test) }

        // ipptool exits non-zero for any status other than successful-ok, so read its output either way.
        let output = (try? shell("/usr/bin/ipptool", ["-T", "8", "-tv", uri, test.path], allowFailure: true)) ?? ""
        guard let line = output.split(separator: "\n").first(where: { $0.contains("status-code =") }) else {
            return .unreachable("no answer")
        }
        if line.contains("successful-ok") { return .cancelled }
        if line.contains("not-possible") || line.contains("not-found") { return .nothingToCancel }
        let status = line.components(separatedBy: "= ").last?.components(separatedBy: " ").first ?? "error"
        return .unreachable(status)
    }

    private static func shell(_ tool: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 && !allowFailure { throw PrintService.Failure(message: text) }
        return text
    }
}
