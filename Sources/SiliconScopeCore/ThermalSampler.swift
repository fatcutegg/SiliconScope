//
//  File:      ThermalSampler.swift
//  Created:   2026-06-08
//  Updated:   2026-09-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Reads thermal pressure (ProcessInfo) and fan RPMs (SMC) sudolessly.
//  Notes:     Fan keys: FNum = fan count (ui8), F{i}Ac = fan i actual RPM (flt on Apple
//             Silicon, fpe2 on older Intel). SMC may be unavailable; fanRPMs is then empty,
//             fansMeasured is false, and we still report thermal pressure. Per-sensor die temperatures come later via the HID
//             sensor API (richer than SMC on Apple Silicon).
//
import Foundation

public final class ThermalSampler {
    private let smc: SMCReader?

    public init() {
        self.smc = SMCReader()
    }

    public func sample() -> ThermalSample {
        var result = ThermalSample()

        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  result.pressure = .nominal
        case .fair:     result.pressure = .fair
        case .serious:  result.pressure = .serious
        case .critical: result.pressure = .critical
        @unknown default: result.pressure = .unknown
        }

        // "No fans" needs the SMC to SAY zero fans. A missing SMC or an unreadable FNum is not an
        // answer, and reporting it as fanless is how a two-fan Intel MacBook Pro read "fanless" (#69).
        result.fansMeasured = false
        if let smc, let count = smc.readDouble("FNum") {
            result.fansMeasured = true
            let fanCount = Int(count)
            var rpms: [Double] = []
            for i in 0..<max(fanCount, 0) {
                if let rpm = smc.readDouble("F\(i)Ac"), rpm >= 0, rpm < 100_000 {
                    rpms.append(rpm)
                }
            }
            result.fanRPMs = rpms
        }

        return result
    }
}
