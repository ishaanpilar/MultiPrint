import Foundation

/// Just enough of the Internet Printing Protocol (RFC 8010/8011) to act as a local virtual printer
/// that CUPS's `ipp` backend can send jobs to.
public enum IPP {
    public enum Operation: UInt16 {
        case printJob = 0x0002
        case validateJob = 0x0004
        case cancelJob = 0x0008
        case getJobAttributes = 0x0009
        case getJobs = 0x000A
        case getPrinterAttributes = 0x000B
    }

    public enum Status: UInt16 {
        case ok = 0x0000
        case badRequest = 0x0400
        case operationNotSupported = 0x0501
    }

    public enum Tag: UInt8 {
        // Delimiters
        case operationGroup = 0x01, jobGroup = 0x02, end = 0x03, printerGroup = 0x04
        // Values
        case integer = 0x21, boolean = 0x22, enumeration = 0x23
        case rangeOfInteger = 0x33
        case text = 0x41, name = 0x42, keyword = 0x44, uri = 0x45
        case charset = 0x47, naturalLanguage = 0x48, mimeMediaType = 0x49
    }

    public struct Request {
        public var versionMajor: UInt8
        public var versionMinor: UInt8
        public var operationID: UInt16
        public var requestID: UInt32
        /// Attributes of the operation group, by name. Values are raw bytes.
        public var operationAttributes: [String: [Data]]
        /// The document that follows the attributes (Print-Job).
        public var document: Data

        public var operation: Operation? { Operation(rawValue: operationID) }

        public func string(_ name: String) -> String? {
            operationAttributes[name]?.first.map { String(decoding: $0, as: UTF8.self) }
        }

        public func integer(_ name: String) -> Int32? {
            guard let raw = operationAttributes[name]?.first, raw.count == 4 else { return nil }
            return raw.withUnsafeBytes { Int32(bigEndian: $0.loadUnaligned(as: Int32.self)) }
        }
    }

    /// Parses a complete IPP request. Returns nil if the message is truncated or malformed.
    public static func parse(_ data: Data) -> Request? {
        let bytes = [UInt8](data)
        guard bytes.count >= 9 else { return nil }
        var index = 8
        var group: UInt8 = 0
        var lastName = ""
        var operationAttributes: [String: [Data]] = [:]

        func read16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }

        while index < bytes.count {
            let tag = bytes[index]
            if tag == Tag.end.rawValue {
                index += 1
                let document = index < bytes.count ? Data(bytes[index...]) : Data()
                return Request(
                    versionMajor: bytes[0],
                    versionMinor: bytes[1],
                    operationID: UInt16(read16(2)),
                    requestID: UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]),
                    operationAttributes: operationAttributes,
                    document: document
                )
            }
            if tag < 0x10 { // another group delimiter
                group = tag
                index += 1
                continue
            }
            guard index + 3 <= bytes.count else { return nil }
            let nameLength = read16(index + 1)
            guard index + 3 + nameLength + 2 <= bytes.count else { return nil }
            let name = String(decoding: bytes[(index + 3)..<(index + 3 + nameLength)], as: UTF8.self)
            let valueStart = index + 3 + nameLength + 2
            let valueLength = read16(index + 3 + nameLength)
            guard valueStart + valueLength <= bytes.count else { return nil }
            let value = Data(bytes[valueStart..<(valueStart + valueLength)])
            if !name.isEmpty { lastName = name }
            if group == Tag.operationGroup.rawValue {
                operationAttributes[lastName, default: []].append(value)
            }
            index = valueStart + valueLength
        }
        return nil
    }

    /// Builds an IPP response message.
    public struct ResponseBuilder {
        public private(set) var data = Data()

        public init(to request: Request, status: Status) {
            data.append(contentsOf: [request.versionMajor, request.versionMinor])
            append16(status.rawValue)
            append32(request.requestID)
            group(.operationGroup)
            add(.charset, "attributes-charset", ["utf-8"])
            add(.naturalLanguage, "attributes-natural-language", ["en"])
        }

        public mutating func group(_ tag: Tag) { data.append(tag.rawValue) }

        public mutating func add(_ tag: Tag, _ name: String, _ values: [String]) {
            addRaw(tag, name, values.map { Data($0.utf8) })
        }

        public mutating func add(_ tag: Tag, _ name: String, integers: [Int32]) {
            addRaw(tag, name, integers.map { withUnsafeBytes(of: $0.bigEndian) { Data($0) } })
        }

        public mutating func add(_ name: String, bool: Bool) {
            addRaw(.boolean, name, [Data([bool ? 1 : 0])])
        }

        public mutating func add(_ name: String, range: ClosedRange<Int32>) {
            var value = Data()
            withUnsafeBytes(of: range.lowerBound.bigEndian) { value.append(contentsOf: $0) }
            withUnsafeBytes(of: range.upperBound.bigEndian) { value.append(contentsOf: $0) }
            addRaw(.rangeOfInteger, name, [value])
        }

        public mutating func finish() -> Data {
            data.append(Tag.end.rawValue)
            return data
        }

        private mutating func addRaw(_ tag: Tag, _ name: String, _ values: [Data]) {
            for (i, value) in values.enumerated() {
                data.append(tag.rawValue)
                let nameBytes = i == 0 ? Data(name.utf8) : Data()
                append16(UInt16(nameBytes.count))
                data.append(nameBytes)
                append16(UInt16(value.count))
                data.append(value)
            }
        }

        private mutating func append16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        private mutating func append32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    }
}

/// Minimal HTTP/1.1 request framing for the IPP endpoint: headers, Content-Length or chunked bodies,
/// and `Expect: 100-continue`.
public struct HTTPRequestHead {
    public var method: String
    public var path: String
    public var headers: [String: String]
    /// Offset of the first body byte in the buffer.
    public var bodyStart: Int

    public var expectsContinue: Bool { headers["expect"]?.lowercased() == "100-continue" }
    public var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") == true }
    public var contentLength: Int { Int(headers["content-length"] ?? "") ?? 0 }

    /// Parses the request line and headers if they're complete.
    public static func parse(_ buffer: Data) -> HTTPRequestHead? {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let text = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequestHead(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, bodyStart: end.upperBound - buffer.startIndex)
    }

    /// Returns the body and the total number of bytes the request occupies, or nil if more data is needed.
    public func body(in buffer: Data) -> (body: Data, consumed: Int)? {
        let bytes = [UInt8](buffer)
        if !isChunked {
            guard bytes.count >= bodyStart + contentLength else { return nil }
            return (Data(bytes[bodyStart..<(bodyStart + contentLength)]), bodyStart + contentLength)
        }
        var body = Data()
        var index = bodyStart
        while true {
            guard let lineEnd = Self.crlf(in: bytes, from: index) else { return nil }
            let sizeText = String(decoding: bytes[index..<lineEnd], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            index = lineEnd + 2
            if size == 0 {
                // Skip optional trailers up to the blank line.
                while true {
                    guard let trailerEnd = Self.crlf(in: bytes, from: index) else { return nil }
                    let isBlank = trailerEnd == index
                    index = trailerEnd + 2
                    if isBlank { return (body, index) }
                }
            }
            guard bytes.count >= index + size + 2 else { return nil }
            body.append(contentsOf: bytes[index..<(index + size)])
            index += size + 2
        }
    }

    private static func crlf(in bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        while i + 1 < bytes.count {
            if bytes[i] == 13 && bytes[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }
}
