// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MultiPrint",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: sheet planning, calibration solving, job/resume state. No AppKit.
        .target(name: "MultiPrintCore"),
        // The SwiftUI app: PDF composing, CUPS submission, wizard and job UI.
        .executableTarget(name: "MultiPrint", dependencies: ["MultiPrintCore"]),
        .testTarget(name: "MultiPrintCoreTests", dependencies: ["MultiPrintCore"]),
    ]
)
