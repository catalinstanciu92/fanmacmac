import Foundation
import SMCBridge

public struct SMCValue: Sendable {
    public let dataType: String
    public let bytes: [UInt8]

    public init(dataType: String, bytes: [UInt8]) {
        self.dataType = dataType
        self.bytes = bytes
    }

    public var unsignedInteger: UInt64? {
        switch bytes.count {
        case 1:
            return UInt64(bytes[0])
        case 2:
            return UInt64(bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) })
        case 4:
            return UInt64(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default:
            return nil
        }
    }

    public var numericValue: Double? {
        switch dataType {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = bytes[0..<4].enumerated().reduce(UInt32(0)) { partial, item in
                partial | (UInt32(item.element) << UInt32(item.offset * 8))
            }
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 4
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256
        case "ui8 ", "ui16", "ui32":
            return unsignedInteger.map(Double.init)
        default:
            if let unsignedInteger { return Double(unsignedInteger) }
            return nil
        }
    }
}

public enum SMCClientError: LocalizedError {
    case invalidKey(String)
    case openFailed(Int32)
    case readFailed(String, Int32)
    case writeFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case let .invalidKey(key):
            return "SMC keys must contain four characters: \(key)"
        case let .openFailed(code):
            return "AppleSMC could not be opened (IOReturn \(code))."
        case let .readFailed(key, code):
            return "AppleSMC read failed for \(key) (IOReturn \(code))."
        case let .writeFailed(key, code):
            return "AppleSMC write failed for \(key) (IOReturn \(code))."
        }
    }
}

public final class SMCClient {
    private var connection: SMCBridgeConnection = 0

    public init() throws {
        let result = smc_bridge_open(&connection)
        guard result == 0 else { throw SMCClientError.openFailed(result) }
    }

    deinit {
        smc_bridge_close(connection)
    }

    public func read(_ key: String) throws -> SMCValue {
        try withKey(key) { keyPointer in
            var rawValue = SMCBridgeValue()
            let result = smc_bridge_read(connection, keyPointer, &rawValue)
            guard result == 0 else { throw SMCClientError.readFailed(key, result) }

            let bytes = withUnsafeBytes(of: rawValue.bytes) { rawBuffer in
                Array(rawBuffer.prefix(Int(min(rawValue.size, 32))))
            }
            let type = withUnsafeBytes(of: rawValue.type) { rawBuffer in
                String(bytes: rawBuffer.prefix(4), encoding: .ascii) ?? ""
            }
            return SMCValue(dataType: type, bytes: bytes)
        }
    }

    public func keyCount() throws -> Int {
        var count: UInt32 = 0
        let result = smc_bridge_key_count(connection, &count)
        guard result == 0 else { throw SMCClientError.readFailed("#KEY", result) }
        return Int(count)
    }

    public func key(at index: Int) throws -> String {
        guard index >= 0 else { throw SMCClientError.invalidKey("index") }
        var rawKey = [CChar](repeating: 0, count: 5)
        let result = rawKey.withUnsafeMutableBufferPointer { buffer in
            smc_bridge_read_index(connection, UInt32(index), buffer.baseAddress!)
        }
        guard result == 0 else { throw SMCClientError.readFailed("index \(index)", result) }
        let bytes = rawKey.prefix(4).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    public func write(_ key: String, value: Data, dataType: String) throws {
        guard dataType.utf8.count == 4 else { throw SMCClientError.invalidKey(dataType) }
        guard value.count <= 32 else { throw SMCClientError.invalidKey("value") }

        try withKey(key) { keyPointer in
            let typeBytes = dataType.utf8.map { CChar(bitPattern: $0) }
            let bytes = Array(value) + Array(repeating: UInt8(0), count: 32 - value.count)
            let result = typeBytes.withUnsafeBufferPointer { typePointer in
                bytes.withUnsafeBufferPointer { bytesPointer in
                    smc_bridge_write(connection, keyPointer, typePointer.baseAddress!, bytesPointer.baseAddress!, UInt32(value.count))
                }
            }
            guard result == 0 else { throw SMCClientError.writeFailed(key, result) }
        }
    }

    public func writeUInt8(_ key: String, _ value: UInt8) throws {
        try write(key, value: Data([value]), dataType: "ui8 ")
    }

    public func writeFloat(_ key: String, _ value: Double) throws {
        var float = Float(value)
        let data = withUnsafeBytes(of: &float) { Data($0) }
        try write(key, value: data, dataType: "flt ")
    }

    private func withKey<T>(_ key: String, _ body: (UnsafePointer<CChar>) throws -> T) throws -> T {
        guard key.utf8.count == 4 else { throw SMCClientError.invalidKey(key) }
        let keyBytes = key.utf8.map { CChar(bitPattern: $0) }
        return try keyBytes.withUnsafeBufferPointer { pointer in
            try body(pointer.baseAddress!)
        }
    }
}
