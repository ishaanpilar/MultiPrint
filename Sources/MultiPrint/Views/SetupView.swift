import AppKit
import SwiftUI

/// Explains and installs the ⌘P integration.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var installed = PrintDialogIntegration.isInstalled
    @State private var printerInstalled = VirtualPrinter.isInstalled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Use MultiPrint from any Print dialog").font(.title2.weight(.semibold))

                Card {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: printerInstalled ? "checkmark.circle.fill" : "printer")
                            .font(.system(size: 30))
                            .foregroundStyle(printerInstalled ? .green : .accentColor)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. The “\(VirtualPrinter.displayName)” printer").font(.headline)
                            Text("Adds a printer called **\(VirtualPrinter.displayName)** to your Mac. It appears in **every** print window, including Chrome's preview, Word's own dialog and the standard macOS dialog. Pick it like any other printer and the document opens here, ready for double-sided printing.")
                                .fixedSize(horizontal: false, vertical: true)
                            Text("It works while MultiPrint is open. Print to it while MultiPrint is closed and the job waits in the queue until you open MultiPrint.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let problem = model.printerServerProblem {
                                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            HStack {
                                if printerInstalled {
                                    Button("Remove printer") { act(VirtualPrinter.uninstall) }
                                } else {
                                    Button("Add printer") { act(VirtualPrinter.install) }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                }

                Card {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: installed ? "checkmark.circle.fill" : "plus.circle")
                            .font(.system(size: 30))
                            .foregroundStyle(installed ? .green : .accentColor)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("2. Also add it to the PDF menu (optional)").font(.headline)
                            Text("Every standard macOS Print dialog has a **PDF ▾** menu in its bottom-left corner. MultiPrint adds **\(PrintDialogIntegration.menuTitle)** to it. Choosing it hands the document, already laid out by the app, straight to MultiPrint.")
                                .fixedSize(horizontal: false, vertical: true)
                            if !PrintDialogIntegration.runningFromAppBundle {
                                Label("Run MultiPrint from MultiPrint.app (scripts/build-app.sh) for this to work.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            HStack {
                                if installed {
                                    Button("Remove from PDF menu") { act(PrintDialogIntegration.uninstall) }
                                } else {
                                    Button("Add to PDF menu") { act(PrintDialogIntegration.install) }
                                        .buttonStyle(.borderedProminent)
                                }
                                Button("Show folder") { PrintDialogIntegration.revealFolder() }
                            }
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("3. Make it one keystroke (optional)").font(.headline)
                        Text("macOS lets you give any menu item a shortcut, including items in the Print dialog's PDF menu.")
                        InstructionRow(symbol: "1.circle", text: "Open **System Settings → Keyboard → Keyboard Shortcuts… → App Shortcuts**.")
                        InstructionRow(symbol: "2.circle", text: "Click **+**, choose **All Applications**, and type the menu title exactly:")
                        HStack {
                            Text(PrintDialogIntegration.menuTitle)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(PrintDialogIntegration.menuTitle, forType: .string)
                            }
                        }
                        .padding(.leading, 28)
                        InstructionRow(symbol: "3.circle", text: "Set the shortcut to **⌘P**. Then **⌘P** opens the Print dialog and pressing **⌘P** again sends the document to MultiPrint.")
                        Button("Open Keyboard settings") { PrintDialogIntegration.openKeyboardShortcutSettings() }
                            .padding(.top, 4)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Where to find it").font(.headline)
                        appRow("Any app", "⌘P → choose **\(VirtualPrinter.displayName)** as the printer → Print.")
                        appRow("Chrome, Edge, Brave, Arc", "In the preview, set **Destination** to \(VirtualPrinter.displayName) (it may be under “See more…”).")
                        appRow("Word, Excel, PowerPoint", "Choose \(VirtualPrinter.displayName) in the **Printer** menu of Office's print window.")
                        appRow("Files", "Drop PDFs, images, Word/Excel/PowerPoint, OpenDocument, RTF, HTML or text files on the MultiPrint window or its Dock icon. Several files become one document.")
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            installed = PrintDialogIntegration.isInstalled
            printerInstalled = VirtualPrinter.isInstalled
        }
    }

    private func appRow(_ apps: String, _ how: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(apps).font(.callout.weight(.semibold))
            Text(.init(how)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func act(_ action: () throws -> Void) {
        do { try action() } catch { model.errorMessage = error.localizedDescription }
        installed = PrintDialogIntegration.isInstalled
        printerInstalled = VirtualPrinter.isInstalled
    }
}
