import Foundation
import MultiPrintCore
import Network

/// A local-only IPP printer, running while MultiPrint is open. CUPS's `ipp` backend sends it the PDF of
/// every job printed to "MultiPrint Duplex". While MultiPrint is closed, CUPS keeps such jobs queued and
/// retries, so they arrive as soon as the app starts.
final class ReceiverServer {
    private let port: UInt16
    private let queue = DispatchQueue(label: "multiprint.receiver")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var nextJobID: Int32 = 1
    private let startDate = Date()

    init(port: UInt16) { self.port = port }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: nothing outside this Mac can send jobs.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let http = HTTPConnection(connection: connection, handler: self.respond(to:body:))
            let id = ObjectIdentifier(http)
            self.connections[id] = http
            http.onClose = { [weak self] in self?.connections[id] = nil }
            http.start(on: self.queue)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                log("Listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        log("Listening on ipp://127.0.0.1:\(port)\(VirtualPrinter.resourcePath)")
    }

    // MARK: - IPP

    private func respond(to head: HTTPRequestHead, body: Data) -> (status: String, contentType: String, body: Data) {
        guard head.method == "POST" else {
            return ("200 OK", "text/plain", Data("MultiPrint virtual printer\n".utf8))
        }
        guard let request = IPP.parse(body) else {
            return ("400 Bad Request", "text/plain", Data())
        }

        switch request.operation {
        case .getPrinterAttributes:
            var response = IPP.ResponseBuilder(to: request, status: .ok)
            addPrinterAttributes(to: &response)
            return ipp(response)

        case .printJob:
            let jobID = nextJobID
            nextJobID += 1
            deliver(request.document, title: request.string("job-name") ?? "Document")
            var response = IPP.ResponseBuilder(to: request, status: .ok)
            addJob(jobID, to: &response)
            return ipp(response)

        case .getJobAttributes:
            var response = IPP.ResponseBuilder(to: request, status: .ok)
            addJob(request.integer("job-id") ?? 1, to: &response)
            return ipp(response)

        case .validateJob, .cancelJob, .getJobs:
            return ipp(IPP.ResponseBuilder(to: request, status: .ok))

        case nil:
            return ipp(IPP.ResponseBuilder(to: request, status: .operationNotSupported))
        }
    }

    private func ipp(_ builder: IPP.ResponseBuilder) -> (status: String, contentType: String, body: Data) {
        var builder = builder
        return ("200 OK", "application/ipp", builder.finish())
    }

    private func addPrinterAttributes(to r: inout IPP.ResponseBuilder) {
        let media = ["iso_a4_210x297mm", "na_letter_8.5x11in", "na_legal_8.5x14in"]
        r.group(.printerGroup)
        r.add(.uri, "printer-uri-supported", ["ipp://127.0.0.1:\(port)\(VirtualPrinter.resourcePath)"])
        r.add(.keyword, "uri-authentication-supported", ["none"])
        r.add(.keyword, "uri-security-supported", ["none"])
        r.add(.name, "printer-name", [VirtualPrinter.displayName])
        r.add(.text, "printer-info", ["Double-sided printing with MultiPrint"])
        r.add(.text, "printer-make-and-model", ["MultiPrint Duplex"])
        r.add(.enumeration, "printer-state", integers: [3]) // idle
        r.add(.keyword, "printer-state-reasons", ["none"])
        r.add("printer-is-accepting-jobs", bool: true)
        r.add(.enumeration, "operations-supported", integers: [0x02, 0x04, 0x08, 0x09, 0x0A, 0x0B])
        r.add(.charset, "charset-configured", ["utf-8"])
        r.add(.charset, "charset-supported", ["utf-8"])
        r.add(.naturalLanguage, "natural-language-configured", ["en"])
        r.add(.naturalLanguage, "generated-natural-language-supported", ["en"])
        r.add(.mimeMediaType, "document-format-default", ["application/pdf"])
        r.add(.mimeMediaType, "document-format-supported", ["application/pdf", "application/octet-stream"])
        r.add(.keyword, "ipp-versions-supported", ["1.1", "2.0"])
        r.add(.keyword, "compression-supported", ["none"])
        r.add(.keyword, "pdl-override-supported", ["attempted"])
        r.add(.integer, "printer-up-time", integers: [Int32(Date().timeIntervalSince(startDate)) + 1])
        r.add(.integer, "queued-job-count", integers: [0])
        r.add("color-supported", bool: true)
        r.add("multiple-document-jobs-supported", bool: false)
        r.add(.keyword, "sides-supported", ["one-sided"])
        r.add(.keyword, "sides-default", ["one-sided"])
        r.add("copies-supported", range: 1...1)
        r.add(.keyword, "media-supported", media)
        r.add(.keyword, "media-default", [VirtualPrinter.usesLetter ? media[1] : media[0]])
    }

    private func addJob(_ id: Int32, to r: inout IPP.ResponseBuilder) {
        r.group(.jobGroup)
        r.add(.integer, "job-id", integers: [id])
        r.add(.uri, "job-uri", ["ipp://127.0.0.1:\(port)/jobs/\(id)"])
        r.add(.enumeration, "job-state", integers: [9]) // completed
        r.add(.keyword, "job-state-reasons", ["job-completed-successfully"])
    }

    // MARK: - Hand-off to the app

    private func deliver(_ document: Data, title: String) {
        guard document.starts(with: Data("%PDF".utf8)) else {
            log("Ignored a job that wasn't a PDF (\(document.count) bytes).")
            return
        }
        let folder = Storage.inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("\(Self.fileName(for: title)).pdf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try document.write(to: file)
        } catch {
            log("Couldn't save the job: \(error)")
            return
        }
        log("Received “\(title)” (\(document.count) bytes)")
        DispatchQueue.main.async { AppModel.shared.open([file]) }
    }

    /// Print job names are often full paths or URLs; keep something short and file-safe.
    static func fileName(for title: String) -> String {
        var name = title.components(separatedBy: "/").last(where: { !$0.isEmpty }) ?? title
        for ext in [".pdf", ".docx", ".doc", ".txt", ".rtf", ".html", ".htm"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        // CUPS prefixes the job number: "47 - Sample Report".
        if let range = name.range(of: #"^\d+ - "#, options: .regularExpression) { name.removeSubrange(range) }
        name = name.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Document" }
        return String(name.prefix(80))
    }
}

private func log(_ message: String) {
    NSLog("[MultiPrint printer] %@", message)
}

/// One keep-alive HTTP connection from CUPS.
final class HTTPConnection {
    typealias Handler = (HTTPRequestHead, Data) -> (status: String, contentType: String, body: Data)

    private let connection: NWConnection
    private let handler: Handler
    private var buffer = Data()
    private var sentContinue = false
    var onClose: (() -> Void)?

    init(connection: NWConnection, handler: @escaping Handler) {
        self.connection = connection
        self.handler = handler
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.onClose?()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.process()
            if isComplete || error != nil {
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }

    private func process() {
        while let head = HTTPRequestHead.parse(buffer) {
            if head.expectsContinue && !sentContinue {
                sentContinue = true
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
            guard let (body, consumed) = head.body(in: buffer) else { return }
            buffer = Data(buffer.dropFirst(consumed))
            sentContinue = false

            let response = handler(head, body)
            var bytes = Data("HTTP/1.1 \(response.status)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\n\r\n".utf8)
            bytes.append(response.body)
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        }
    }
}
