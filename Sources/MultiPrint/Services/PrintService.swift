import Foundation
import PDFKit

/// Talks to CUPS through its command-line tools. Each pass is sent as one plain one-sided job
/// with no page-set / reverse options: MultiPrint decides the exact page order itself, so the
/// printer driver has nothing left to "help" with.
enum PrintService {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Real printers MultiPrint can print to (its own virtual printer is left out).
    static func printers() -> [String] {
        queues().filter { $0 != VirtualPrinter.queueName }
    }

    /// Every CUPS queue on this Mac.
    static func queues() -> [String] {
        let output = (try? run("/usr/bin/lpstat", ["-e"])) ?? ""
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Adds or removes printers. Admin users can do this without a password on macOS.
    static func admin(_ arguments: [String]) throws {
        try run("/usr/sbin/lpadmin", arguments)
    }

    static func defaultPrinter() -> String? {
        // "system default destination: Brother_DCP_T436W"
        guard let output = try? run("/usr/bin/lpstat", ["-d"]), let colon = output.firstIndex(of: ":") else { return nil }
        let name = output[output.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func displayName(_ queue: String) -> String { queue.replacingOccurrences(of: "_", with: " ") }

    /// Writes the pass to the spool folder and submits it. Returns lp's "request id is …" line.
    @discardableResult
    static func submit(_ document: PDFDocument, queue: String, title: String) throws -> String {
        let url = Storage.spool.appendingPathComponent("\(UUID().uuidString).pdf")
        guard document.write(to: url) else { throw Failure(message: "Couldn't write the pages to send to the printer.") }
        return try run("/usr/bin/lp", [
            "-d", queue,
            "-t", title,
            "-o", "sides=one-sided",
            "-o", "outputorder=normal",
            url.path,
        ])
    }

    /// Cancels everything still queued for the printer (after a jam, so it stops printing shifted pages).
    static func cancelAll(queue: String) throws {
        try run("/usr/bin/cancel", ["-a", queue])
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure(message: text.isEmpty ? "\(tool) failed (\(process.terminationStatus))." : text)
        }
        return text
    }
}
