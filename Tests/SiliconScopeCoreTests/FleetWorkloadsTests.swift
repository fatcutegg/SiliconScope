//
//  File:      FleetWorkloadsTests.swift
//  Created:   2026-09-29
//  Updated:   2026-09-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Pins the Linux workload fields on the wire: Docker containers with their restart
//             counts, a ComfyUI queue, and which container a GPU process belongs to.
//  Notes:     Values follow kennt-Ubuntu, where one container (calidaai-gpu-agent) had restarted
//             419 times while reading "running". "Not reported" (absent) must stay distinct from
//             "none" ([]).
//
import XCTest
@testable import SiliconScopeCore

final class FleetWorkloadsTests: XCTestCase {

    private func machine(_ extra: String) throws -> MachineMetrics {
        let json = #"{"machineId":"x","hostname":"kennt-Ubuntu","os":"Ubuntu","kind":"linux","agentVersion":"1.3.0","ts":1,"cpu":{"cores":16,"usagePercent":0,"loadAvg1":0},"memory":{"totalBytes":1,"usedBytes":0,"availableBytes":1},"gpus":[]"# + extra + "}"
        return try JSONDecoder().decode(MachineMetrics.self, from: Data(json.utf8))
    }

    func testContainersAndTheirRestartsDecode() throws {
        let m = try machine(#","containers":[{"name":"calidaai-gpu-agent-1","image":"calidaai-gpu-agent","state":"running","status":"Up 4 minutes","restartCount":419},{"name":"calidaai-tts-worker-1","image":"calidaai-tts-worker","state":"running","status":"Up 35 hours (healthy)","restartCount":0}]"#)
        XCTAssertEqual(m.containers?.count, 2)
        XCTAssertTrue(m.containers?[0].hasRestarted == true, "a crash loop still reads running")
        XCTAssertFalse(m.containers?[1].hasRestarted == true)
    }

    /// Absent = the agent couldn't read Docker (or predates this); [] = Docker, and nothing running.
    func testNotReportedIsNotNone() throws {
        XCTAssertNil(try machine("").containers)
        XCTAssertEqual(try machine(#","containers":[]"#).containers, [])
    }

    func testComfyUIQueueDecodes() throws {
        let c = try machine(#","comfyui":{"version":"0.16.4","port":8188,"running":1,"pending":3}"#).comfyui
        XCTAssertEqual(c?.running, 1)
        XCTAssertEqual(c?.pending, 3)
        XCTAssertEqual(c?.version, "0.16.4")
        XCTAssertNil(try machine("").comfyui)
    }

    /// Both GPU processes on kennt-Ubuntu read "…python" once the column narrowed.
    func testGPUProcessesAreNamedByTheirProject() {
        XCTAssertEqual(FleetGPUProc.displayName(forPath: "/home/kennt/ComfyUI/venv/bin/python"), "ComfyUI")
        XCTAssertEqual(FleetGPUProc.displayName(forPath: "/home/kennt/whisper-bench/bin/python"), "whisper-bench")
        XCTAssertEqual(FleetGPUProc.displayName(forPath: "/srv/app/.venv/bin/python3.12"), "app")
        XCTAssertEqual(FleetGPUProc.displayName(forPath: "/usr/local/lib/ollama/llama-server"), "llama-server")
        XCTAssertEqual(FleetGPUProc.displayName(forPath: "/usr/bin/python3"), "python3", "the system python is not an environment")
        XCTAssertEqual(FleetGPUProc.displayName(forPath: "/usr/local/bin/python3.12"), "python3.12")
        XCTAssertEqual(FleetGPUProc.displayName(forPath: "python"), "python")
    }

    func testAGPUProcessCarriesItsContainer() throws {
        let proc = try JSONDecoder().decode(FleetGPUProc.self,
            from: Data(#"{"pid":7,"name":"python","vramBytes":1,"container":"calidaai-comfyui-worker-1"}"#.utf8))
        XCTAssertEqual(proc.container, "calidaai-comfyui-worker-1")
        let host = try JSONDecoder().decode(FleetGPUProc.self, from: Data(#"{"pid":2629,"name":"python","vramBytes":1}"#.utf8))
        XCTAssertNil(host.container)
    }
}
