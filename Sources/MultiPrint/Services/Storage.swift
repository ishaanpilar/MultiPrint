import Foundation
import MultiPrintCore

/// Everything lives in ~/Library/Application Support/MultiPrint.
enum Storage {
    static let root: URL = {
        #if DEBUG
        // `-storageRoot /some/folder` keeps debug runs (screenshots, previews) away from real data.
        if let override = UserDefaults.standard.string(forKey: "storageRoot") {
            return ensure(URL(fileURLWithPath: override, isDirectory: true))
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("MultiPrint", isDirectory: true))
    }()

    /// Copies of the PDFs being printed (the Print dialog's temp file disappears quickly).
    static var documents: URL { ensure(root.appendingPathComponent("Documents", isDirectory: true)) }
    static var photos: URL { ensure(root.appendingPathComponent("Photos", isDirectory: true)) }
    /// Jobs received from the "MultiPrint Duplex" printer, before the app picks them up.
    static var inbox: URL { ensure(root.appendingPathComponent("Inbox", isDirectory: true)) }
    /// Pass PDFs handed to CUPS.
    static var spool: URL { ensure(root.appendingPathComponent("Spool", isDirectory: true)) }

    private static var profilesFile: URL { root.appendingPathComponent("profiles.json") }
    private static var jobFile: URL { root.appendingPathComponent("job.json") }

    static func loadProfiles() -> [PrinterProfile] { load([PrinterProfile].self, from: profilesFile) ?? [] }
    static func saveProfiles(_ profiles: [PrinterProfile]) { save(profiles, to: profilesFile) }

    static func loadJob() -> DuplexJob? { load(DuplexJob.self, from: jobFile) }
    static func saveJob(_ job: DuplexJob?) {
        if let job { save(job, to: jobFile) } else { try? FileManager.default.removeItem(at: jobFile) }
    }

    /// Removes spooled pass PDFs older than a day.
    static func cleanSpool() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in (try? fm.contentsOfDirectory(at: spool, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: url) }
        }
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
