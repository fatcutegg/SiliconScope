//
//  File:      ThermalSample.swift
//  Created:   2026-06-08
//  Updated:   2026-09-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Value type holding one thermal reading: OS thermal pressure plus fan
//             speeds. Thermal pressure is the primary throttle signal for sustained
//             AI workloads.
//  Notes:     pressure mirrors ProcessInfo.thermalState. fanRPMs is empty on fanless
//             Macs (e.g. MacBook Air) — check hasFans before display. An empty list is only
//             "fanless" when the fan count was actually read: `fansMeasured == false` means we
//             could not read it, and the display must say unknown, not fanless (#69).
//
import Foundation

public struct ThermalSample: Sendable, Equatable, Codable {
    public enum Pressure: String, Sendable, Codable {
        case nominal, fair, serious, critical, unknown
    }

    public var pressure: Pressure = .nominal
    public var fanRPMs: [Double] = []
    /// Whether the fan count was read. nil comes from recordings and remote agents older than this
    /// field, where an empty list was always shown as fanless; false means the SMC gave no answer,
    /// so an empty `fanRPMs` is unknown rather than fanless (#69: an Intel MacBook Pro with two
    /// fans read as "fanless"). Optional so older recordings still decode.
    public var fansMeasured: Bool? = nil

    public init() {}

    public var hasFans: Bool { !fanRPMs.isEmpty }
    /// No fan reading at all — neither a speed nor a confirmed absence of fans.
    public var fansUnknown: Bool { fanRPMs.isEmpty && fansMeasured == false }
    public var maxFanRPM: Double { fanRPMs.max() ?? 0 }
    public var isThrottling: Bool { pressure == .serious || pressure == .critical }
}
