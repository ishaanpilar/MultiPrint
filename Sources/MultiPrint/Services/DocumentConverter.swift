import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Turns common document formats into a PDF that MultiPrint can split into sheets.
///
/// - PDF: used as is.
/// - Images (JPEG, PNG, HEIC, TIFF, GIF, BMP, WebP): one image per page, fitted to the paper. Multi-page TIFFs give several pages.
/// - Word / Excel / PowerPoint / OpenDocument: LibreOffice in headless mode, for the real layout. Without LibreOffice,
///   Word and OpenDocument text fall back to macOS's own reader (simpler layout); spreadsheets and slides need LibreOffice.
/// - RTF, HTML, plain text, Markdown, CSV: laid out on pages by macOS's text system.
enum DocumentConverter {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
    static let wordExtensions = ["doc", "docx", "odt"]
    static let officeOnlyExtensions = ["xls", "xlsx", "ods", "ppt", "pptx", "odp"]
    static let textExtensions = ["rtf", "rtfd", "html", "htm", "txt", "text", "md", "markdown", "csv"]
    static let iWorkExtensions = ["pages", "numbers", "key"]

    static var supportedExtensions: [String] {
        ["pdf"] + imageExtensions + wordExtensions + officeOnlyExtensions + textExtensions
    }

    static var contentTypes: [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) } + [.image]
    }

    static func canOpen(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased()) || iWorkExtensions.contains(url.pathExtension.lowercased())
    }

    static var libreOffice: URL? {
        let candidates = ["/Applications/LibreOffice.app", "\(NSHomeDirectory())/Applications/LibreOffice.app"]
        return candidates.map { URL(fileURLWithPath: $0).appendingPathComponent("Contents/MacOS/soffice") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @MainActor
    static func pdf(for url: URL) async throws -> PDFDocument {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw Failure(message: "\(url.lastPathComponent) isn't a readable PDF.") }
            if pdf.isLocked { throw Failure(message: "\(url.lastPathComponent) is password-protected. Open it in Preview, unlock it, and print it to MultiPrint Duplex.") }
            return pdf
        case _ where imageExtensions.contains(ext):
            return try images(url)
        case _ where wordExtensions.contains(ext) || officeOnlyExtensions.contains(ext):
            if libreOffice != nil { return try await viaLibreOffice(url) }
            if wordExtensions.contains(ext) { return try paginate(readText(url)) }
            throw Failure(message: "To open \(url.lastPathComponent), install LibreOffice, or open it in its own app and print to “\(VirtualPrinter.displayName)”.")
        case _ where textExtensions.contains(ext):
            return try paginate(readText(url))
        case _ where iWorkExtensions.contains(ext):
            throw Failure(message: "Pages, Numbers and Keynote files can't be read directly. Open \(url.lastPathComponent) and print it to “\(VirtualPrinter.displayName)”.")
        default:
            throw Failure(message: "MultiPrint can't open .\(ext) files. Print it from its app to “\(VirtualPrinter.displayName)” instead.")
        }
    }

    private static var paperSize: CGSize { NSPrintInfo.shared.paperSize }

    // MARK: Images

    private static func images(_ url: URL) throws -> PDFDocument {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure(message: "\(url.lastPathComponent) isn't a readable image.")
        }
        // GIFs are animations: print the first frame only. TIFFs can hold real pages.
        let count = url.pathExtension.lowercased() == "gif" ? 1 : CGImageSourceGetCount(source)
        return try drawPDF(pageCount: count) { index, context in
            // Applies the EXIF orientation, so phone photos come out the right way up.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 8000,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
            let landscape = image.width > image.height
            let page = landscape ? CGSize(width: paperSize.height, height: paperSize.width) : paperSize
            return (page, {
                let area = CGRect(origin: .zero, size: page).insetBy(dx: 24, dy: 24)
                let scale = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                context.draw(image, in: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
            })
        }
    }

    // MARK: Text

    private static func readText(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        let body = NSFont.systemFont(ofSize: 11)
        let mono = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        switch ext {
        case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "docx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "odt": options[.documentType] = NSAttributedString.DocumentType.openDocument
        case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd": options[.documentType] = NSAttributedString.DocumentType.rtfd
        case "html", "htm": options[.documentType] = NSAttributedString.DocumentType.html
        default:
            options[.documentType] = NSAttributedString.DocumentType.plain
            options[.defaultAttributes] = [NSAttributedString.Key.font: ext == "csv" ? mono : body]
        }
        do {
            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } catch {
            throw Failure(message: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Lays text out on pages with 0.75" margins.
    private static func paginate(_ text: NSAttributedString) throws -> PDFDocument {
        let margin: CGFloat = 54
        let textSize = CGSize(width: paperSize.width - 2 * margin, height: paperSize.height - 2 * margin)
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            // Something taller than a page (e.g. a huge image) would never fit; stop instead of looping.
            if layout.glyphRange(for: container).length == 0 && !containers.isEmpty { break }
            containers.append(container)
        } while NSMaxRange(layout.glyphRange(for: containers[containers.count - 1])) < layout.numberOfGlyphs && containers.count < 5000

        return try drawPDF(pageCount: containers.count) { index, context in
            (paperSize, {
                context.translateBy(x: 0, y: paperSize.height)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let range = layout.glyphRange(for: containers[index])
                let origin = CGPoint(x: margin, y: margin)
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
            })
        }
    }

    // MARK: Office via LibreOffice

    private static func viaLibreOffice(_ url: URL) async throws -> PDFDocument {
        guard let soffice = libreOffice else { throw Failure(message: "LibreOffice isn't installed.") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("multiprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let process = Process()
        process.executableURL = soffice
        process.arguments = [
            // A private profile so this works even while LibreOffice is open.
            "-env:UserInstallation=file://\(work.path)/profile",
            "--headless", "--norestore", "--convert-to", "pdf", "--outdir", work.path, url.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
        let output = work.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
        guard let data = try? Data(contentsOf: output), let pdf = PDFDocument(data: data) else {
            throw Failure(message: "LibreOffice couldn't convert \(url.lastPathComponent). Try opening it in its own app and printing to “\(VirtualPrinter.displayName)”.")
        }
        return pdf
    }

    // MARK: PDF drawing

    /// Draws pages into a PDF. `page` returns the page size and a drawing closure (nil skips the page).
    private static func drawPDF(pageCount: Int, page: (Int, CGContext) -> (CGSize, () -> Void)?) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw Failure(message: "Couldn't create a PDF.") }

        for index in 0..<pageCount {
            guard let (size, draw) = page(index, context) else { continue }
            var box = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            context.saveGState()
            draw()
            context.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        guard let pdf = PDFDocument(data: data as Data), pdf.pageCount > 0 else { throw Failure(message: "Nothing to print in this file.") }
        return pdf
    }
}
