import AppKit
import MultiPrintCore
import Observation
import PDFKit
import UniformTypeIdentifiers

enum AppSection: String, Hashable, CaseIterable {
    case print, printers, setup
}

/// Photos the person can attach to a printer profile, shown at the matching step.
enum PhotoSlot: String, CaseIterable, Identifiable {
    case loadPaper, reloadStack, finishedStack
    var id: String { rawValue }

    var title: String {
        switch self {
        case .loadPaper: return "How to load blank paper"
        case .reloadStack: return "How to put the stack back in"
        case .finishedStack: return "What the finished stack looks like"
        }
    }
}

/// A PDF chosen for printing but not started yet.
struct LoadedDocument: Identifiable {
    let id = UUID()
    let title: String
    let fileName: String
    let pdf: PDFDocument
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var section: AppSection = .print
    var profiles: [PrinterProfile] { didSet { Storage.saveProfiles(profiles) } }
    var job: DuplexJob? { didSet { Storage.saveJob(job) } }
    var document: LoadedDocument?
    var printers: [String] = []
    var errorMessage: String?
    /// Non-nil while the calibration wizard is open; holds the profile being (re)calibrated.
    var calibrating: PrinterProfile?
    var showingResume = false
    /// True while files are being converted.
    var importing = false
    /// Nil when the MultiPrint Duplex printer's server is running; otherwise why it isn't.
    var printerServerProblem: String?
    var lastUsedProfileID: UUID? {
        get { UserDefaults.standard.string(forKey: "lastProfile").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "lastProfile") }
    }

    @ObservationIgnored private let printerServer = ReceiverServer(port: VirtualPrinter.port)
    @ObservationIgnored private var jobPDF: (file: String, pdf: PDFDocument)?
    @ObservationIgnored private var thumbnails: [String: NSImage] = [:]

    private init() {
        profiles = Storage.loadProfiles()
        job = Storage.loadJob()
        refreshPrinters()
        Storage.cleanSpool()
        do {
            try printerServer.start()
        } catch {
            printerServerProblem = "The MultiPrint Duplex printer couldn't start: \(error.localizedDescription)"
        }
        #if DEBUG
        if UserDefaults.standard.integer(forKey: "previewWizardStep") > 0 { beginCalibration() }
        if let section = UserDefaults.standard.string(forKey: "previewSection").flatMap(AppSection.init(rawValue:)) { self.section = section }
        if let path = UserDefaults.standard.string(forKey: "previewDocument") { open([URL(fileURLWithPath: path)]) }
        if let path = UserDefaults.standard.string(forKey: "exportCalibrationPDF") {
            PDFComposer.calibrationDocument().write(to: URL(fileURLWithPath: path))
            exit(0)
        }
        // `-testStop Brother_DCP_T436W` runs the Stop sequence against a queue and prints the result.
        if let queue = UserDefaults.standard.string(forKey: "testStop") {
            Task {
                print(await PrintCanceller.stop(queue: queue).message)
                exit(0)
            }
        }
        // `-installPrinter YES` runs the same code as Setup → Add printer, then quits.
        if UserDefaults.standard.bool(forKey: "installPrinter") {
            do { try VirtualPrinter.install(); print("installed") } catch { print("FAIL \(error.localizedDescription)") }
            exit(0)
        }
        // `-convertTest in.docx -convertOut out.pdf` runs one conversion and quits.
        if let input = UserDefaults.standard.string(forKey: "convertTest"), let output = UserDefaults.standard.string(forKey: "convertOut") {
            Task {
                do {
                    let pdf = try await DocumentConverter.pdf(for: URL(fileURLWithPath: input))
                    pdf.write(to: URL(fileURLWithPath: output))
                    print("OK \(pdf.pageCount) pages")
                } catch {
                    print("FAIL \(error.localizedDescription)")
                }
                exit(0)
            }
        }
        // `-previewJob file.pdf -previewPasses 1` shows the job runner without sending anything.
        if let path = UserDefaults.standard.string(forKey: "previewJob") {
            Task {
                await importDocuments([URL(fileURLWithPath: path)])
                startJob(profile: profiles.first ?? PrinterProfile(name: "Preview", queue: printers.first ?? "", reloadMethod: .flipOver, frontsReversed: true, turnFinishedStackOver: true), pages: Array(0..<(document?.pdf.pageCount ?? 0)), binding: .longEdge, batchSize: UserDefaults.standard.integer(forKey: "previewBatch"))
                for _ in 0..<UserDefaults.standard.integer(forKey: "previewPasses") { job?.passCompleted() }
                if UserDefaults.standard.bool(forKey: "previewSent") { job?.markSent() }
                showingResume = UserDefaults.standard.bool(forKey: "previewResume")
            }
        }
        #endif
    }

    func refreshPrinters() { printers = PrintService.printers() }

    // MARK: - Documents

    /// Opens one or more files of any supported format, converts them, and merges them into one document.
    /// The result is saved in MultiPrint's storage right away: files handed over by the Print dialog are temporary.
    func open(_ urls: [URL]) {
        let urls = urls.filter { DocumentConverter.canOpen($0) || $0.pathExtension.isEmpty }
        guard !urls.isEmpty else {
            errorMessage = "MultiPrint opens PDFs, images, Word, Excel, PowerPoint, OpenDocument, RTF, HTML and text files."
            return
        }
        importing = true
        Task { await importDocuments(urls) }
    }

    private func importDocuments(_ urls: [URL]) async {
        defer { importing = false }
        let merged = PDFDocument()
        var problems: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let pdf = try await DocumentConverter.pdf(for: url)
                for index in 0..<pdf.pageCount {
                    if let page = pdf.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
            } catch {
                problems.append(error.localizedDescription)
            }
            // Jobs from the MultiPrint Duplex printer are copied now; drop the inbox copy.
            if url.path.hasPrefix(Storage.inbox.path) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        if !problems.isEmpty { errorMessage = problems.joined(separator: "\n\n") }
        guard merged.pageCount > 0 else { return }

        let fileName = "\(UUID().uuidString).pdf"
        let destination = Storage.documents.appendingPathComponent(fileName)
        guard merged.write(to: destination), let pdf = PDFDocument(url: destination) else {
            errorMessage = "Couldn't save the document for printing."
            return
        }
        var title = Self.cleanTitle(urls[0].deletingPathExtension().lastPathComponent)
        if urls.count > 1 { title += " + \(urls.count - 1) more" }
        if let document { closeDocumentFile(document) }
        section = .print
        document = LoadedDocument(title: title, fileName: fileName, pdf: pdf)
        NSApp.activate(ignoringOtherApps: true)
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentConverter.contentTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more files. Several files are printed as one document, in the order shown."
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func closeDocument() {
        if let document { closeDocumentFile(document) }
        document = nil
    }

    private func closeDocumentFile(_ document: LoadedDocument) {
        if job?.documentFile != document.fileName {
            try? FileManager.default.removeItem(at: Storage.documents.appendingPathComponent(document.fileName))
        }
    }

    func pdf(for job: DuplexJob) -> PDFDocument? {
        if let jobPDF, jobPDF.file == job.documentFile { return jobPDF.pdf }
        if let document, document.fileName == job.documentFile {
            jobPDF = (job.documentFile, document.pdf)
            return document.pdf
        }
        guard let pdf = PDFDocument(url: Storage.documents.appendingPathComponent(job.documentFile)) else { return nil }
        jobPDF = (job.documentFile, pdf)
        return pdf
    }

    func thumbnail(_ pdf: PDFDocument, file: String, page: Int, height: CGFloat = 150) -> NSImage? {
        let key = "\(file)#\(page)@\(Int(height))"
        if let cached = thumbnails[key] { return cached }
        let image = PDFComposer.thumbnail(pdf, page: page, height: height)
        thumbnails[key] = image
        return image
    }

    // MARK: - Jobs

    func startJob(profile: PrinterProfile, pages: [Int], binding: BindingEdge, batchSize: Int) {
        guard let document else { return }
        lastUsedProfileID = profile.id
        job = DuplexJob(
            title: document.title,
            documentFile: document.fileName,
            pageCount: document.pdf.pageCount,
            pages: pages,
            profile: profile,
            binding: binding,
            batchSize: batchSize
        )
        self.document = nil
    }

    /// Sends what's left of the current pass.
    func sendCurrentPass() {
        guard var job, let pdf = pdf(for: job), let pass = job.currentPass else { return }
        let slots = job.slotsForPending()
        guard !slots.isEmpty else { return }
        let passName = pass == .fronts ? "fronts" : "backs"
        do {
            try PrintService.submit(PDFComposer.compose(slots, from: pdf), queue: job.profile.queue, title: "\(job.title) – \(passName)")
            job.markSent()
            self.job = job
        } catch {
            errorMessage = "The printer didn't accept the job: \(error.localizedDescription)"
        }
    }

    func passCompleted() { job?.passCompleted() }
    func applyReport(_ outcomes: [Int: RowOutcome]) { job?.applyReport(outcomes) }
    func finishCollect() { job?.finishCollect() }

    /// The finished stack came out in reverse order even after following the collect instructions:
    /// flip "send fronts last-to-first" in the saved printer profile, and in this job's remaining batches.
    func fixReversedFinish() {
        guard var job else { return }
        var profile = profiles.first { $0.id == job.profile.id } ?? job.profile
        profile.frontsReversed.toggle()
        save(profile)
        job.updateProfile(profile)
        self.job = job
    }

    /// Cancels what's waiting on this Mac and asks the printer itself to drop this user's jobs.
    func stopPrinting() async -> String {
        guard let job else { return "No job is running." }
        return await PrintCanceller.stop(queue: job.profile.queue).message
    }

    func endJob() {
        if let job { try? FileManager.default.removeItem(at: Storage.documents.appendingPathComponent(job.documentFile)) }
        jobPDF = nil
        job = nil
    }

    // MARK: - Profiles

    func beginCalibration(_ existing: PrinterProfile? = nil) {
        refreshPrinters()
        calibrating = existing ?? PrinterProfile(
            name: PrintService.displayName(PrintService.defaultPrinter() ?? printers.first ?? "My printer"),
            queue: PrintService.defaultPrinter() ?? printers.first ?? ""
        )
    }

    func save(_ profile: PrinterProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    func delete(_ profile: PrinterProfile) {
        for file in profile.photos.values { try? FileManager.default.removeItem(at: Storage.photos.appendingPathComponent(file)) }
        profiles.removeAll { $0.id == profile.id }
    }

    // MARK: - Photos

    func photo(_ slot: PhotoSlot, of profile: PrinterProfile) -> NSImage? {
        guard let file = profile.photos[slot.rawValue] else { return nil }
        return NSImage(contentsOf: Storage.photos.appendingPathComponent(file))
    }

    func attachPhoto(_ url: URL, slot: PhotoSlot, to profile: inout PrinterProfile) {
        let fileName = "\(profile.id.uuidString)-\(slot.rawValue)-\(UUID().uuidString.prefix(6)).\(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)"
        do {
            try FileManager.default.copyItem(at: url, to: Storage.photos.appendingPathComponent(fileName))
            removePhoto(slot, from: &profile)
            profile.photos[slot.rawValue] = fileName
        } catch {
            errorMessage = "Couldn't add the photo: \(error.localizedDescription)"
        }
    }

    func removePhoto(_ slot: PhotoSlot, from profile: inout PrinterProfile) {
        guard let file = profile.photos.removeValue(forKey: slot.rawValue) else { return }
        try? FileManager.default.removeItem(at: Storage.photos.appendingPathComponent(file))
    }

    /// Print dialog spool names look like "Untitled-1 2" or carry the app name; keep them readable.
    private static func cleanTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Document" : trimmed
    }
}
