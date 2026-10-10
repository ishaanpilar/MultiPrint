import Foundation

/// Turns a list of pages into sheets and into the exact page sequences sent in each pass.
public enum DuplexPlanner {
    /// Pairs pages into sheets: (1,2), (3,4), … with a missing back on the last sheet when the count is odd.
    public static func sheets(for pages: [Int]) -> [SheetSpec] {
        stride(from: 0, to: pages.count, by: 2).enumerated().map { number, i in
            SheetSpec(id: number, front: pages[i], back: i + 1 < pages.count ? pages[i + 1] : nil)
        }
    }

    /// Splits sheets into batches of `size` (0 = everything in one batch).
    public static func batches(_ sheetIDs: [Int], size: Int) -> [[Int]] {
        guard !sheetIDs.isEmpty else { return [] }
        guard size > 0, size < sheetIDs.count else { return [sheetIDs] }
        return stride(from: 0, to: sheetIDs.count, by: size).map {
            Array(sheetIDs[$0..<min($0 + size, sheetIDs.count)])
        }
    }

    /// Order in which the fronts of a batch are sent.
    public static func frontsSequence(_ batch: [Int], profile: PrinterProfile) -> [Int] {
        profile.frontsReversed ? batch.reversed() : batch
    }

    /// Order in which the backs are sent, given the sheets whose fronts made it into the stack
    /// (in the order their fronts were sent).
    public static func backsSequence(frontsSent: [Int], profile: PrinterProfile) -> [Int] {
        profile.backsReversed ? frontsSent.reversed() : frontsSent
    }

    public static func backsNeedRotation(_ profile: PrinterProfile, binding: BindingEdge) -> Bool {
        // Turning over the short edge instead of the long edge flips the back by another 180°.
        profile.backsRotated != (binding == .shortEdge)
    }

    public static func slots(
        for pass: PassKind,
        sequence: [Int],
        sheets: [SheetSpec],
        profile: PrinterProfile,
        binding: BindingEdge
    ) -> [Slot] {
        let byID = Dictionary(uniqueKeysWithValues: sheets.map { ($0.id, $0) })
        let rotate = backsNeedRotation(profile, binding: binding)
        return sequence.compactMap { id in
            guard let sheet = byID[id] else { return nil }
            switch pass {
            case .fronts:
                return .page(sheet.front, rotated: false)
            case .backs:
                return sheet.back.map { .page($0, rotated: rotate) } ?? .blank(sizedLike: sheet.front)
            }
        }
    }
}

// MARK: - Calibration

public enum CalibrationSheet: String, CaseIterable, Identifiable, Sendable {
    case a = "A"
    case b = "B"
    public var id: String { rawValue }
}

/// What is visible on top of the finished test stack, without turning it over.
public enum StackTop: String, CaseIterable, Identifiable, Sendable {
    case frontA, backA, frontB, backB
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .frontA: return "A · FRONT"
        case .backA: return "A · BACK"
        case .frontB: return "B · FRONT"
        case .backB: return "B · BACK"
        }
    }
}

/// Answers to the questions asked after the two-sheet test print.
/// The test always sends fronts A, B then backs A, B, unrotated.
public struct CalibrationAnswers: Equatable, Sendable {
    public var backOnBlankSide: Bool
    public var stackTop: StackTop
    /// Which sheet's back ended up on sheet A.
    public var backOnSheetA: CalibrationSheet
    /// With sheet A's front upright, turned like a book page: is the back upright too?
    public var backArrowUp: Bool

    public init(backOnBlankSide: Bool, stackTop: StackTop, backOnSheetA: CalibrationSheet, backArrowUp: Bool) {
        self.backOnBlankSide = backOnBlankSide
        self.stackTop = stackTop
        self.backOnSheetA = backOnSheetA
        self.backArrowUp = backArrowUp
    }
}

public enum Calibration {
    /// Test-pass sheets: sheet 0 = A (pages 0/1), sheet 1 = B (pages 2/3) of the calibration PDF.
    public static let testSheets = DuplexPlanner.sheets(for: [0, 1, 2, 3])

    /// The neutral profile the test is printed with.
    public static func testProfile(queue: String, method: ReloadMethod) -> PrinterProfile {
        PrinterProfile(name: "Calibration", queue: queue, reloadMethod: method)
    }

    /// Fills in the profile from the answers. Returns false when the backs landed on the printed side,
    /// in which case the other reload method must be tried.
    @discardableResult
    public static func apply(_ answers: CalibrationAnswers, to profile: inout PrinterProfile, at date: Date = Date()) -> Bool {
        guard answers.backOnBlankSide else { return false }
        profile.backsReversed = answers.backOnSheetA == .b
        profile.backsRotated = !answers.backArrowUp

        // What's visible on top is a label, not a sheet: when backs are reversed, sheet A carries "B · BACK".
        let showsBack = answers.stackTop == .backA || answers.stackTop == .backB
        let visibleLetter: CalibrationSheet = (answers.stackTop == .frontA || answers.stackTop == .backA) ? .a : .b
        let topSheet: CalibrationSheet = showsBack && profile.backsReversed ? (visibleLetter == .a ? .b : .a) : visibleLetter

        // The finished stack should read A first. Turning a stack over reverses it, so sheet B lying
        // back-up on top is already right once turned.
        profile.frontsReversed = (topSheet == .b) != showsBack
        profile.turnFinishedStackOver = showsBack
        profile.calibratedAt = date
        return true
    }
}
