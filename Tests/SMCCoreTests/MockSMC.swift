// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import SMCCore

/// In-memory SMC standing in for the hardware client. Keys hold (type,
/// bytes); `#KEY` is virtual and always reports the key count. Writes can be
/// dropped (to exercise the write-didn't-stick retry path) or made to throw.
final class MockSMC: SMCProviding {
    struct Entry {
        var type: String
        var bytes: [UInt8]
    }

    private(set) var store: [String: Entry] = [:]
    private(set) var order: [String] = []
    /// Every writeBytes call that didn't throw, in order.
    private(set) var writes: [(key: String, bytes: [UInt8])] = []
    /// Writes to these keys are accepted but not applied, n times.
    var dropWrites: [String: Int] = [:]
    /// Writes to these keys throw an SMC error.
    var failWrites: Set<String> = []

    // MARK: - Populating

    func set(_ key: String, type: String, bytes: [UInt8]) {
        if store[key] == nil { order.append(key) }
        store[key] = Entry(type: type, bytes: bytes)
    }

    func setNumber(_ key: String, type: String, _ value: Double) {
        set(key, type: type, bytes: try! SMC.encode(type: type, value: value, key: key))
    }

    func setSp78(_ key: String, _ celsius: Double) {
        let raw = UInt16(bitPattern: Int16(celsius * 256))
        set(key, type: "sp78", bytes: [UInt8(raw >> 8), UInt8(raw & 0xff)])
    }

    /// Install the standard key set for one fan. Pass `modeKey: nil` to
    /// omit the mode key entirely (read-only fan).
    func addFan(_ id: Int, actual: Double = 2000, min: Double = 1200,
                max: Double = 6000, target: Double = 2000,
                mode: Double? = 0, modeKey: String? = nil, name: String? = nil) {
        setNumber("F\(id)Ac", type: "flt ", actual)
        setNumber("F\(id)Mn", type: "flt ", min)
        setNumber("F\(id)Mx", type: "flt ", max)
        setNumber("F\(id)Tg", type: "flt ", target)
        if let mode {
            setNumber(modeKey ?? "F\(id)Md", type: "ui8 ", mode)
        }
        if let name {
            var bytes: [UInt8] = [0, 0, 0, 0] + Array(name.utf8)
            while bytes.count < 16 { bytes.append(0) }
            set("F\(id)ID", type: "{fds", bytes: bytes)
        }
    }

    func number(_ key: String) -> Double? {
        try? readNumber(key)
    }

    // MARK: - SMCProviding

    private func entry(_ key: String) throws -> Entry {
        if key == "#KEY" {
            let n = UInt32(order.count)
            return Entry(type: "ui32", bytes: [
                UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff),
                UInt8(n >> 8 & 0xff), UInt8(n & 0xff),
            ])
        }
        guard let e = store[key] else { throw SMCError.keyNotFound(key) }
        return e
    }

    func keyInfo(_ key: String) throws -> SMC.KeyInfo {
        let e = try entry(key)
        return SMC.KeyInfo(dataSize: e.bytes.count, dataType: e.type)
    }

    func readBytes(_ key: String) throws -> (info: SMC.KeyInfo, bytes: [UInt8]) {
        let e = try entry(key)
        return (SMC.KeyInfo(dataSize: e.bytes.count, dataType: e.type), e.bytes)
    }

    func writeBytes(_ key: String, _ bytes: [UInt8]) throws {
        guard store[key] != nil else { throw SMCError.keyNotFound(key) }
        if failWrites.contains(key) { throw SMCError.smcResult(key, 1) }
        writes.append((key, bytes))
        if let n = dropWrites[key], n > 0 {
            dropWrites[key] = n - 1
            return
        }
        store[key]!.bytes = bytes
    }

    func keyAtIndex(_ index: Int) throws -> String {
        guard order.indices.contains(index) else {
            throw SMCError.smcResult("#\(index)", 1)
        }
        return order[index]
    }
}
