import Foundation
import IOKit

// Low-level client for the AppleSMC kernel service, following the classic
// SMCParamStruct protocol used by smcFanControl, SMCKit and exelban/stats.
// Reads work as a normal user; writes require root (euid 0).

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    case smcResult(String, UInt8)
    case badData(String)
    case writeNotApplied(String)

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let k): return "IOServiceOpen failed (\(k))"
        case .callFailed(let k): return "IOConnectCallStructMethod failed (\(k))"
        case .keyNotFound(let key): return "SMC key not found: \(key)"
        case .smcResult(let key, let r): return "SMC error for \(key) (result \(r))"
        case .badData(let key): return "Unexpected data for \(key)"
        case .writeNotApplied(let key): return "Write to \(key) did not take effect"
        }
    }
}

// MARK: - Param struct (must be exactly 80 bytes)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

public typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

let emptyBytes: SMCBytes = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
)

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = emptyBytes
}

private let kSMCHandleYPCEvent: UInt32 = 2
private let kSMCReadBytes: UInt8 = 5
private let kSMCWriteBytes: UInt8 = 6
private let kSMCReadIndex: UInt8 = 8
private let kSMCReadKeyInfo: UInt8 = 9
private let kSMCSuccess: UInt8 = 0
private let kSMCKeyNotFound: UInt8 = 132

// MARK: - Four-char codes

func fourCC(_ s: String) -> UInt32 {
    var result: UInt32 = 0
    for c in s.utf8.prefix(4) { result = result << 8 | UInt32(c) }
    return result
}

func fourCCString(_ v: UInt32) -> String {
    let chars: [UInt8] = [
        UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff),
        UInt8(v >> 8 & 0xff), UInt8(v & 0xff),
    ]
    return String(bytes: chars, encoding: .ascii) ?? ""
}

// MARK: - Client

public final class SMC {
    public static let shared = SMC()
    private var connection: io_connect_t = 0
    private let lock = NSLock()

    private init() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        IOServiceOpen(service, mach_task_self_, 0, &connection)
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        guard connection != 0 else { throw SMCError.serviceNotFound }
        assert(MemoryLayout<SMCParamStruct>.stride == 80, "SMCParamStruct must be 80 bytes")
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        lock.lock()
        defer { lock.unlock() }
        let rc = IOConnectCallStructMethod(
            connection, kSMCHandleYPCEvent,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize)
        guard rc == kIOReturnSuccess else { throw SMCError.callFailed(rc) }
        return output
    }

    public struct KeyInfo {
        public let dataSize: Int
        public let dataType: String

        public init(dataSize: Int, dataType: String) {
            self.dataSize = dataSize
            self.dataType = dataType
        }
    }

    public func keyInfo(_ key: String) throws -> KeyInfo {
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = kSMCReadKeyInfo
        let output = try call(&input)
        if output.result == kSMCKeyNotFound { throw SMCError.keyNotFound(key) }
        guard output.result == kSMCSuccess else { throw SMCError.smcResult(key, output.result) }
        return KeyInfo(
            dataSize: Int(output.keyInfo.dataSize),
            dataType: fourCCString(output.keyInfo.dataType))
    }

    public func readBytes(_ key: String) throws -> (info: KeyInfo, bytes: [UInt8]) {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.keyInfo.dataSize = UInt32(info.dataSize)
        input.data8 = kSMCReadBytes
        let output = try call(&input)
        guard output.result == kSMCSuccess else { throw SMCError.smcResult(key, output.result) }
        let raw = withUnsafeBytes(of: output.bytes) { Array($0.prefix(info.dataSize)) }
        return (info, raw)
    }

    public func writeBytes(_ key: String, _ bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count >= info.dataSize else { throw SMCError.badData(key) }
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.keyInfo.dataSize = UInt32(info.dataSize)
        input.data8 = kSMCWriteBytes
        withUnsafeMutableBytes(of: &input.bytes) { dst in
            for i in 0..<info.dataSize { dst[i] = bytes[i] }
        }
        let output = try call(&input)
        guard output.result == kSMCSuccess else { throw SMCError.smcResult(key, output.result) }
    }

    public func keyAtIndex(_ index: Int) throws -> String {
        var input = SMCParamStruct()
        input.data8 = kSMCReadIndex
        input.data32 = UInt32(index)
        let output = try call(&input)
        guard output.result == kSMCSuccess else {
            throw SMCError.smcResult("#\(index)", output.result)
        }
        return fourCCString(output.key)
    }

}

// MARK: - Value coding (pure, hardware-free)

extension SMC {
    /// Decode a numeric SMC value. Integers are big-endian; `flt` is a native
    /// little-endian float (the common type on Apple Silicon).
    static func decode(type: String, bytes b: [UInt8], key: String) throws -> Double {
        switch type {
        case "ui8 ", "si8 ", "flag":
            guard b.count >= 1 else { throw SMCError.badData(key) }
            return Double(b[0])
        case "ui16":
            guard b.count >= 2 else { throw SMCError.badData(key) }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { throw SMCError.badData(key) }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "flt ":
            guard b.count >= 4 else { throw SMCError.badData(key) }
            let v = b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
            return Double(v)
        case "fpe2":
            guard b.count >= 2 else { throw SMCError.badData(key) }
            return Double(UInt16(b[0]) << 6 | UInt16(b[1]) >> 2)
        case "sp78":
            guard b.count >= 2 else { throw SMCError.badData(key) }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        default:
            throw SMCError.badData("\(key) [\(type)]")
        }
    }

    /// Encode a value for the writable fan-key types (ui8/flt/fpe2).
    static func encode(type: String, value: Double, key: String) throws -> [UInt8] {
        switch type {
        case "ui8 ", "si8 ", "flag":
            return [UInt8(max(0, min(255, value)))]
        case "flt ":
            var f = Float32(value)
            return withUnsafeBytes(of: &f) { Array($0) }
        case "fpe2":
            let v = UInt16(max(0, min(16383, value)))
            return [UInt8(v >> 6), UInt8((v << 2) & 0xff)]
        default:
            throw SMCError.badData("\(key) [\(type)]")
        }
    }
}

// MARK: - Client protocol

/// The four primitive SMC operations; typed reads/writes are derived from
/// them below. `Fans`/`Sensors` talk to `activeSMC` so tests can substitute
/// an in-memory mock for the real hardware client.
public protocol SMCProviding: AnyObject {
    func keyInfo(_ key: String) throws -> SMC.KeyInfo
    func readBytes(_ key: String) throws -> (info: SMC.KeyInfo, bytes: [UInt8])
    func writeBytes(_ key: String, _ bytes: [UInt8]) throws
    func keyAtIndex(_ index: Int) throws -> String
}

extension SMC: SMCProviding {}

public extension SMCProviding {
    func hasKey(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    func keyCount() throws -> Int {
        Int(try readNumber("#KEY"))
    }

    func readNumber(_ key: String) throws -> Double {
        let (info, b) = try readBytes(key)
        return try SMC.decode(type: info.dataType, bytes: b, key: key)
    }

    func writeNumber(_ key: String, _ value: Double) throws {
        let info = try keyInfo(key)
        try writeBytes(key, SMC.encode(type: info.dataType, value: value, key: key))
    }
}

/// The SMC implementation used by `Fans` and `Sensors`. Production code
/// never changes this; tests swap in a `MockSMC`.
var activeSMC: SMCProviding = SMC.shared
