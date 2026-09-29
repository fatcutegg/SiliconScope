//
//  File:      IntelFansAndSensorsTests.swift
//  Created:   2026-09-29
//  Updated:   2026-09-30
//  Developer: Kennt Kim / Calida Lab
//  Overview:  #69: a two-fan Intel MacBook Pro read "fanless" with "no sensors available". Pins the
//             three pieces of the fix — the Intel sp78 temperature type, Intel's key names, and the
//             difference between "no fans" and "no fan reading" from agent to screen.
//  Notes:     Intel key meanings (TC0P proximity, TCnC per core …) are Intel-Mac convention and are
//             not verified on hardware here; the reporter tests a build. The decode and the
//             unknown-vs-fanless mapping are pure and fully pinned.
//
import XCTest
@testable import SiliconScopeCore

final class IntelFansAndSensorsTests: XCTestCase {

    // MARK: - sp78

    func testSp78IsSignedFixedPointWithEightFractionalBits() {
        XCTAssertEqual(SMCReader.decode(type: "sp78", bytes: [0x2A, 0x80]), 42.5)
        XCTAssertEqual(SMCReader.decode(type: "sp78", bytes: [0x00, 0x00]), 0)
        XCTAssertEqual(SMCReader.decode(type: "sp78", bytes: [0xFF, 0x00]), -1.0, "signed")
        XCTAssertNil(SMCReader.decode(type: "sp78", bytes: [0x2A]))
    }

    /// The key scan used to accept `flt` only, so an Intel Mac's temperatures were never found.
    func testTheKeyScanAcceptsBothTemperatureTypes() {
        XCTAssertEqual(SMCReader.temperatureTypes, ["flt ", "sp78"])
    }

    // MARK: - Intel key names

    func testIntelKeysAreClassifiedByIntelPrefixes() {
        XCTAssertEqual(TemperatureSampler.category(for: "TC0P", intel: true), .cpu)
        XCTAssertEqual(TemperatureSampler.category(for: "TC4C", intel: true), .cpu)
        XCTAssertEqual(TemperatureSampler.category(for: "TG0D", intel: true), .gpu)
        XCTAssertEqual(TemperatureSampler.category(for: "TM0P", intel: true), .memory)
        XCTAssertEqual(TemperatureSampler.category(for: "TB1T", intel: true), .battery)
        XCTAssertEqual(TemperatureSampler.category(for: "TA0P", intel: true), .other)
    }

    /// The Intel map must not leak into Apple Silicon, whose CPU keys are lowercase `Tp`.
    func testAppleSiliconClassificationIsUnchanged() {
        XCTAssertEqual(TemperatureSampler.category(for: "Tp09", intel: false), .cpu)
        XCTAssertEqual(TemperatureSampler.category(for: "Tg05", intel: false), .gpu)
        XCTAssertEqual(TemperatureSampler.category(for: "TC0P", intel: false), .other)
    }

    func testIntelKeysGetTheirConventionalNamesOrStayRaw() {
        XCTAssertEqual(TemperatureSampler.intelName(for: "TC0P"), "CPU proximity")
        XCTAssertEqual(TemperatureSampler.intelName(for: "TC0D"), "CPU die")
        XCTAssertEqual(TemperatureSampler.intelName(for: "TC3C"), "CPU core 3")
        XCTAssertEqual(TemperatureSampler.intelName(for: "TG0P"), "GPU proximity")
        XCTAssertEqual(TemperatureSampler.intelName(for: "TB1T"), "Battery 2")
        XCTAssertNil(TemperatureSampler.intelName(for: "TA0P"), "unknown meaning keeps the raw key")
        XCTAssertNil(TemperatureSampler.intelName(for: "TC0C"), "core numbering starts at 1")
    }

    /// dewylouis's MacBookPro16,1 read "CPU die" twice (TC0E, TC0F) and left conventional keys raw.
    func testIntelDieReadingsAreDistinctAndConventionalKeysAreNamed() {
        let die = ["TC0D", "TC0E", "TC0F"].compactMap { TemperatureSampler.intelName(for: $0) }
        XCTAssertEqual(Set(die).count, 3, "three readings of one die need three names")
        XCTAssertEqual(TemperatureSampler.intelName(for: "TCSA"), "CPU system agent")
        XCTAssertEqual(TemperatureSampler.intelName(for: "TW0P"), "Wi-Fi")
        XCTAssertEqual(TemperatureSampler.intelName(for: "TH0x"), "Drive 1 max")
        XCTAssertEqual(TemperatureSampler.intelName(for: "TH0A"), "Drive 1 A")
        XCTAssertEqual(TemperatureSampler.intelName(for: "TH1b"), "Drive 2 B")
        XCTAssertNil(TemperatureSampler.intelName(for: "TH0P"), "HDD proximity on some models, drive 0 on others")
        // Keys whose documented meaning differs between models stay raw.
        for key in ["Ts0S", "Ts1S", "Ts1P", "Th1H", "Th2H", "Tm0P", "TaLC", "TaRC"] {
            XCTAssertNil(TemperatureSampler.intelName(for: key), key)
        }
    }

    // MARK: - No fans vs no fan reading

    /// Builds a real agent payload on this machine, lets the test reshape it, then maps it the way
    /// the viewer does.
    private func viewerThermal(_ reshape: (inout [String: Any]) -> Void) throws -> ThermalSample {
        let m = MachineMetrics.mac(snapshot: SystemSnapshot(), topology: nil, hostname: "h", machineId: "id",
                                   osName: "macOS", agentVersion: "t", tsMillis: 1, loadAvg1: 0,
                                   anePeakWatts: 0, mediaPeakGBs: 0, bandwidthPeakGBs: 0, gpuClockPeakMHz: 0)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
        reshape(&json)
        let decoded = try JSONDecoder().decode(MachineMetrics.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        return decoded.toDashboardSnapshot().snapshot.thermal
    }

    /// #69 itself: an Intel agent sends no Apple block and (before 1.3) no fans. That is unknown.
    func testAnIntelAgentWithoutFansReadsUnknownNotFanless() throws {
        let t = try viewerThermal { json in
            json["apple"] = nil
            json["thermal"] = ["pressure": "nominal"]
        }
        XCTAssertTrue(t.fansUnknown)
        XCTAssertFalse(t.hasFans)
    }

    func testFansInTheCommonFieldAreShown() throws {
        let t = try viewerThermal { json in
            json["apple"] = nil
            json["thermal"] = ["pressure": "nominal", "fanRPMs": [2100.0, 2150.0]]
        }
        XCTAssertEqual(t.fanRPMs, [2100, 2150])
        XCTAssertFalse(t.fansUnknown)
    }

    /// An agent that read the fan count and got zero: that is a real fanless Mac.
    func testAnEmptyCommonFieldIsFanless() throws {
        let t = try viewerThermal { json in
            json["thermal"] = ["pressure": "nominal", "fanRPMs": [Double]()]
        }
        XCTAssertFalse(t.hasFans)
        XCTAssertFalse(t.fansUnknown, "a confirmed zero is fanless, not unknown")
    }

    /// Apple Silicon agents before this field carried fans only in the Apple block. A fanless Air
    /// from one of them must still read fanless.
    func testAnOlderAppleSiliconAgentStillReadsItsAppleBlock() throws {
        let t = try viewerThermal { json in
            var apple = json["apple"] as! [String: Any]
            apple["fanRPMs"] = [Double]()
            json["apple"] = apple
            json["thermal"] = ["pressure": "nominal"]
        }
        XCTAssertFalse(t.hasFans)
        XCTAssertFalse(t.fansUnknown)
    }

    /// Recordings made before the field existed must still decode, and keep their old meaning.
    func testOlderRecordingsDecodeWithoutTheField() throws {
        let t = try JSONDecoder().decode(ThermalSample.self,
                                         from: Data(#"{"pressure":"nominal","fanRPMs":[]}"#.utf8))
        XCTAssertNil(t.fansMeasured)
        XCTAssertFalse(t.fansUnknown)
    }
}
