import MultiPrintCore
import PDFKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                Label("Print", systemImage: "printer.fill").tag(AppSection.print)
                Label("Printers", systemImage: "slider.horizontal.3").tag(AppSection.printers)
                Label("Print Dialog Setup", systemImage: "command").tag(AppSection.setup)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch model.section {
            case .print: PrintView()
            case .printers: PrintersView()
            case .setup: SetupView()
            }
        }
        .sheet(item: $model.calibrating) { profile in
            CalibrationWizard(profile: profile)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct PrintView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.job != nil {
                JobRunnerView()
            } else if let document = model.document {
                JobSetupView(document: document)
            } else {
                DropZoneView()
            }
        }
        .overlay {
            if model.importing {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Preparing the document…").foregroundStyle(.secondary)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

// MARK: - Empty state

struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            HStack(spacing: -18) {
                PaperSheet(label: "1", caption: "FRONT").frame(height: 120).rotationEffect(.degrees(-8))
                PaperSheet(label: "2", caption: "BACK", dashed: true).frame(height: 120).rotationEffect(.degrees(7)).offset(y: 6)
            }
            Text("Double-sided printing without the guesswork")
                .font(.title.weight(.semibold))
            Text("Drop files here (PDF, Word, Excel, PowerPoint, images, text…), or print from any app to **\(VirtualPrinter.displayName)**.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack {
                Button("Open Files…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                    .buttonStyle(.borderedProminent)
                if model.profiles.isEmpty {
                    Button("Calibrate a printer first") { model.beginCalibration() }
                }
            }
            .controlSize(.large)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(16)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            model.open(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - Job setup

struct JobSetupView: View {
    @Environment(AppModel.self) private var model
    let document: LoadedDocument

    @State private var profileID: UUID?
    @State private var allPages = true
    @State private var firstPage = 1
    @State private var lastPage = 1
    @State private var binding: BindingEdge = .longEdge
    @State private var useBatches = false
    @State private var batchSize = 10

    private var pageCount: Int { document.pdf.pageCount }
    private var pages: [Int] {
        allPages ? Array(0..<pageCount) : Array((max(1, firstPage) - 1)..<min(pageCount, max(firstPage, lastPage)))
    }
    private var sheets: [SheetSpec] { DuplexPlanner.sheets(for: pages) }
    private var profile: PrinterProfile? { model.profiles.first { $0.id == profileID } }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(document.title).font(.title2.weight(.semibold)).lineLimit(2)
                    Text("\(pageCount) page\(pageCount == 1 ? "" : "s") → \(sheets.count) sheet\(sheets.count == 1 ? "" : "s") of paper").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 24)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 18)], spacing: 18) {
                    ForEach(sheets) { sheet in
                        SheetPreview(pdf: document.pdf, file: document.fileName, sheet: sheet, sheetNumber: sheet.id + 1)
                    }
                }
                .padding(24)
            }
            Divider()
            settings
                .frame(width: 320)
        }
        .onAppear {
            profileID = model.lastUsedProfileID.flatMap { id in model.profiles.first { $0.id == id }?.id } ?? model.profiles.first?.id
            lastPage = pageCount
        }
    }

    private var settings: some View {
        Form {
            Section("Printer") {
                if model.profiles.isEmpty {
                    Text("No calibrated printer yet. It takes two sheets of paper and about two minutes.")
                        .foregroundStyle(.secondary)
                    Button("Calibrate a printer…") { model.beginCalibration() }
                } else {
                    Picker("Profile", selection: $profileID) {
                        ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if let profile {
                        LabeledContent("Between passes", value: profile.reloadMethod.title)
                    }
                }
            }
            Section("Pages") {
                Toggle("All pages", isOn: $allPages)
                if !allPages {
                    Stepper("From page \(firstPage)", value: $firstPage, in: 1...pageCount)
                    Stepper("To page \(lastPage)", value: $lastPage, in: firstPage...pageCount)
                }
                Picker("Turn pages on", selection: $binding) {
                    ForEach(BindingEdge.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Print in batches", isOn: $useBatches)
                if useBatches {
                    Stepper("\(batchSize) sheets per batch", value: $batchSize, in: 2...100)
                }
            } header: {
                Text("Batches")
            } footer: {
                Text("Smaller stacks feed more reliably and limit the damage if something jams.")
            }
            Section {
                Button {
                    if let profile { model.startJob(profile: profile, pages: pages, binding: binding, batchSize: useBatches ? batchSize : 0) }
                } label: {
                    Label("Start printing \(sheets.count) sheets", systemImage: "printer.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(profile == nil || sheets.isEmpty)
                Button("Close document", role: .cancel) { model.closeDocument() }
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }
}

/// Front and back of one sheet, side by side.
struct SheetPreview: View {
    @Environment(AppModel.self) private var model
    let pdf: PDFDocument
    let file: String
    let sheet: SheetSpec
    let sheetNumber: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                face(sheet.front, caption: "front")
                if let back = sheet.back {
                    face(back, caption: "back")
                } else {
                    VStack(spacing: 4) {
                        PaperSheet(printed: false).frame(height: 110)
                        Text("blank").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Sheet \(sheetNumber)").font(.caption.weight(.semibold))
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func face(_ page: Int, caption: String) -> some View {
        VStack(spacing: 4) {
            if let image = model.thumbnail(pdf, file: file, page: page, height: 110) {
                Image(nsImage: image).resizable().scaledToFit().frame(height: 110)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            Text("p. \(page + 1) · \(caption)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
