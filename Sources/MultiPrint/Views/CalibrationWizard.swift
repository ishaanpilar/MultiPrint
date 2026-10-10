import MultiPrintCore
import PDFKit
import SwiftUI

/// Two blank sheets, two test passes, four questions about what came out → a printer profile.
struct CalibrationWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PrinterProfile
    @State private var step: Step = .setup
    @State private var frontsSent = false
    @State private var backsSent = false
    @State private var blankSide: Bool?
    @State private var stackTop: StackTop?
    @State private var backOnA: CalibrationSheet?
    @State private var arrowUp: Bool?
    @State private var switchedMethod = false

    private let testPDF = PDFComposer.calibrationDocument()

    enum Step: Int, CaseIterable {
        case setup, fronts, reload, backs, inspect, result
        var title: String {
            ["Printer", "Test fronts", "Put back", "Test backs", "Check", "Done"][rawValue]
        }
    }

    init(profile: PrinterProfile) {
        _draft = State(initialValue: profile)
        #if DEBUG
        // `MultiPrint -previewWizardStep 4` opens the wizard on a given step, for checking layouts.
        let previewStep = UserDefaults.standard.integer(forKey: "previewWizardStep")
        if previewStep > 0, let step = Step(rawValue: previewStep) {
            _step = State(initialValue: step)
            _blankSide = State(initialValue: true)
        }
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
            Divider()
            ScrollView {
                content
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 700)
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                VStack(spacing: 6) {
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                    Text(s.title).font(.caption2.weight(s == step ? .semibold : .regular))
                        .foregroundStyle(s == step ? .primary : .secondary)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if step != .setup && step != .result {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .setup }
            }
            switch step {
            case .result where blankSide == true:
                Button("Save printer") {
                    model.save(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            case .result:
                Button("Try again with “\(draft.reloadMethod.other.title)”") { restart(switching: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(16)
    }

    private var canContinue: Bool {
        switch step {
        case .setup: return !draft.queue.isEmpty && !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        case .fronts: return frontsSent
        case .reload: return true
        case .backs: return backsSent
        case .inspect:
            if blankSide == false { return true }
            return blankSide != nil && stackTop != nil && backOnA != nil && arrowUp != nil
        case .result: return false
        }
    }

    private func advance() {
        if step == .inspect {
            if blankSide == true {
                Calibration.apply(CalibrationAnswers(backOnBlankSide: true, stackTop: stackTop!, backOnSheetA: backOnA!, backArrowUp: arrowUp!), to: &draft)
            }
        }
        step = Step(rawValue: step.rawValue + 1) ?? .result
    }

    private func restart(switching: Bool) {
        if switching {
            draft.reloadMethod = draft.reloadMethod.other
            switchedMethod = true
        }
        frontsSent = false
        backsSent = false
        blankSide = nil
        stackTop = nil
        backOnA = nil
        arrowUp = nil
        step = .fronts
    }

    private func send(_ pass: PassKind) {
        let test = Calibration.testProfile(queue: draft.queue, method: draft.reloadMethod)
        let ids = Calibration.testSheets.map(\.id)
        let sequence = pass == .fronts ? ids : DuplexPlanner.backsSequence(frontsSent: ids, profile: test)
        let slots = DuplexPlanner.slots(for: pass, sequence: sequence, sheets: Calibration.testSheets, profile: test, binding: .longEdge)
        do {
            try PrintService.submit(PDFComposer.compose(slots, from: testPDF), queue: draft.queue, title: "MultiPrint calibration – \(pass == .fronts ? "fronts" : "backs")")
            if pass == .fronts { frontsSent = true } else { backsSent = true }
        } catch {
            model.errorMessage = "The printer didn't accept the test page: \(error.localizedDescription)"
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .setup: setup
        case .fronts: fronts
        case .reload: reload
        case .backs: backs
        case .inspect: inspect
        case .result: result
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Teach MultiPrint how your printer handles paper", "You'll print a two-sheet test, put it back in, and answer a few questions about what came out. Have **2 blank sheets** ready.")
            Form {
                TextField("Name", text: $draft.name)
                Picker("Printer", selection: $draft.queue) {
                    if model.printers.isEmpty { Text("No printers found").tag("") }
                    ForEach(model.printers, id: \.self) { Text(PrintService.displayName($0)).tag($0) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 120)

            Text("Between the two passes, how would you like to put the stack back?").font(.headline)
            Text("Pick whatever feels natural. If it's the wrong one for your printer, the test will tell you and switch.")
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(ReloadMethod.allCases) { method in
                    ChoiceCard(title: method.title, subtitle: method == .keepAsIs ? "Same side up, same direction" : "Turned over like a book page", selected: draft.reloadMethod == method) {
                        draft.reloadMethod = method
                    } visual: {
                        ReloadAnimation(method: method).scaleEffect(0.55).frame(height: 92)
                    }
                }
            }
        }
    }

    private var fronts: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Print the test fronts", "Put exactly **2 blank sheets** in the input tray, then print. You'll get a big **A** and a big **B**, each with an arrow pointing to the top of the page.")
            HStack(spacing: 18) {
                PaperSheet(label: "A", caption: "FRONT", arrowUp: true).frame(height: 130)
                PaperSheet(label: "B", caption: "FRONT", arrowUp: true).frame(height: 130)
            }
            .frame(maxWidth: .infinity)
            PhotoSlotView(profile: $draft, slot: .loadPaper)
            HStack {
                Button { send(.fronts) } label: { Label(frontsSent ? "Print again" : "Print test fronts", systemImage: "printer") }
                    .controlSize(.large)
                if frontsSent {
                    Label("Sent. Wait for both sheets, then continue. Don't touch them yet.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var reload: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Put the stack back: \(draft.reloadMethod.title.lowercased())", draft.reloadMethod.instruction)
            if switchedMethod {
                Label("Use 2 fresh blank sheets for the fronts if you haven't already. This attempt uses the other method.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            ReloadAnimation(method: draft.reloadMethod).padding(.horizontal, 60)
            Text("Do it exactly the way you'll do it every time from now on. Add a photo of it so future-you sees the same thing.")
                .foregroundStyle(.secondary)
            PhotoSlotView(profile: $draft, slot: .reloadStack)
        }
    }

    private var backs: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Print the test backs", "With the two sheets back in the input tray, print the backs.")
            HStack(spacing: 18) {
                PaperSheet(label: "A", caption: "BACK", dashed: true, arrowUp: true).frame(height: 130)
                PaperSheet(label: "B", caption: "BACK", dashed: true, arrowUp: true).frame(height: 130)
            }
            .frame(maxWidth: .infinity)
            HStack {
                Button { send(.backs) } label: { Label(backsSent ? "Print again" : "Print test backs", systemImage: "printer") }
                    .controlSize(.large)
                if backsSent {
                    Label("Sent. When both sheets are out, continue without touching the stack.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var inspect: some View {
        VStack(alignment: .leading, spacing: 26) {
            question(1, "Did the backs print on the blank side?") {
                ChoiceCard(title: "Yes, on the blank side", selected: blankSide == true, action: { blankSide = true }) {
                    HStack(spacing: 6) {
                        PaperSheet(label: "A", caption: "FRONT")
                        PaperSheet(label: "A", caption: "BACK", dashed: true)
                    }
                }
                ChoiceCard(title: "No, over the fronts", subtitle: "The printing overlaps, the other side is blank", selected: blankSide == false, action: { blankSide = false }) {
                    PaperSheet(label: "A", caption: "FRONT+BACK")
                        .overlay(Image(systemName: "xmark").font(.title.bold()).foregroundStyle(.red))
                }
            }

            if blankSide == true {
                question(2, "Without touching the stack: what's showing on top?") {
                    ForEach(StackTop.allCases) { top in
                        let isBack = top == .backA || top == .backB
                        ChoiceCard(title: top.title, selected: stackTop == top, action: { stackTop = top }) {
                            PaperSheet(label: top == .frontA || top == .backA ? "A" : "B", caption: isBack ? "BACK" : "FRONT", dashed: isBack)
                        }
                    }
                }

                question(3, "Now pick up the sheet with the big “A FRONT”. What's on its other side?") {
                    ChoiceCard(title: "A BACK", selected: backOnA == .a, action: { backOnA = .a }) {
                        PaperSheet(label: "A", caption: "BACK", dashed: true)
                    }
                    ChoiceCard(title: "B BACK", selected: backOnA == .b, action: { backOnA = .b }) {
                        PaperSheet(label: "B", caption: "BACK", dashed: true)
                    }
                }

                question(4, "Hold that sheet with A FRONT facing you and its arrow pointing up. Turn it over like a page in a book. Which way does the arrow on the back point?") {
                    ChoiceCard(title: "Up", selected: arrowUp == true, action: { arrowUp = true }) {
                        PaperSheet(caption: "BACK", dashed: true, arrowUp: true)
                    }
                    ChoiceCard(title: "Down", subtitle: "The back is upside down", selected: arrowUp == false, action: { arrowUp = false }) {
                        PaperSheet(caption: "BACK", dashed: true, arrowUp: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        if blankSide == true {
            VStack(alignment: .leading, spacing: 18) {
                heading("\(draft.name) is calibrated", "Here's what MultiPrint will handle for you from now on:")
                Card {
                    InstructionRow(symbol: draft.reloadMethod == .flipOver ? "arrow.left.arrow.right" : "square.stack", text: "Between passes you **\(draft.reloadMethod.title.lowercased())**.")
                    InstructionRow(symbol: "arrow.up.arrow.down", text: draft.backsReversed ? "Backs are sent in reverse order to match how the stack feeds back in." : "Backs are sent in the same order as the fronts.")
                    InstructionRow(symbol: "rotate.right", text: draft.backsRotated ? "Backs are rotated 180° so they come out upright." : "Backs need no rotation.")
                    InstructionRow(symbol: "list.number", text: draft.frontsReversed ? "Fronts go out last-to-first so the finished stack is in reading order." : "Fronts go out first-to-last; the finished stack is already in reading order.")
                    InstructionRow(symbol: "arrow.uturn.down", text: draft.turnFinishedStackOver ? "When it's done, turn the finished stack over to read it." : "When it's done, the finished stack is ready to read as it lies.")
                }
                Text("Optional: add a photo of the finished stack, so you can recognise what “done” looks like.")
                    .foregroundStyle(.secondary)
                PhotoSlotView(profile: $draft, slot: .finishedStack)
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                heading("That's useful: your printer needs the other method", "With “\(draft.reloadMethod.title.lowercased())”, the backs land on the printed side. That means you have to **\(draft.reloadMethod.other.title.lowercased())** instead.")
                ReloadAnimation(method: draft.reloadMethod.other).padding(.horizontal, 60)
                Text("Grab 2 fresh blank sheets and run the test once more.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(.init(detail)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func question<Choices: View>(_ number: Int, _ text: String, @ViewBuilder choices: () -> Choices) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)").font(.headline).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(Color.accentColor, in: Circle())
                Text(text).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) { choices() }
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
