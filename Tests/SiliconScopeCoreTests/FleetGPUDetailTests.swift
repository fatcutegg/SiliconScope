//
//  File:      FleetGPUDetailTests.swift
//  Created:   2026-09-29
//  Updated:   2026-09-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins the extended NVIDIA fields on the wire: what a new agent sends decodes, what an
//             older agent omits stays nil, and "nothing is throttling" stays distinct from "the card
//             doesn't say".
//  Notes:     The GPU object follows the new Linux agent's output on kennt-Ubuntu (RTX 3090, driver
//             595, idle), trimmed to the fields under test.
//
import XCTest
@testable import SiliconScopeCore

final class FleetGPUDetailTests: XCTestCase {

    private func gpu(_ extra: String) throws -> FleetGPU {
        let json = #"{"index":0,"name":"NVIDIA GeForce RTX 3090","driver":"595.84","vramTotalBytes":25769803776,"vramUsedBytes":536870912,"utilizationPercent":0,"temperatureC":42,"powerDrawW":35.33,"powerLimitW":390,"processes":[]"# + extra + "}"
        return try JSONDecoder().decode(FleetGPU.self, from: Data(json.utf8))
    }

    func testANewAgentsDetailDecodes() throws {
        let g = try gpu(#","memUtilPercent":9,"smClockMHz":210,"smClockMaxMHz":2130,"memClockMHz":405,"memClockMaxMHz":9751,"pstate":"P8","fanPercent":0,"encoderPercent":0,"decoderPercent":0,"throttleReasons":[]"#)
        XCTAssertEqual(g.memUtilPercent, 9)
        XCTAssertEqual(g.smClockMHz, 210)
        XCTAssertEqual(g.smClockMaxMHz, 2130)
        XCTAssertEqual(g.memClockMaxMHz, 9751)
        XCTAssertEqual(g.pstate, "P8")
        XCTAssertEqual(g.fanPercent, 0, "a real 0 % fan (fan-stop at idle) is a value, not a gap")
        XCTAssertEqual(g.throttleReasons, [], "nothing throttling is a known fact")
        XCTAssertTrue(g.hasExtendedDetail)
    }

    /// An agent before 1.3 sends none of it: every field nil, and no detail card.
    func testAnOlderAgentHasNoDetail() throws {
        let g = try gpu("")
        XCTAssertNil(g.memUtilPercent)
        XCTAssertNil(g.throttleReasons)
        XCTAssertFalse(g.hasExtendedDetail)
    }

    /// A card that doesn't report a field leaves only that one out.
    func testAPartialReportKeepsWhatWasSent() throws {
        let g = try gpu(#","memUtilPercent":64,"throttleReasons":["power cap"]"#)
        XCTAssertEqual(g.memUtilPercent, 64)
        XCTAssertNil(g.fanPercent)
        XCTAssertEqual(g.throttleReasons, ["power cap"])
    }
}
