import MultiPrintCore
import PDFKit
import SwiftUI

/// Walks through one job: fronts → put the stack back → backs → collect, batch by batch.
struct JobRunnerView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingAbandon = false
    @State private var confirmingReversed = false
    @State private var orderFixed = false

    var body: some View {
        @Bindable var model = model
        if let job = model.job {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(job)
                    StageTrack(stage: job.stage)
                    stageCard(job)
                    if job.stage != .finished { SheetStrip(job: job) }
                }
                .padding(28)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .sheet(isPresented: $model.showingResume) {
                ResumeSheet(job: job)
            }
            .confirmationDialog("Stop this job?", isPresented: $confirmingAbandon) {
                Button("Stop job", role: .destructive) { model.endJob() }
            } message: {
                Text("MultiPrint will forget where you are. Pages already printed stay printed.")
            }
            .toolbar {
                if job.stage != .finished {
                    ToolbarItem {
                        Button("Stop job", systemImage: "xmark.circle") { confirmingAbandon = true }
                    }
                }
            }
        }
    }

    private func header(_ job: DuplexJob) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.title2.weight(.semibold)).lineLimit(2)
                Text("\(job.profile.name) · \(job.sheets.count) sheets · \(job.binding == .longEdge ? "turn like a book" : "turn like a notepad")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if job.stage != .finished {
                Text(batchLabel(job))
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private func batchLabel(_ job: DuplexJob) -> String {
        if job.batch.isReprint { return "Reprinting damaged sheets" }
        if job.regularBatchCount == 1 { return "One batch" }
        return "Batch \(job.batchIndex + 1) of \(job.regularBatchCount)"
    }

    @ViewBuilder
    private func stageCard(_ job: DuplexJob) -> some View {
        let count = job.pendingSequence.count
        switch job.stage {
        case .fronts where !job.passSent:
            Card {
                stepTitle(1, job.batch.done.isEmpty ? "Load \(count) blank sheet\(count == 1 ? "" : "s")" : "Load paper for the remaining \(count)")
                InstructionRow(symbol: "tray.and.arrow.down", text: "Put exactly **\(count)** blank sheet\(count == 1 ? "" : "s") in the input tray of \(PrintService.displayName(job.profile.queue)). Remove any other paper.")
                if !job.batch.done.isEmpty {
                    InstructionRow(symbol: "hand.raised", text: "Leave the sheets that already printed in the output tray, exactly where they are.", tint: .orange)
                }
                if job.profile.frontsReversed {
                    InstructionRow(symbol: "arrow.up.arrow.down", text: "Fronts go out last-to-first on purpose, so the finished stack lands in reading order.", tint: .secondary)
                }
                PhotoSlotView(profile: .constant(job.profile), slot: .loadPaper, editable: false)
                primary("Print \(count) front\(count == 1 ? "" : "s")", symbol: "printer.fill") { model.sendCurrentPass() }
            }
        case .backs where !job.passSent:
            Card {
                stepTitle(2, job.batch.done.isEmpty ? "Put the stack back in: \(job.profile.reloadMethod.title.lowercased())" : "Reload the sheets that still need a back")
                ReloadAnimation(method: job.profile.reloadMethod)
                    .padding(.horizontal, 30)
                InstructionRow(symbol: job.profile.reloadMethod == .flipOver ? "arrow.left.arrow.right" : "square.stack", text: job.profile.reloadMethod.instruction)
                InstructionRow(symbol: "exclamationmark.triangle", text: "Don't add any paper. Exactly **\(count)** sheet\(count == 1 ? "" : "s") should be in the tray.", tint: .orange)
                if !job.batch.lost.isEmpty {
                    InstructionRow(symbol: "trash", text: "Leave out the \(job.batch.lost.count) damaged sheet(s); they'll be reprinted at the end.", tint: .secondary)
                }
                PhotoSlotView(profile: .constant(job.profile), slot: .reloadStack, editable: false)
                primary("Print \(count) back\(count == 1 ? "" : "s")", symbol: "printer.fill") { model.sendCurrentPass() }
            }
        case .fronts, .backs:
            Card {
                stepTitle(job.stage == .fronts ? 1 : 2, "Printing \(count) \(job.stage == .fronts ? "front" : "back")\(count == 1 ? "" : "s")…")
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Wait until every sheet is out. Don't touch the output tray yet.").foregroundStyle(.secondary)
                }
                if job.stage == .backs {
                    InstructionRow(symbol: "arrow.uturn.down", text: job.profile.turnFinishedStackOver
                        ? "Next: take the stack out and **turn the whole stack over in one go**. Don't reshuffle. Page 1 will be on top."
                        : "Next: take the stack out as it is. Page 1 is on top.")
                }
                HStack {
                    primary("All \(count) came out fine", symbol: "checkmark.circle.fill") { model.passCompleted() }
                    Button {
                        model.showingResume = true
                    } label: {
                        Label("Printer stopped or something went wrong…", systemImage: "exclamationmark.bubble")
                    }
                    .controlSize(.large)
                }
            }
        case .collect:
            collectCard(job)
        case .finished:
            Card {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green)
                    Text("All \(job.sheets.count) sheets are printed").font(.title2.weight(.semibold))
                    Text("Every page is on its own side, in order.").foregroundStyle(.secondary)
                    primary("Done", symbol: "checkmark") { model.endJob() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    private func collectCard(_ job: DuplexJob) -> some View {
        let present = job.batch.presentSheetIDs
        let isLastBatch = job.batchIndex + 1 >= job.batches.count
        return Card {
            stepTitle(3, "Collect the finished stack")
            if job.profile.turnFinishedStackOver {
                InstructionRow(symbol: "arrow.uturn.down", text: "Take the stack out and **turn it over**. Sheet 1 is now on top, front side up.")
            } else {
                InstructionRow(symbol: "hand.raised", text: "Take the stack out as it is. The first sheet is on top, front side up.")
            }
            if job.batch.isReprint {
                ForEach(job.insertionHints(), id: \.sheet.id) { item in
                    InstructionRow(symbol: "arrow.turn.down.right", text: "The sheet with **\(item.sheet.label.lowercased())** \(item.hint).")
                }
            } else {
                if job.batchIndex > 0 {
                    InstructionRow(symbol: "square.stack.3d.down.right", text: "Put it face up **under** the pages you already have.")
                }
                if let first = present.first, let last = present.last {
                    InstructionRow(symbol: "doc.text", text: "This stack runs from \(job.sheet(first).label.lowercased()) to \(job.sheet(last).label.lowercased()).", tint: .secondary)
                }
            }
            PhotoSlotView(profile: .constant(job.profile), slot: .finishedStack, editable: false)
            if orderFixed {
                Label("Fixed for next time. For this stack, reverse the sheets once by hand.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    confirmingReversed = true
                } label: {
                    Label("Order still reversed (last page on top)?", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.link)
                .confirmationDialog("Is the order reversed even after you \(job.profile.turnFinishedStackOver ? "turned the stack over" : "took it out as it is")?", isPresented: $confirmingReversed) {
                    Button("Yes, fix it for next time") {
                        model.fixReversedFinish()
                        orderFixed = true
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(job.profile.turnFinishedStackOver
                         ? "Turn the whole stack over first, without reshuffling. If the last page is still on top, MultiPrint will send the fronts in the opposite order from now on, so the stack comes out in order."
                         : "If the last page is on top, MultiPrint will send the fronts in the opposite order from now on, so the stack comes out in order.")
                }
            }
            if !isLastBatch {
                primary("Next batch", symbol: "arrow.right") { orderFixed = false; model.finishCollect() }
            } else if !job.reprintQueue.isEmpty {
                primary("Reprint \(job.reprintQueue.count) damaged sheet\(job.reprintQueue.count == 1 ? "" : "s")", symbol: "arrow.clockwise") { model.finishCollect() }
            } else {
                primary("Finish", symbol: "checkmark") { model.finishCollect() }
            }
        }
    }

    private func stepTitle(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
            Text(title).font(.title3.weight(.semibold))
        }
    }

    private func primary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }
}

/// Fronts → Backs → Collect progress indicator.
struct StageTrack: View {
    let stage: JobStage

    private let steps: [(JobStage, String, String)] = [
        (.fronts, "Fronts", "doc"),
        (.backs, "Backs", "arrow.triangle.2.circlepath"),
        (.collect, "Collect", "square.stack"),
    ]

    private var currentIndex: Int {
        switch stage {
        case .fronts: return 0
        case .backs: return 1
        case .collect: return 2
        case .finished: return 3
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let state = index < currentIndex ? 2 : (index == currentIndex ? 1 : 0)
                HStack(spacing: 8) {
                    Image(systemName: state == 2 ? "checkmark.circle.fill" : step.2)
                        .foregroundStyle(state == 0 ? Color.secondary : (state == 2 ? Color.green : Color.accentColor))
                    Text(step.1).font(.callout.weight(state == 1 ? .semibold : .regular))
                        .foregroundStyle(state == 0 ? .secondary : .primary)
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(index < currentIndex ? Color.green.opacity(0.6) : Color.secondary.opacity(0.25))
                        .frame(height: 2)
                        .padding(.horizontal, 12)
                }
            }
        }
    }
}

/// Every sheet of the current batch with its status in the current pass.
struct SheetStrip: View {
    let job: DuplexJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sheets in this batch").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(job.batch.sheetIDs, id: \.self) { id in
                        let status = status(id)
                        VStack(spacing: 3) {
                            Text("\(id + 1)").font(.caption.weight(.bold).monospacedDigit())
                            Text(job.sheet(id).label.replacingOccurrences(of: "Pages ", with: "p. ").replacingOccurrences(of: "Page ", with: "p. "))
                                .font(.system(size: 9))
                        }
                        .frame(width: 54, height: 44)
                        .background(status.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(status.color.opacity(0.6)))
                        .help(status.help)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    private func status(_ id: Int) -> (color: Color, help: String) {
        if job.batch.lost.contains(id) { return (.red, "Damaged — will be reprinted at the end") }
        if job.stage == .collect || job.batch.done.contains(id) { return (.green, "Done for this step") }
        if job.stage == .backs { return (.blue, "Front printed, back pending") }
        return (.secondary, "Waiting")
    }
}

// MARK: - Resume after a stop

struct ResumeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let job: DuplexJob
    @State private var outcomes: [Int: RowOutcome] = [:]
    @State private var lastGood: Int = -1
    @State private var stopping = false
    @State private var stopResult: String?

    private var rows: [Int] { job.pendingSequence }
    private var isBacks: Bool { job.stage == .backs }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where did the printer stop?").font(.title2.weight(.semibold))

            // Stopping comes first: the printer may still be pulling paper.
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Still printing? Press **Stop/Cancel (✕)** on the printer. That's the fastest way, because the printer already holds the pages it was sent.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button {
                            stopping = true
                            stopResult = nil
                            Task {
                                stopResult = await model.stopPrinting()
                                stopping = false
                            }
                        } label: {
                            Label("Also cancel from this Mac", systemImage: "xmark.octagon")
                        }
                        .disabled(stopping)
                        if stopping {
                            ProgressView().controlSize(.small)
                            Text("Cancelling on this Mac and on the printer…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let stopResult {
                        Text(stopResult).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(isBacks
                 ? "Check the output tray. Sheets are listed in the order they were sent to the printer."
                 : "Check the output tray. Fronts are listed in the order they were sent to the printer.")
                .foregroundStyle(.secondary)

            Picker("Last sheet that came out correctly", selection: $lastGood) {
                Text("None of them").tag(-1)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, id in
                    Text("#\(index + 1) — \(job.sheet(id).label)").tag(index)
                }
            }
            .onChange(of: lastGood) { _, newValue in
                outcomes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element, $0.offset <= newValue ? .printed : .notPrinted) })
            }

            List {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, id in
                    HStack(spacing: 12) {
                        Text("#\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                        thumb(id)
                        VStack(alignment: .leading) {
                            Text(job.sheet(id).label).font(.callout.weight(.medium))
                            Text(job.page(on: id).map { "This step prints page \($0 + 1)" } ?? "This step prints a blank back")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(get: { outcomes[id] ?? .notPrinted }, set: { outcomes[id] = $0 })) {
                            ForEach(RowOutcome.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 330)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 220)

            Card(padding: 14) {
                if isBacks {
                    InstructionRow(symbol: "1.circle", text: "Leave the sheets that printed fine in the output tray.")
                    InstructionRow(symbol: "2.circle", text: "Throw away sheets marked damaged (they'll be reprinted at the end).")
                    InstructionRow(symbol: "3.circle", text: "Sheets that still need their back go in the input tray, in their original order, placed the same way as before.")
                } else {
                    InstructionRow(symbol: "1.circle", text: "Leave the sheets that printed fine in the output tray.")
                    InstructionRow(symbol: "2.circle", text: "Throw away damaged sheets. Unused blank paper can go back into the input tray.")
                }
            }

            HStack {
                Spacer()
                Button("Back") { dismiss() }
                Button(remainingTitle) {
                    model.applyReport(outcomes)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 780, height: 720)
    }

    private var remainingTitle: String {
        let left = rows.filter { (outcomes[$0] ?? .notPrinted) == .notPrinted }.count
        return left == 0 ? "Continue" : "Continue with \(left) remaining"
    }

    @ViewBuilder
    private func thumb(_ id: Int) -> some View {
        if let page = job.page(on: id), let pdf = model.pdf(for: job), let image = model.thumbnail(pdf, file: job.documentFile, page: page, height: 44) {
            Image(nsImage: image).resizable().scaledToFit().frame(height: 44)
        } else {
            PaperSheet(printed: false).frame(height: 44)
        }
    }
}
