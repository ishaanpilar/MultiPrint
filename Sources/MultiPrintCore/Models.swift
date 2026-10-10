import Foundation

/// What the person physically does with the printed stack between the fronts pass and the backs pass.
/// Only two choices matter: whether the stack is turned over or not. Everything else (order, rotation)
/// is compensated in software by the calibrated profile.
public enum ReloadMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepAsIs
    case flipOver

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keepAsIs: return "Keep it as it is"
        case .flipOver: return "Turn the stack over"
        }
    }

    public var instruction: String {
        switch self {
        case .keepAsIs:
            return "Lift the whole stack out of the output tray and put it in the input tray exactly as it is. Don't turn it over, don't spin it, don't reorder anything."
        case .flipOver:
            return "Lift the whole stack out of the output tray, turn it over like turning a page in a book, and put it in the input tray. Don't spin it or reorder anything."
        }
    }

    public var other: ReloadMethod { self == .keepAsIs ? .flipOver : .keepAsIs }
}

/// How the finished sheets are meant to be turned when reading.
public enum BindingEdge: String, Codable, CaseIterable, Identifiable, Sendable {
    case longEdge
    case shortEdge

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .longEdge: return "Long edge (book)"
        case .shortEdge: return "Short edge (notepad)"
        }
    }
}

/// Calibrated behaviour of one printer + one reload habit.
///
/// Every flag is expressed relative to the order in which MultiPrint *sends* pages, so whatever the
/// driver or the paper path does (reverse output, face-up/face-down trays, U-turn paths) is captured
/// empirically by the calibration test instead of being modelled.
public struct PrinterProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// CUPS queue name, as listed by `lpstat -e`.
    public var queue: String
    public var reloadMethod: ReloadMethod
    /// The k-th back sent lands on the sheet whose front was sent (n+1-k)-th.
    public var backsReversed: Bool
    /// Backs must be rotated 180° to read upright when the sheet is turned like a book page.
    public var backsRotated: Bool
    /// Send fronts last-to-first so the finished stack comes out in reading order.
    public var frontsReversed: Bool
    /// The finished stack shows a back on top, so it has to be turned over to read it.
    public var turnFinishedStackOver: Bool
    public var calibratedAt: Date?
    /// PhotoSlot raw value -> file name of a photo the person attached.
    public var photos: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        queue: String,
        reloadMethod: ReloadMethod = .keepAsIs,
        backsReversed: Bool = false,
        backsRotated: Bool = false,
        frontsReversed: Bool = false,
        turnFinishedStackOver: Bool = false,
        calibratedAt: Date? = nil,
        photos: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.queue = queue
        self.reloadMethod = reloadMethod
        self.backsReversed = backsReversed
        self.backsRotated = backsRotated
        self.frontsReversed = frontsReversed
        self.turnFinishedStackOver = turnFinishedStackOver
        self.calibratedAt = calibratedAt
        self.photos = photos
    }
}

/// One physical sheet of the finished document. Page numbers are 0-based indices into the source PDF.
public struct SheetSpec: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let front: Int
    public let back: Int?

    public init(id: Int, front: Int, back: Int?) {
        self.id = id
        self.front = front
        self.back = back
    }

    /// "Pages 3–4" or "Page 5" (1-based, for people).
    public var label: String {
        if let back { return "Pages \(front + 1)–\(back + 1)" }
        return "Page \(front + 1)"
    }
}

/// One page of a pass PDF that gets sent to the printer.
public enum Slot: Codable, Hashable, Sendable {
    case page(Int, rotated: Bool)
    /// A blank back, sized like the given source page, so sheets stay aligned when the page count is odd.
    case blank(sizedLike: Int)
}

public enum PassKind: String, Codable, Sendable {
    case fronts
    case backs
}
