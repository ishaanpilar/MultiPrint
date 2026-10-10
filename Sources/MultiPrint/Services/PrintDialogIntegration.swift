import AppKit

/// Puts MultiPrint in the "PDF" menu of every standard macOS Print dialog.
///
/// macOS lists whatever is in ~/Library/PDF Services in that menu. When the item is an application
/// (or an alias to one), the system renders the document to a PDF and opens it with that app.
enum PrintDialogIntegration {
    static let menuTitle = "Duplex Print with MultiPrint"

    static var servicesFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/PDF Services", isDirectory: true)
    }

    static var itemURL: URL { servicesFolder.appendingPathComponent(menuTitle) }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: itemURL.path)
    }

    /// True when MultiPrint runs from a real .app bundle (required for the alias to work).
    static var runningFromAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: servicesFolder, withIntermediateDirectories: true)
        if isInstalled { try fm.removeItem(at: itemURL) }
        // A Finder alias (not a symlink) keeps working if the app is moved.
        let bookmark = try Bundle.main.bundleURL.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: itemURL)
    }

    static func uninstall() throws {
        if isInstalled { try FileManager.default.removeItem(at: itemURL) }
    }

    static func revealFolder() {
        try? FileManager.default.createDirectory(at: servicesFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(servicesFolder)
    }

    static func openKeyboardShortcutSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
