import XCTest
@testable import MultiPrintCore

final class DuplexTests: XCTestCase {
    func testSheetsPairPagesAndLeaveOddBackEmpty() {
        let sheets = DuplexPlanner.sheets(for: [0, 1, 2, 3, 4])
        XCTAssertEqual(sheets.map(\.front), [0, 2, 4])
        XCTAssertEqual(sheets.map(\.back), [1, 3, nil])
        XCTAssertEqual(sheets[2].label, "Page 5")
    }

    func testBatches() {
        XCTAssertEqual(DuplexPlanner.batches([0, 1, 2, 3, 4], size: 2), [[0, 1], [2, 3], [4]])
        XCTAssertEqual(DuplexPlanner.batches([0, 1, 2], size: 0), [[0, 1, 2]])
        XCTAssertEqual(DuplexPlanner.batches([], size: 3), [])
    }

    func testOddPageCountSendsBlankBackSoSheetsStayAligned() {
        let profile = PrinterProfile(name: "p", queue: "q", backsReversed: true)
        var job = DuplexJob(title: "t", documentFile: "f", pageCount: 3, pages: [0, 1, 2], profile: profile, binding: .longEdge, batchSize: 0)
        job.passCompleted()
        XCTAssertEqual(job.slotsForPending(), [.blank(sizedLike: 2), .page(1, rotated: false)])
    }

    /// The core promise: for every printer behaviour, calibrating with the wizard's questions and then
    /// following the app's instructions yields a correctly ordered, correctly rotated double-sided document.
    func testEveryPrinterBehaviourProducesCorrectDuplexAfterCalibration() throws {
        for printer in SimPrinter.all {
            for firstTry in ReloadMethod.allCases {
                let profile = try XCTUnwrap(printer.calibrate(firstTry: firstTry), "\(printer)")
                for binding in BindingEdge.allCases {
                    for pageCount in 1...7 {
                        for batchSize in [0, 2] {
                            try assertCorrectDuplex(printer, profile, binding, pageCount, batchSize)
                        }
                    }
                }
            }
        }
    }

    func testJamDuringFrontsIsResumedAndDamagedSheetIsReprinted() throws {
        let printer = SimPrinter(printsOnUpFace: false, outputPrintedFaceUp: false, outputLeadingEdgeFar: true, imageTopAtLeadingEdge: true, driverReversesJobs: true)
        let profile = try XCTUnwrap(printer.calibrate())
        var job = DuplexJob(title: "t", documentFile: "f", pageCount: 8, pages: Array(0..<8), profile: profile, binding: .longEdge, batchSize: 0)

        // The printer stops after two fronts and the third sheet is crumpled.
        let rows = job.pendingSequence
        job.applyReport([rows[0]: .printed, rows[1]: .printed, rows[2]: .damaged])
        XCTAssertEqual(job.stage, .fronts)
        XCTAssertEqual(job.pendingSequence, [rows[3]])
        XCTAssertEqual(job.reprintQueue, [rows[2]])

        job.passCompleted() // remaining front prints fine
        XCTAssertEqual(job.stage, .backs)
        XCTAssertEqual(Set(job.pendingSequence), Set(rows).subtracting([rows[2]]))
        job.passCompleted()
        job.finishCollect()
        XCTAssertTrue(job.batch.isReprint)
        XCTAssertEqual(job.batch.sheetIDs, [rows[2]])
    }

    func testNotPrintedBeforeAPrintedSheetIsMovedToReprint() {
        let profile = PrinterProfile(name: "p", queue: "q")
        var job = DuplexJob(title: "t", documentFile: "f", pageCount: 8, pages: Array(0..<8), profile: profile, binding: .longEdge, batchSize: 0)
        job.passCompleted()
        // Double feed during backs: sheet 1 came out without a back, sheet 2 got printed.
        job.applyReport([0: .printed, 1: .notPrinted, 2: .printed])
        XCTAssertEqual(job.pendingSequence, [3])
        XCTAssertEqual(job.reprintQueue, [1])
    }

    func testCorrectingTheProfileReordersOnlyBatchesNotStarted() {
        var profile = PrinterProfile(name: "p", queue: "q")
        var job = DuplexJob(title: "t", documentFile: "f", pageCount: 8, pages: Array(0..<8), profile: profile, binding: .longEdge, batchSize: 2)
        job.passCompleted()
        job.passCompleted()
        XCTAssertEqual(job.stage, .collect)
        profile.frontsReversed = true
        job.updateProfile(profile)
        XCTAssertEqual(job.batches[0].frontsSequence, [0, 1], "the batch already printed keeps its order")
        XCTAssertEqual(job.batches[1].frontsSequence, [3, 2])
    }

    // MARK: - Helpers

    private func assertCorrectDuplex(_ printer: SimPrinter, _ profile: PrinterProfile, _ binding: BindingEdge, _ pageCount: Int, _ batchSize: Int) throws {
        let context = "\(printer) method=\(profile.reloadMethod) binding=\(binding) pages=\(pageCount) batch=\(batchSize)"
        var job = DuplexJob(title: "t", documentFile: "f", pageCount: pageCount, pages: Array(0..<pageCount), profile: profile, binding: binding, batchSize: batchSize)
        let name: (Int) -> String = { "p\($0)" }
        var finished: [SimPrinter.Sheet] = []

        while job.stage != .finished {
            var input = SimPrinter.blankPaper(job.pendingSequence.count), output: [SimPrinter.Sheet] = []
            try printer.run(SimPrinter.pages(job.slotsForPending(), naming: name), input: &input, output: &output)
            job.passCompleted()

            input = SimPrinter.reload(output, profile.reloadMethod)
            output = []
            XCTAssertEqual(job.stage, .backs, context)
            do {
                try printer.run(SimPrinter.pages(job.slotsForPending(), naming: name), input: &input, output: &output)
            } catch {
                return XCTFail("backs failed (\(error)) — \(context)")
            }
            job.passCompleted()
            XCTAssertEqual(job.stage, .collect, context)

            // Collect: turn over if told to, then put it under what we already have.
            finished += profile.turnFinishedStackOver ? SimPrinter.turnOver(output) : output
            job.finishCollect()
        }

        XCTAssertEqual(finished.count, (pageCount + 1) / 2, context)
        for (i, sheet) in finished.enumerated() {
            let front = try XCTUnwrap(sheet.upInk, "sheet \(i) has nothing facing up — \(context)")
            XCTAssertEqual(front.content, name(2 * i), "sheet \(i) front — \(context)")
            guard 2 * i + 1 < pageCount else {
                XCTAssertNil(sheet.downInk, "sheet \(i) should have a blank back — \(context)")
                continue
            }
            let back = try XCTUnwrap(sheet.downInk, "sheet \(i) back missing — \(context)")
            XCTAssertEqual(back.content, name(2 * i + 1), "sheet \(i) back — \(context)")
            // Long edge: turning like a book keeps the top edge on top. Short edge: top becomes bottom.
            let upright = binding == .longEdge ? back.topEdge == front.topEdge : back.topEdge != front.topEdge
            XCTAssertTrue(upright, "sheet \(i) back is upside down — \(context)")
        }
    }
}
