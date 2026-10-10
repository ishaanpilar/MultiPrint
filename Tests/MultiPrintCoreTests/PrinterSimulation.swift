import MultiPrintCore

/// A physical simplex printer, reduced to the behaviours that matter for manual duplex.
/// Every combination is plausible for some real printer/driver; calibration must cope with all of them.
struct SimPrinter: CustomStringConvertible {
    var printsOnUpFace: Bool          // prints the face that is up in the input tray
    var outputPrintedFaceUp: Bool     // printed face lands facing up in the output tray
    var outputLeadingEdgeFar: Bool    // where the edge that fed first ends up in the output tray
    var imageTopAtLeadingEdge: Bool   // page top is printed at the edge that feeds first
    var driverReversesJobs: Bool      // driver prints the last page of a job first

    static var all: [SimPrinter] {
        (0..<32).map { bits in
            SimPrinter(
                printsOnUpFace: bits & 1 != 0,
                outputPrintedFaceUp: bits & 2 != 0,
                outputLeadingEdgeFar: bits & 4 != 0,
                imageTopAtLeadingEdge: bits & 8 != 0,
                driverReversesJobs: bits & 16 != 0
            )
        }
    }

    var description: String {
        "printsUp=\(printsOnUpFace) outFaceUp=\(outputPrintedFaceUp) leadFar=\(outputLeadingEdgeFar) topLeading=\(imageTopAtLeadingEdge) driverRev=\(driverReversesJobs)"
    }

    struct Ink: Equatable { var content: String; var topEdge: Int }

    struct Sheet {
        var faces: [Ink?] = [nil, nil]
        var upFace = 0
        var farEdge = 0
        var upInk: Ink? { faces[upFace] }
        var downInk: Ink? { faces[1 - upFace] }
    }

    struct Page { var content: String; var rotated: Bool }

    enum Failure: Error { case overprint, outOfPaper }

    /// Prints `job` from the top of `input` onto `output` (top of stack = index 0).
    func run(_ job: [Page], input: inout [Sheet], output: inout [Sheet]) throws {
        for page in driverReversesJobs ? job.reversed() : job {
            guard !input.isEmpty else { throw Failure.outOfPaper }
            var sheet = input.removeFirst()
            let face = printsOnUpFace ? sheet.upFace : 1 - sheet.upFace
            let leading = sheet.farEdge
            var top = imageTopAtLeadingEdge ? leading : 1 - leading
            if page.rotated { top = 1 - top }
            if !page.content.isEmpty {
                if sheet.faces[face] != nil { throw Failure.overprint }
                sheet.faces[face] = Ink(content: page.content, topEdge: top)
            }
            sheet.upFace = outputPrintedFaceUp ? face : 1 - face
            sheet.farEdge = outputLeadingEdgeFar ? leading : 1 - leading
            output.insert(sheet, at: 0)
        }
    }

    static func reload(_ stack: [Sheet], _ method: ReloadMethod) -> [Sheet] {
        switch method {
        case .keepAsIs:
            return stack
        case .flipOver:
            return stack.reversed().map { var s = $0; s.upFace = 1 - s.upFace; return s }
        }
    }

    static func turnOver(_ stack: [Sheet]) -> [Sheet] { reload(stack, .flipOver) }

    static func blankPaper(_ count: Int) -> [Sheet] { Array(repeating: Sheet(), count: count) }

    static func pages(_ slots: [Slot], naming: (Int) -> String) -> [Page] {
        slots.map {
            switch $0 {
            case let .page(index, rotated): return Page(content: naming(index), rotated: rotated)
            case .blank: return Page(content: "", rotated: false)
            }
        }
    }

    /// Runs the calibration wizard against this printer the way a person would, answering by looking at the paper.
    /// Tries the person's first choice of reload method, then the other one if the backs hit the printed side.
    func calibrate(firstTry: ReloadMethod = .keepAsIs) -> PrinterProfile? {
        let names = ["A-front", "A-back", "B-front", "B-back"]
        for method in [firstTry, firstTry.other] {
            let test = Calibration.testProfile(queue: "sim", method: method)
            let sheets = Calibration.testSheets
            let fronts = DuplexPlanner.frontsSequence(sheets.map(\.id), profile: test)
            let backs = DuplexPlanner.backsSequence(frontsSent: fronts, profile: test)

            var input = SimPrinter.blankPaper(2), output: [Sheet] = []
            try? run(SimPrinter.pages(DuplexPlanner.slots(for: .fronts, sequence: fronts, sheets: sheets, profile: test, binding: .longEdge)) { names[$0] }, input: &input, output: &output)
            input = SimPrinter.reload(output, method)
            output = []
            do {
                try run(SimPrinter.pages(DuplexPlanner.slots(for: .backs, sequence: backs, sheets: sheets, profile: test, binding: .longEdge)) { names[$0] }, input: &input, output: &output)
            } catch {
                continue // backs printed over the fronts: "No, same side" -> try the other method
            }

            let stackTop: StackTop
            switch output[0].upInk?.content {
            case "A-front": stackTop = .frontA
            case "A-back": stackTop = .backA
            case "B-front": stackTop = .frontB
            default: stackTop = .backB
            }
            let sheetA = output.first { $0.faces.contains { $0?.content == "A-front" } }!
            let frontA = sheetA.faces.first { $0?.content == "A-front" }!!
            let backOnA = sheetA.faces.first { $0?.content.hasSuffix("back") == true }!!
            let answers = CalibrationAnswers(
                backOnBlankSide: true,
                stackTop: stackTop,
                backOnSheetA: backOnA.content.hasPrefix("A") ? .a : .b,
                backArrowUp: backOnA.topEdge == frontA.topEdge // turned like a book page, the top edge stays on top
            )
            var profile = PrinterProfile(name: "Sim", queue: "sim", reloadMethod: method)
            Calibration.apply(answers, to: &profile)
            return profile
        }
        return nil
    }
}
