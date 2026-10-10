import XCTest
@testable import MultiPrintCore

final class IPPTests: XCTestCase {
    /// A Print-Job request as CUPS's ipp backend would send it.
    private func printJobRequest(document: Data) -> Data {
        var data = Data([0x02, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x07, 0x01])
        func attribute(_ tag: UInt8, _ name: String, _ value: Data) {
            data.append(tag)
            data.append(contentsOf: [UInt8(name.utf8.count >> 8), UInt8(name.utf8.count & 0xFF)])
            data.append(Data(name.utf8))
            data.append(contentsOf: [UInt8(value.count >> 8), UInt8(value.count & 0xFF)])
            data.append(value)
        }
        attribute(0x47, "attributes-charset", Data("utf-8".utf8))
        attribute(0x48, "attributes-natural-language", Data("en".utf8))
        attribute(0x45, "printer-uri", Data("ipp://127.0.0.1:8631/ipp/print".utf8))
        attribute(0x42, "job-name", Data("Quarterly report.docx".utf8))
        attribute(0x21, "job-id", Data([0, 0, 0, 42]))
        data.append(0x02) // job group, ignored
        attribute(0x21, "copies", Data([0, 0, 0, 1]))
        data.append(0x03)
        data.append(document)
        return data
    }

    func testParsesPrintJobAndDocument() throws {
        let pdf = Data("%PDF-1.7 fake".utf8)
        let request = try XCTUnwrap(IPP.parse(printJobRequest(document: pdf)))
        XCTAssertEqual(request.operation, .printJob)
        XCTAssertEqual(request.requestID, 7)
        XCTAssertEqual(request.string("job-name"), "Quarterly report.docx")
        XCTAssertEqual(request.integer("job-id"), 42)
        XCTAssertNil(request.operationAttributes["copies"], "job-group attributes must not leak into operation attributes")
        XCTAssertEqual(request.document, pdf)
    }

    func testTruncatedRequestIsRejected() {
        let full = printJobRequest(document: Data())
        XCTAssertNil(IPP.parse(full.prefix(30)))
    }

    func testResponseRoundTrips() throws {
        let request = try XCTUnwrap(IPP.parse(printJobRequest(document: Data())))
        var builder = IPP.ResponseBuilder(to: request, status: .ok)
        builder.group(.jobGroup)
        builder.add(.integer, "job-id", integers: [3])
        builder.add(.keyword, "job-state-reasons", ["a", "b"])
        let response = builder.finish()
        XCTAssertEqual(Array(response.prefix(8)), [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07])
        // Re-parse with our own parser: the operation group must carry the charset.
        let parsed = try XCTUnwrap(IPP.parse(response))
        XCTAssertEqual(parsed.string("attributes-charset"), "utf-8")
    }

    func testChunkedBodyWithExpectContinue() throws {
        let body = printJobRequest(document: Data(repeating: 0x41, count: 5000))
        var raw = Data("POST /ipp/print HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/ipp\r\nExpect: 100-continue\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        var offset = 0
        while offset < body.count {
            let size = min(1024, body.count - offset)
            raw.append(Data((String(size, radix: 16) + "\r\n").utf8))
            raw.append(body[offset..<(offset + size)])
            raw.append(Data("\r\n".utf8))
            offset += size
        }
        raw.append(Data("0\r\n\r\n".utf8))
        raw.append(Data("GET / HTTP/1.1\r\n\r\n".utf8)) // next request on the same keep-alive connection

        let head = try XCTUnwrap(HTTPRequestHead.parse(raw))
        XCTAssertTrue(head.expectsContinue)
        XCTAssertTrue(head.isChunked)
        XCTAssertNil(head.body(in: raw.prefix(raw.count - 40)), "incomplete chunked body needs more data")
        let (decoded, consumed) = try XCTUnwrap(head.body(in: raw))
        XCTAssertEqual(decoded, body)
        XCTAssertEqual(HTTPRequestHead.parse(Data(raw.dropFirst(consumed)))?.method, "GET")
    }

    func testContentLengthBody() throws {
        let raw = Data("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcdEXTRA".utf8)
        let head = try XCTUnwrap(HTTPRequestHead.parse(raw))
        let (body, consumed) = try XCTUnwrap(head.body(in: raw))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "abcd")
        XCTAssertEqual(consumed, raw.count - 5)
    }
}
