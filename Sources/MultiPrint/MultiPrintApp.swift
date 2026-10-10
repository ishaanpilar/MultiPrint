import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Called for Finder "Open With", drops on the Dock icon, and the Print dialog's PDF menu.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MultiPrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("MultiPrint", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 660)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}
