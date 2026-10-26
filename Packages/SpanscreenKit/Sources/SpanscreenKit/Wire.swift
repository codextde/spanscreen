import Foundation

struct ByteWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    private mutating func take(_ n: Int) -> Data? {
        guard data.endIndex - offset >= n else { return nil }
        defer { offset += n }
        return data[offset..<offset + n]
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
        guard let bytes = take(MemoryLayout<T>.size) else { return nil }
        return bytes.reduce(T(0)) { ($0 << 8) | T($1) }
    }

    mutating func u8() -> UInt8? { integer(UInt8.self) }
    mutating func u16() -> UInt16? { integer(UInt16.self) }
    mutating func u32() -> UInt32? { integer(UInt32.self) }
    mutating func u64() -> UInt64? { integer(UInt64.self) }
    mutating func f32() -> Float? { u32().map(Float.init(bitPattern:)) }
    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset..<data.endIndex])
    }
}

public struct VideoFrame: Equatable, Sendable {
    public var index: UInt32
    public var isKeyframe: Bool
    public var captureTime: UInt64
    public var data: Data

    public init(index: UInt32, isKeyframe: Bool, captureTime: UInt64, data: Data) {
        self.index = index
        self.isKeyframe = isKeyframe
        self.captureTime = captureTime
        self.data = data
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        w.data.reserveCapacity(data.count + 13)
        w.u8(isKeyframe ? 1 : 0)
        w.u32(index)
        w.u64(captureTime)
        w.bytes(data)
        return w.data
    }

    public init?(_ payload: Data) {
        var r = ByteReader(payload)
        guard let flags = r.u8(), let index = r.u32(), let time = r.u64() else { return nil }
        self.init(index: index, isKeyframe: flags & 1 == 1, captureTime: time, data: r.rest())
    }
}

public struct Message: Sendable {
    public var type: MessageType
    public var payload: Data

    public init(type: MessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    public init<T: Encodable>(_ type: MessageType, json value: T) {
        self.type = type
        self.payload = (try? Message.encoder.encode(value)) ?? Data()
    }

    public func decode<T: Decodable>(_: T.Type) -> T? {
        try? Message.decoder.decode(T.self, from: payload)
    }

    public func framed() -> Data {
        var w = ByteWriter()
        w.data.reserveCapacity(payload.count + 5)
        w.u32(UInt32(payload.count + 1))
        w.u8(type.rawValue)
        w.bytes(payload)
        return w.data
    }

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}

public enum FramingError: Error, Equatable {
    case oversized(Int)
    case emptyMessage
}

public struct MessageParser {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Message] {
        buffer.append(data)
        var messages: [Message] = []
        var start = buffer.startIndex
        while buffer.endIndex - start >= 4 {
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0 else { throw FramingError.emptyMessage }
            guard length <= Spanscreen.maxMessageSize else { throw FramingError.oversized(length) }
            guard buffer.endIndex - start >= 4 + length else { break }
            let typeByte = buffer[start + 4]
            let payload = Data(buffer[(start + 5)..<(start + 4 + length)])
            if let type = MessageType(rawValue: typeByte) {
                messages.append(Message(type: type, payload: payload))
            }
            start += 4 + length
        }
        if start > buffer.startIndex {
            buffer = Data(buffer[start..<buffer.endIndex])
        }
        return messages
    }
}
