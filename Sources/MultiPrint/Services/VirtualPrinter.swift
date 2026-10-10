import Foundation

/// The "MultiPrint Duplex" printer: a regular CUPS queue, so it appears in every app's printer list
/// (system dialog, Chrome's preview, Word's own dialog), pointing at the IPP server MultiPrint runs on loopback.
enum VirtualPrinter {
    static let queueName = "MultiPrint_Duplex"
    static let displayName = "MultiPrint Duplex"
    static let port: UInt16 = 8631
    static let resourcePath = "/ipp/print"

    /// `waitjob=false`: the backend doesn't poll job state after handing over the document.
    static var deviceURI: String { "ipp://127.0.0.1:\(port)\(resourcePath)?waitjob=false" }

    static var usesLetter: Bool {
        ["US", "CA", "MX", "PH", "CL", "CO", "VE"].contains(Locale.current.region?.identifier ?? "")
    }

    static var isInstalled: Bool { PrintService.queues().contains(queueName) }

    static func install() throws {
        let ppd = Storage.root.appendingPathComponent("MultiPrint.ppd")
        try makePPD().write(to: ppd, atomically: true, encoding: .ascii)
        try PrintService.admin([
            "-p", queueName,
            "-D", displayName,
            "-L", "Double-sided printing with MultiPrint",
            "-E",
            "-v", deviceURI,
            "-P", ppd.path,
            "-o", "printer-is-shared=false",
        ])
    }

    static func uninstall() throws {
        try PrintService.admin(["-x", queueName])
    }

    /// A pass-through PDF printer description: CUPS hands the app's PDF straight to the IPP backend.
    static func makePPD() -> String {
        let sizes: [(key: String, name: String, w: Int, h: Int)] = [
            ("A4", "A4", 595, 842),
            ("Letter", "US Letter", 612, 792),
            ("Legal", "US Legal", 612, 1008),
        ]
        let defaultSize = usesLetter ? "Letter" : "A4"
        let margin = 12
        var lines = [
            "*PPD-Adobe: \"4.3\"",
            "*FormatVersion: \"4.3\"",
            "*FileVersion: \"1.0\"",
            "*LanguageVersion: English",
            "*LanguageEncoding: ISOLatin1",
            "*PCFileName: \"MULTIPRT.PPD\"",
            "*Manufacturer: \"MultiPrint\"",
            "*Product: \"(MultiPrint Duplex)\"",
            "*ModelName: \"MultiPrint Duplex\"",
            "*ShortNickName: \"MultiPrint Duplex\"",
            "*NickName: \"MultiPrint Duplex\"",
            "*PSVersion: \"(3010.000) 0\"",
            "*LanguageLevel: \"3\"",
            "*ColorDevice: True",
            "*DefaultColorSpace: RGB",
            "*FileSystem: False",
            "*Throughput: \"1\"",
            "*LandscapeOrientation: Plus90",
            "*TTRasterizer: Type42",
            "*cupsVersion: 2.3",
            "*cupsLanguages: \"en\"",
            "*cupsFilter2: \"application/vnd.cups-pdf application/pdf 0 -\"",
        ]
        for keyword in ["PageSize", "PageRegion"] {
            lines.append("*OpenUI *\(keyword)/Media Size: PickOne")
            lines.append("*OrderDependency: 10 AnySetup *\(keyword)")
            lines.append("*Default\(keyword): \(defaultSize)")
            for s in sizes {
                lines.append("*\(keyword) \(s.key)/\(s.name): \"<</PageSize[\(s.w) \(s.h)]/ImagingBBox null>>setpagedevice\"")
            }
            lines.append("*CloseUI: *\(keyword)")
        }
        lines.append("*DefaultImageableArea: \(defaultSize)")
        for s in sizes { lines.append("*ImageableArea \(s.key)/\(s.name): \"\(margin) \(margin) \(s.w - margin) \(s.h - margin)\"") }
        lines.append("*DefaultPaperDimension: \(defaultSize)")
        for s in sizes { lines.append("*PaperDimension \(s.key)/\(s.name): \"\(s.w) \(s.h)\"") }
        lines.append("*DefaultFont: Courier")
        lines.append("*Font Courier: Standard \"(002.004S)\" Standard ROM")
        return lines.joined(separator: "\n") + "\n"
    }
}
