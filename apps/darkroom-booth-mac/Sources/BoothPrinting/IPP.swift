import Foundation

/// Minimal IPP/1.1 binary encoding (RFC 8010) for querying the local CUPS
/// server: printer list, state, state reasons and marker (ribbon/media) levels.
public enum IPP {
    public enum Operation: UInt16 {
        case printJob = 0x0002
        case getPrinterAttributes = 0x000B
        case cupsGetPrinters = 0x4002
    }

    public enum Tag: UInt8 {
        case operationAttributes = 0x01
        case jobAttributes = 0x02
        case end = 0x03
        case printerAttributes = 0x04
        case unsupportedAttributes = 0x05
        case integer = 0x21
        case boolean = 0x22
        case enumValue = 0x23
        case textWithoutLanguage = 0x41
        case nameWithoutLanguage = 0x42
        case keyword = 0x44
        case uri = 0x45
        case charset = 0x47
        case naturalLanguage = 0x48
        case mimeMediaType = 0x49
    }

    public enum Value: Equatable, Sendable {
        case integer(Int32)
        case boolean(Bool)
        case string(String)
        case other(tag: UInt8, bytes: Data)

        public var intValue: Int? {
            if case .integer(let v) = self { return Int(v) }
            return nil
        }

        public var stringValue: String? {
            if case .string(let v) = self { return v }
            return nil
        }
    }

    public struct Attribute: Equatable, Sendable {
        public var name: String
        public var values: [Value]
    }

    /// One attribute group, e.g. one printer in a CUPS-Get-Printers response.
    public struct Group: Equatable, Sendable {
        public var tag: UInt8
        public var attributes: [Attribute]

        public subscript(name: String) -> [Value] {
            attributes.first { $0.name == name }?.values ?? []
        }
    }

    public struct Response: Equatable, Sendable {
        public var statusCode: UInt16
        public var requestID: UInt32
        public var groups: [Group]

        public var isSuccess: Bool { statusCode < 0x0100 }

        public func groups(tagged tag: Tag) -> [Group] {
            groups.filter { $0.tag == tag.rawValue }
        }
    }

    public enum DecodeError: Error, Equatable {
        case truncated
        case valueOutsideGroup
    }

    public struct Request {
        public var operation: Operation
        public var requestID: UInt32
        private var body = Data()

        public init(operation: Operation, requestID: UInt32 = 1, printerURI: String?) {
            self.operation = operation
            self.requestID = requestID
            body.append(Tag.operationAttributes.rawValue)
            append(.charset, "attributes-charset", ["utf-8"])
            append(.naturalLanguage, "attributes-natural-language", ["en"])
            if let printerURI { append(.uri, "printer-uri", [printerURI]) }
        }

        public mutating func append(_ tag: Tag, _ name: String, _ values: [String]) {
            for (index, value) in values.enumerated() {
                body.append(tag.rawValue)
                let nameBytes = index == 0 ? Data(name.utf8) : Data()
                body.appendUInt16(UInt16(nameBytes.count))
                body.append(nameBytes)
                let valueBytes = Data(value.utf8)
                body.appendUInt16(UInt16(valueBytes.count))
                body.append(valueBytes)
            }
        }

        public mutating func appendInteger(_ name: String, _ value: Int32) {
            body.append(Tag.integer.rawValue)
            body.appendUInt16(UInt16(name.utf8.count))
            body.append(Data(name.utf8))
            body.appendUInt16(4)
            body.appendUInt32(UInt32(bitPattern: value))
        }

        /// The encoded request; `document` follows the end-of-attributes tag.
        public func encoded(document: Data? = nil) -> Data {
            var data = Data([0x01, 0x01])
            data.appendUInt16(operation.rawValue)
            data.appendUInt32(requestID)
            data.append(body)
            data.append(Tag.end.rawValue)
            if let document { data.append(document) }
            return data
        }
    }

    public static func decode(_ data: Data) throws -> Response {
        var reader = Reader(data: data)
        _ = try reader.uint16() // version
        let status = try reader.uint16()
        let requestID = try reader.uint32()
        var groups: [Group] = []
        while true {
            let tag = try reader.uint8()
            if tag == Tag.end.rawValue { break }
            if tag < 0x10 {
                groups.append(Group(tag: tag, attributes: []))
                continue
            }
            guard !groups.isEmpty else { throw DecodeError.valueOutsideGroup }
            let name = try reader.string(length: Int(try reader.uint16()))
            let raw = try reader.bytes(Int(try reader.uint16()))
            let value = decodeValue(tag: tag, raw: raw)
            var group = groups.removeLast()
            if name.isEmpty, !group.attributes.isEmpty {
                group.attributes[group.attributes.count - 1].values.append(value)
            } else {
                group.attributes.append(Attribute(name: name, values: [value]))
            }
            groups.append(group)
        }
        return Response(statusCode: status, requestID: requestID, groups: groups)
    }

    private static func decodeValue(tag: UInt8, raw: Data) -> Value {
        switch tag {
        case Tag.integer.rawValue, Tag.enumValue.rawValue:
            guard raw.count == 4 else { return .other(tag: tag, bytes: raw) }
            let bits = raw.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return .integer(Int32(bitPattern: bits))
        case Tag.boolean.rawValue:
            return .boolean(raw.first.map { $0 != 0 } ?? false)
        case 0x41...0x49:
            return .string(String(decoding: raw, as: UTF8.self))
        default:
            return .other(tag: tag, bytes: raw)
        }
    }

    private struct Reader {
        let data: Data
        var offset: Int

        init(data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.endIndex else { throw DecodeError.truncated }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func uint8() throws -> UInt8 { try bytes(1).first! }

        mutating func uint16() throws -> UInt16 {
            try bytes(2).reduce(0) { ($0 << 8) | UInt16($1) }
        }

        mutating func uint32() throws -> UInt32 {
            try bytes(4).reduce(0) { ($0 << 8) | UInt32($1) }
        }

        mutating func string(length: Int) throws -> String {
            String(decoding: try bytes(length), as: UTF8.self)
        }
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendUInt16(UInt16(value >> 16))
        appendUInt16(UInt16(value & 0xffff))
    }
}
