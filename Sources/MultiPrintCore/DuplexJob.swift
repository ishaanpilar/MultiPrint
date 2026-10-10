import Foundation

public enum JobStage: String, Codable, Sendable {
    case fronts
    case backs
    case collect
    case finished
}

/// What happened to one sheet of the current pass, as reported after the printer stopped.
public enum RowOutcome: String, Codable, CaseIterable, Identifiable, Sendable {
    case printed
    case notPrinted
    case damaged
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .printed: return "Printed fine"
        case .notPrinted: return "Not printed yet"
        case .damaged: return "Damaged / wrong"
        }
    }
}

public struct DuplexBatch: Codable, Hashable, Sendable {
    public var sheetIDs: [Int]
    /// A batch made of sheets that were damaged earlier and are printed again at the end.
    public var isReprint: Bool
    public var frontsSequence: [Int]
    public var backsSequence: [Int] = []
    /// Sheets confirmed printed in the current pass.
    public var done: Set<Int> = []
    /// Sheets taken out of this batch; they go to the reprint queue.
    public var lost: Set<Int> = []

    public var presentSheetIDs: [Int] { sheetIDs.filter { !lost.contains($0) } }
}

/// The full, resumable state of one manual-duplex job. Persisted between launches.
public struct DuplexJob: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// File name of the job's copy of the PDF in MultiPrint's storage.
    public var documentFile: String
    public var pageCount: Int
    /// Snapshot of the profile, so recalibrating mid-job can't change the rules halfway.
    public var profile: PrinterProfile
    public var binding: BindingEdge
    public var sheets: [SheetSpec]
    public var batches: [DuplexBatch]
    public var batchIndex: Int = 0
    public var stage: JobStage = .fronts
    /// True once the current pass (or its remainder) has been sent and we're waiting on paper.
    public var passSent = false
    /// Damaged sheets waiting to be reprinted after the last regular batch.
    public var reprintQueue: [Int] = []

    public init(
        id: UUID = UUID(),
        title: String,
        documentFile: String,
        pageCount: Int,
        pages: [Int],
        profile: PrinterProfile,
        binding: BindingEdge,
        batchSize: Int
    ) {
        self.id = id
        self.title = title
        self.documentFile = documentFile
        self.pageCount = pageCount
        self.profile = profile
        self.binding = binding
        sheets = DuplexPlanner.sheets(for: pages)
        batches = DuplexPlanner.batches(sheets.map(\.id), size: batchSize).map {
            DuplexBatch(sheetIDs: $0, isReprint: false, frontsSequence: DuplexPlanner.frontsSequence($0, profile: profile))
        }
        if batches.isEmpty { stage = .finished }
    }

    public var batch: DuplexBatch {
        get { batches[batchIndex] }
        set { batches[batchIndex] = newValue }
    }

    public var regularBatchCount: Int { batches.filter { !$0.isReprint }.count }

    public func sheet(_ id: Int) -> SheetSpec { sheets[id] }

    public var currentPass: PassKind? {
        switch stage {
        case .fronts: return .fronts
        case .backs: return .backs
        case .collect, .finished: return nil
        }
    }

    public var currentSequence: [Int] {
        switch stage {
        case .fronts: return batch.frontsSequence
        case .backs: return batch.backsSequence
        case .collect, .finished: return []
        }
    }

    /// Sheets of the current pass that still need printing, in send order.
    public var pendingSequence: [Int] {
        currentSequence.filter { !batch.done.contains($0) && !batch.lost.contains($0) }
    }

    public func slotsForPending() -> [Slot] {
        guard let pass = currentPass else { return [] }
        return DuplexPlanner.slots(for: pass, sequence: pendingSequence, sheets: sheets, profile: profile, binding: binding)
    }

    /// The source page printed on `sheetID` in the current pass (nil for a blank back).
    public func page(on sheetID: Int) -> Int? {
        stage == .backs ? sheets[sheetID].back : sheets[sheetID].front
    }

    public mutating func markSent() { passSent = true }

    /// Everything that was sent came out fine.
    public mutating func passCompleted() {
        for id in pendingSequence { batch.done.insert(id) }
        advancePass()
    }

    /// The printer stopped or misbehaved. `outcomes` covers the pending sheets; missing entries mean "not printed".
    ///
    /// Rules that keep the paper stack and the page sequence aligned:
    /// - printed sheets are done;
    /// - damaged sheets leave the batch and are reprinted at the end;
    /// - a "not printed" sheet that comes *before* a printed one can't be slotted back in order,
    ///   so it is also reprinted at the end. Later "not printed" sheets are simply sent again.
    public mutating func applyReport(_ outcomes: [Int: RowOutcome]) {
        let rows = pendingSequence
        let lastPrinted = rows.lastIndex { outcomes[$0] == .printed }
        for (index, id) in rows.enumerated() {
            switch outcomes[id] ?? .notPrinted {
            case .printed:
                batch.done.insert(id)
            case .damaged:
                lose(id)
            case .notPrinted:
                if let lastPrinted, index < lastPrinted { lose(id) }
            }
        }
        passSent = false
        if pendingSequence.isEmpty { advancePass() }
    }

    /// After collecting a finished batch: move to the next batch, the reprint batch, or finish.
    public mutating func finishCollect() {
        passSent = false
        if batchIndex + 1 < batches.count {
            batchIndex += 1
            stage = .fronts
        } else if !reprintQueue.isEmpty {
            let ids = reprintQueue.sorted()
            reprintQueue = []
            batches.append(DuplexBatch(sheetIDs: ids, isReprint: true, frontsSequence: DuplexPlanner.frontsSequence(ids, profile: profile)))
            batchIndex = batches.count - 1
            stage = .fronts
        } else {
            stage = .finished
        }
    }

    /// Applies a corrected profile from now on: batches that haven't started yet get a new fronts order.
    public mutating func updateProfile(_ newProfile: PrinterProfile) {
        profile = newProfile
        for index in batches.indices where index > batchIndex || (index == batchIndex && stage == .fronts && !passSent && batch.done.isEmpty) {
            batches[index].frontsSequence = DuplexPlanner.frontsSequence(batches[index].sheetIDs, profile: newProfile)
        }
    }

    /// Where each reprinted sheet of the current batch belongs in the finished document.
    public func insertionHints() -> [(sheet: SheetSpec, hint: String)] {
        batch.presentSheetIDs.map { id in
            let sheet = sheets[id]
            if id == 0 { return (sheet, "goes on top, as the very first sheet") }
            return (sheet, "goes right after the sheet with \(sheets[id - 1].label.lowercased())")
        }
    }

    private mutating func lose(_ id: Int) {
        guard !batch.lost.contains(id) else { return }
        batch.lost.insert(id)
        reprintQueue.append(id)
    }

    private mutating func advancePass() {
        passSent = false
        switch stage {
        case .fronts:
            let present = batch.frontsSequence.filter { !batch.lost.contains($0) }
            batch.backsSequence = DuplexPlanner.backsSequence(frontsSent: present, profile: profile)
            batch.done = []
            stage = present.isEmpty ? .collect : .backs
        case .backs:
            stage = .collect
        case .collect, .finished:
            break
        }
    }
}
