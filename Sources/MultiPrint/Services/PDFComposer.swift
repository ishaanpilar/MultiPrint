import AppKit
import MultiPrintCore
import PDFKit

enum PDFComposer {
    /// Builds the PDF for one pass: the given pages, in order, rotated where needed, with blank backs.
    static func compose(_ slots: [Slot], from source: PDFDocument) -> PDFDocument {
        let output = PDFDocument()
        for slot in slots {
            let page: PDFPage?
            switch slot {
            case let .page(index, rotated):
                page = source.page(at: index)?.copy() as? PDFPage
                if rotated, let page { page.rotation = (page.rotation + 180) % 360 }
            case let .blank(index):
                page = blankPage(like: source.page(at: index))
            }
            if let page { output.insert(page, at: output.pageCount) }
        }
        return output
    }

    static func blankPage(like reference: PDFPage?) -> PDFPage {
        let page = PDFPage()
        let media = reference?.bounds(for: .mediaBox) ?? CGRect(origin: .zero, size: NSPrintInfo.shared.paperSize)
        page.setBounds(media, for: .mediaBox)
        page.setBounds(reference?.bounds(for: .cropBox) ?? media, for: .cropBox)
        page.rotation = reference?.rotation ?? 0
        return page
    }

    static func thumbnail(_ document: PDFDocument, page index: Int, height: CGFloat) -> NSImage? {
        guard let page = document.page(at: index) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let aspect = rotated ? bounds.height / bounds.width : bounds.width / bounds.height
        return page.thumbnail(of: CGSize(width: height * aspect, height: height), for: .cropBox)
    }

    // MARK: - Calibration test sheets

    /// Four pages: A front, A back, B front, B back — sized to the system's default paper.
    static func calibrationDocument() -> PDFDocument {
        let size = NSPrintInfo.shared.paperSize
        var box = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return PDFDocument() }

        for (letter, isFront) in [("A", true), ("A", false), ("B", true), ("B", false)] {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            drawTestPage(letter: letter, isFront: isFront, size: size)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data) ?? PDFDocument()
    }

    private static func drawTestPage(letter: String, isFront: Bool, size: CGSize) {
        let ink = NSColor.black
        let margin: CGFloat = 36

        // Frame: solid for fronts, dashed for backs, so the two sides are told apart at a glance.
        let frame = NSBezierPath(rect: CGRect(x: margin, y: margin, width: size.width - 2 * margin, height: size.height - 2 * margin))
        frame.lineWidth = 4
        if !isFront { frame.setLineDash([14, 8], count: 2, phase: 0) }
        ink.setStroke()
        frame.stroke()

        // Arrow pointing at the top edge.
        let midX = size.width / 2
        let arrowTop = size.height - margin - 24
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: midX, y: arrowTop))
        arrow.line(to: CGPoint(x: midX - 40, y: arrowTop - 56))
        arrow.line(to: CGPoint(x: midX - 14, y: arrowTop - 56))
        arrow.line(to: CGPoint(x: midX - 14, y: arrowTop - 130))
        arrow.line(to: CGPoint(x: midX + 14, y: arrowTop - 130))
        arrow.line(to: CGPoint(x: midX + 14, y: arrowTop - 56))
        arrow.line(to: CGPoint(x: midX + 40, y: arrowTop - 56))
        arrow.close()
        ink.setFill()
        arrow.fill()

        func centered(_ text: String, size fontSize: CGFloat, weight: NSFont.Weight, y: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: ink,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let width = string.size().width
            string.draw(at: CGPoint(x: (size.width - width) / 2, y: y))
        }

        centered("TOP OF PAGE", size: 20, weight: .semibold, y: arrowTop - 170)
        centered(letter, size: 300, weight: .black, y: size.height * 0.30)
        centered(isFront ? "FRONT" : "BACK", size: 64, weight: .bold, y: size.height * 0.22)
        centered("MultiPrint calibration · sheet \(letter) · \(isFront ? "front" : "back")", size: 12, weight: .regular, y: margin + 16)
    }
}
