// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

// Best-effort names for SMC temperature sensor keys.
//
// Apple documents none of the Apple Silicon keys, and the same key can mean
// different sensors on different chip generations — Tp09 is an efficiency
// core on M1 but a performance core on M2 and M4 — so the M-series tables
// are selected by the machine's chip generation, parsed from the CPU brand
// string. The tables are community knowledge collected by the exelban/stats
// project (MIT licensed), which in turn draws on acidanthera's VirtualSMC
// docs. A key with no name shows as its raw four-char code — honest, and
// still enough to spot the hot one. (On this hardware many exist: an M1 Max
// exposes ~200 plausible temperature keys, of which the community has named
// only a fraction.)
enum SensorName {

    static func label(for key: String) -> String {
        label(for: key, generation: currentGeneration)
    }

    /// `generation` is the Apple Silicon generation (1 for M1...), nil on
    /// Intel. Lookup order: the generation's own table, then keys common to
    /// all Apple Silicon, then keys common to every Mac, then (Intel only)
    /// keys whose classic meaning doesn't hold on M-series.
    static func label(for key: String, generation: Int?) -> String {
        if let generation, let name = mSeries[generation]?[key] { return name }
        if generation != nil, let name = appleSilicon[key] { return name }
        if let name = everyMac[key] { return name }
        if generation == nil, let name = intelOnly[key] { return name }
        if key.hasPrefix("Tp") { return "CPU (\(key))" }
        if key.hasPrefix("Tg") { return "GPU (\(key))" }
        return key
    }

    /// "Apple M1 Max" → 1, "Apple M3" → 3; nil for anything that isn't an
    /// M-series brand string.
    nonisolated static func generation(brandString: String) -> Int? {
        for token in brandString.split(separator: " ")
        where token.first == "M" {
            if let n = Int(token.dropFirst()) { return n }
        }
        return nil
    }

    private static let currentGeneration: Int? = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0
        else { return nil }
        return generation(brandString: String(cString: buffer))
    }()

    // MARK: - Tables

    private static let mSeries: [Int: [String: String]] = [
        1: [
            "Tp09": "CPU efficiency core 1", "Tp0T": "CPU efficiency core 2",
            "Tp01": "CPU performance core 1", "Tp05": "CPU performance core 2",
            "Tp0D": "CPU performance core 3", "Tp0H": "CPU performance core 4",
            "Tp0L": "CPU performance core 5", "Tp0P": "CPU performance core 6",
            "Tp0X": "CPU performance core 7", "Tp0b": "CPU performance core 8",
            "Tg05": "GPU 1", "Tg0D": "GPU 2", "Tg0L": "GPU 3", "Tg0T": "GPU 4",
            "Tm02": "Memory 1", "Tm06": "Memory 2",
            "Tm08": "Memory 3", "Tm09": "Memory 4",
        ],
        2: [
            "Tp1h": "CPU efficiency core 1", "Tp1t": "CPU efficiency core 2",
            "Tp1p": "CPU efficiency core 3", "Tp1l": "CPU efficiency core 4",
            "Tp01": "CPU performance core 1", "Tp05": "CPU performance core 2",
            "Tp09": "CPU performance core 3", "Tp0D": "CPU performance core 4",
            "Tp0X": "CPU performance core 5", "Tp0b": "CPU performance core 6",
            "Tp0f": "CPU performance core 7", "Tp0j": "CPU performance core 8",
            "Tg0f": "GPU 1", "Tg0j": "GPU 2",
        ],
        3: [
            "Te05": "CPU efficiency core 1", "Te0L": "CPU efficiency core 2",
            "Te0P": "CPU efficiency core 3", "Te0S": "CPU efficiency core 4",
            "Tf04": "CPU performance core 1", "Tf09": "CPU performance core 2",
            "Tf0A": "CPU performance core 3", "Tf0B": "CPU performance core 4",
            "Tf0D": "CPU performance core 5", "Tf0E": "CPU performance core 6",
            "Tf44": "CPU performance core 7", "Tf49": "CPU performance core 8",
            "Tf4A": "CPU performance core 9", "Tf4B": "CPU performance core 10",
            "Tf4D": "CPU performance core 11", "Tf4E": "CPU performance core 12",
            "Tf14": "GPU 1", "Tf18": "GPU 2", "Tf19": "GPU 3", "Tf1A": "GPU 4",
            "Tf24": "GPU 5", "Tf28": "GPU 6", "Tf29": "GPU 7", "Tf2A": "GPU 8",
        ],
        4: [
            "Te05": "CPU efficiency core 1", "Te0S": "CPU efficiency core 2",
            "Te09": "CPU efficiency core 3", "Te0H": "CPU efficiency core 4",
            "Tp01": "CPU performance core 1", "Tp05": "CPU performance core 2",
            "Tp09": "CPU performance core 3", "Tp0D": "CPU performance core 4",
            "Tp0V": "CPU performance core 5", "Tp0Y": "CPU performance core 6",
            "Tp0b": "CPU performance core 7", "Tp0e": "CPU performance core 8",
            // Tg0G/Tg0H are the plain M4's GPU keys, Tg1U/Tg1k the
            // Pro/Max/Ultra's; only one pair exists on any given machine.
            "Tg0G": "GPU 1", "Tg0H": "GPU 2",
            "Tg1U": "GPU 1", "Tg1k": "GPU 2",
            "Tg0K": "GPU 3", "Tg0L": "GPU 4", "Tg0d": "GPU 5",
            "Tg0e": "GPU 6", "Tg0j": "GPU 7", "Tg0k": "GPU 8",
            "Tm0p": "Memory 1", "Tm1p": "Memory 2", "Tm2p": "Memory 3",
        ],
        5: [
            "Tp00": "CPU super core 1", "Tp04": "CPU super core 2",
            "Tp08": "CPU super core 3", "Tp0C": "CPU super core 4",
            "Tp0G": "CPU super core 5", "Tp0K": "CPU super core 6",
            "Tp0O": "CPU performance core 1", "Tp0R": "CPU performance core 2",
            "Tp0U": "CPU performance core 3", "Tp0X": "CPU performance core 4",
            "Tp0a": "CPU performance core 5", "Tp0d": "CPU performance core 6",
            "Tp0g": "CPU performance core 7", "Tp0j": "CPU performance core 8",
            "Tp0m": "CPU performance core 9", "Tp0p": "CPU performance core 10",
            "Tp0u": "CPU performance core 11", "Tp0y": "CPU performance core 12",
            "Tg0U": "GPU 1", "Tg0X": "GPU 2", "Tg0d": "GPU 3", "Tg0g": "GPU 4",
            "Tg0j": "GPU 5", "Tg1Y": "GPU 6", "Tg1c": "GPU 7", "Tg1g": "GPU 8",
        ],
    ]

    private static let appleSilicon: [String: String] = [
        "TaLP": "Airflow left", "TaRF": "Airflow right",
        "TH0x": "NAND",
        "TB1T": "Battery 1", "TB2T": "Battery 2",
    ]

    private static let everyMac: [String: String] = [
        "TA0P": "Ambient", "TB0T": "Battery", "TC0P": "CPU Proximity",
        "TG0P": "GPU Proximity", "TN0P": "Northbridge",
        "TW0P": "AirPort", "Ts0P": "Palm Rest",
    ]

    /// Classic keys whose meaning is only attested on Intel Macs. This M1 Max
    /// also has a "Th0H", but nobody knows it's a heatpipe there — better a
    /// raw key than a confident wrong name.
    private static let intelOnly: [String: String] = [
        "TH0P": "Drive Bay", "Th0H": "Heatpipe 1", "Th1H": "Heatpipe 2",
    ]
}
