import MultiPrintCore
import SwiftUI

struct PrintersView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var confirmingDelete = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.profiles) { profile in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.body.weight(.medium))
                            Text(PrintService.displayName(profile.queue)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(profile.id)
                    }
                }
                Divider()
                Button {
                    model.beginCalibration()
                } label: {
                    Label("Calibrate a printer…", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .padding(12)
            }
            .frame(width: 250)
            Divider()

            if let index = model.profiles.firstIndex(where: { $0.id == selection }) {
                detail($model.profiles[index])
            } else {
                ContentUnavailableView {
                    Label(model.profiles.isEmpty ? "No printers calibrated" : "Select a printer", systemImage: "printer")
                } description: {
                    Text("A calibration takes two sheets of paper and about two minutes.")
                } actions: {
                    if model.profiles.isEmpty { Button("Calibrate a printer…") { model.beginCalibration() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = selection ?? model.profiles.first?.id }
    }

    private func detail(_ profile: Binding<PrinterProfile>) -> some View {
        Form {
            Section {
                TextField("Name", text: profile.name)
                Picker("Printer", selection: profile.queue) {
                    ForEach(Array(Set(model.printers + [profile.wrappedValue.queue])).sorted(), id: \.self) {
                        Text(PrintService.displayName($0)).tag($0)
                    }
                }
                LabeledContent("Calibrated", value: profile.wrappedValue.calibratedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
            }
            Section {
                Picker("Between passes", selection: profile.reloadMethod) {
                    ForEach(ReloadMethod.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Send backs in reverse order", isOn: profile.backsReversed)
                Toggle("Rotate backs 180°", isOn: profile.backsRotated)
                Toggle("Send fronts last-to-first", isOn: profile.frontsReversed)
                Toggle("Turn the finished stack over", isOn: profile.turnFinishedStackOver)
            } header: {
                Text("Paper handling")
            } footer: {
                Text("These are set by the calibration. Change them by hand only if you know your printer changed; recalibrating is safer.")
            }
            Section("Your photos") {
                ForEach(PhotoSlot.allCases) { slot in
                    PhotoSlotView(profile: profile, slot: slot)
                }
            }
            Section {
                HStack {
                    Button("Recalibrate…") { model.beginCalibration(profile.wrappedValue) }
                    Spacer()
                    Button("Delete printer", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete \(profile.wrappedValue.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                let doomed = profile.wrappedValue
                selection = nil
                model.delete(doomed)
            }
        }
    }
}
