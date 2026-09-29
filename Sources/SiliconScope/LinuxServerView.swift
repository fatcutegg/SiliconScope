//
//  File:      LinuxServerView.swift
//  Created:   2026-07-22
//  Updated:   2026-09-29
//  Developer: Kennt Kim / Calida Lab
//  Overview:  Detail dashboard for a remote LINUX / NVIDIA server — GPU-centric, distinct from the
//             Mac layout. The header carries the machine's identity (OS, agent, cores, RAM, GPU,
//             VRAM). Then three rows on This Mac's grid constants, grouped by subject: the GPU
//             (util/VRAM chart | NVIDIA detail), what runs on it (compute processes | AI runtime),
//             and the host (CPU/RAM chart | storage). Three rows to This Mac's four, with lists
//             scrolling inside their cards, so the page is never taller than This Mac's.
//             Deliberately omits Apple-only concepts (ANE / E-P / Media).
//  Notes:     Reuses the app's shared `Sparkline` + `MetricPalette` (line + gradient fill, NOT Swift
//             Charts) so it matches the local GPU/CPU cards — GPU=green, VRAM=sky-cyan, CPU=blue,
//             RAM=amber. Each graph overlays two traces on a shared 0…1 axis (util ÷100; VRAM/RAM
//             fractions as-is). The caption's tinted metric word (GPU/VRAM/CPU/RAM) is the legend.
//             Driven by remote MachineMetrics + FleetMonitor's rolling history.
//
import SwiftUI
import SiliconScopeCore

struct LinuxServerView: View {
    let fleet: FleetMonitor
    let machineID: String

    private var entry: FleetMonitor.Entry? { fleet.entries.first { $0.id == machineID } }
    private var history: [FleetMonitor.Sample] { fleet.history[machineID] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                if let m = entry?.metrics {
                    let g = m.gpus.first
                    header(m, g)

                    // Rows sit on the same grid constants as This Mac, and there are three of them to
                    // its four: the page can be shorter than This Mac, never taller. Lists scroll
                    // inside their cards instead of stretching the page.
                    //
                    // GPU first — what the card is doing and why — then what is running on it, then
                    // the host. A Pi / CPU-only box has no GPU rows at all rather than flat ones (#33).
                    if let g {
                        HStack(alignment: .top, spacing: Space.row) {
                            dualChart(title: "GPU / VRAM", caption: gpuCaption(g),
                                      history.map { $0.gpuUtil / 100 }, MetricPalette.gpuC,
                                      history.map { $0.vramFrac }, MetricPalette.gpuMemC)
                            // The questions asked of Apple Silicon, asked of the NVIDIA card:
                            // bandwidth-bound? boosting? held back, and by what? Only from an agent
                            // that reports them.
                            if g.hasExtendedDetail { gpuDetailCard(g) }
                        }
                        .frame(minHeight: Layout.Row.dense)

                        HStack(alignment: .top, spacing: Space.row) {
                            computeProcesses(g)
                            runtimeCard(m)
                        }
                        .frame(height: Layout.Row.scrolling)
                    }

                    HStack(alignment: .top, spacing: Space.row) {
                        dualChart(title: "CPU / RAM", caption: cpuCaption(m),
                                  history.map { $0.cpu / 100 }, MetricPalette.cpuC,
                                  history.map { $0.memFrac }, MetricPalette.ramC)
                        // nil disks = an agent too old to report them → no card, not an empty one.
                        if let disks = m.disks, !disks.isEmpty { storageCard(disks) }
                    }
                    .frame(height: Layout.Row.graphed)
                }
            }
            .padding(Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    // MARK: - sections

    /// The NVIDIA card beyond utilisation and VRAM. Each row appears only when the card reports it.
    private func gpuDetailCard(_ g: FleetGPU) -> some View {
        card("GPU DETAIL") {
            if let mem = g.memUtilPercent {
                KV(key: "Memory bandwidth", value: String(format: "%.0f%% busy", mem))
            }
            if let sm = g.smClockMHz {
                KV(key: "Core clock", value: clockText(sm, g.smClockMaxMHz) + (g.pstate.map { " · \($0)" } ?? ""))
            } else if let p = g.pstate {
                KV(key: "P-state", value: p)
            }
            if let mc = g.memClockMHz {
                KV(key: "Memory clock", value: clockText(mc, g.memClockMaxMHz))
            }
            if let fan = g.fanPercent {
                KV(key: "Fan", value: String(format: "%.0f%%", fan))
            }
            if g.encoderPercent != nil || g.decoderPercent != nil {
                KV(key: "NVENC / NVDEC",
                   value: "\(pct(g.encoderPercent)) / \(pct(g.decoderPercent))")
            }
            if let reasons = g.throttleReasons {
                KV(key: "Clocks held by",
                   value: reasons.isEmpty ? "nothing" : reasons.joined(separator: ", "),
                   valueColor: throttleColor(reasons))
            }
        }
    }

    private func clockText(_ now: Double, _ max: Double?) -> String {
        max.map { String(format: "%.0f / %.0f MHz", now, $0) } ?? String(format: "%.0f MHz", now)
    }

    private func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "—" }

    /// A power cap under load is the card working at its configured limit — stated, not flagged.
    /// Heat is worth attention; a hardware slowdown or power brake means something is wrong.
    private func throttleColor(_ reasons: [String]) -> Color {
        if reasons.contains(where: { $0.hasPrefix("hardware") || $0.hasPrefix("power brake") }) {
            return Palette.State.critical.color
        }
        if reasons.contains(where: { $0.hasPrefix("thermal") }) { return Palette.State.warn.color }
        return Theme.text
    }

    /// Name and identity in one header — the machine's shape (cores, RAM, GPU, VRAM) is a fact about
    /// it, not a reading, so it needs no card of its own.
    private func header(_ m: MachineMetrics, _ g: FleetGPU?) -> some View {
        HStack(spacing: Space.card) {
            Image(systemName: "server.rack")
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(m.hostname).font(.system(.title3, design: .monospaced).bold())
                // Two lines, software then hardware: one line got truncated in the middle and lost
                // the core count and RAM in exactly the part that was elided.
                Text("\(m.os) · agent \(m.agentVersion)").font(Theme.font(.caption)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(hardwareLine(m, g)).font(Theme.font(.caption)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let u = entry?.lastUpdated {
                Text("updated \(u.formatted(date: .omitted, time: .standard))")
                    .font(Theme.font(.caption)).foregroundStyle(.tertiary)
            }
        }
    }

    private func hardwareLine(_ m: MachineMetrics, _ g: FleetGPU?) -> String {
        var parts = ["\(m.cpu.cores) cores", "\(gbInt(m.memory.totalBytes)) RAM"]
        // A machine without a GPU (Pi, CPU-only server, VM) says nothing about one.
        if let g { parts.append("\(g.name) \(gbInt(g.vramTotalBytes))") }
        return parts.joined(separator: " · ")
    }

    private func gpuCaption(_ g: FleetGPU?) -> Text {
        guard let g else { return Text("no GPU").foregroundStyle(.secondary) }
        let power = g.powerLimitW > 0 ? "\(Int(g.powerDrawW)) / \(Int(g.powerLimitW)) W" : "\(Int(g.powerDrawW)) W"
        return tag("GPU", MetricPalette.gpuC)
            + dim(" \(Int(g.utilizationPercent))% · \(power) · \(Int(g.temperatureC))°C\n")
            + tag("VRAM", MetricPalette.gpuMemC)
            + dim(" \(gb(g.vramUsedBytes)) / \(gb(g.vramTotalBytes))")
    }

    private func cpuCaption(_ m: MachineMetrics) -> Text {
        tag("CPU", MetricPalette.cpuC)
            + dim(" \(Int(m.cpu.usagePercent))% · load \(dec2(m.cpu.loadAvg1))\n")
            + tag("RAM", MetricPalette.ramC)
            + dim(" \(gb(m.memory.usedBytes)) / \(gb(m.memory.totalBytes))")
    }

    private func tag(_ s: String, _ c: Color) -> Text {
        Text(s).font(.system(.caption, design: .monospaced).bold()).foregroundStyle(c)
    }
    private func dim(_ s: String) -> Text {
        Text(s).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
    }

    /// A card with a tinted value caption and two overlaid `Sparkline` traces on a shared 0…1 axis
    /// (values pre-normalized by the caller) — matching the local GPU/CPU cards' look.
    private func dualChart(title: String, caption: Text,
                           _ a: [Double], _ ca: Color, _ b: [Double], _ cb: Color) -> some View {
        card(title) {
            caption.fixedSize(horizontal: false, vertical: true)
            // The chart takes whatever height the row leaves it, so the card fits its row instead
            // of setting the row's height.
            if history.count >= 2 {
                Sparkline([Trace(a, ca), Trace(b, cb)], role: .trend)
                    .frame(maxHeight: .infinity)
            } else {
                Color.clear.frame(maxHeight: .infinity)
            }
        }
    }

    /// Per-volume capacity. `used` is derived (total − free) on FleetDisk, not sent. A disk has no
    /// identity colour, so the fill uses the state ramp — "how full" is itself the reading (the same
    /// encoding the local Disk card uses).
    private func storageCard(_ disks: [FleetDisk]) -> some View {
        card("STORAGE") {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.row) {
                    ForEach(disks, id: \.mount) { d in
                        Bar(label: d.mount, value: d.usedFraction,
                            detail: formatBytesOfTotal(UInt64(d.usedBytes), UInt64(max(0, d.totalBytes))),
                            encoding: .state)
                    }
                }
            }
        }
    }

    private func computeProcesses(_ g: FleetGPU) -> some View {
        card("COMPUTE PROCESSES") {
            if g.processes.isEmpty {
                Text("nothing is using the GPU").font(Theme.font(.caption)).foregroundStyle(.secondary)
            }
            ScrollView {
            ForEach(g.processes, id: \.pid) { p in
                HStack {
                    Text("\(p.pid)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: Layout.Column.linuxLabel, alignment: .leading)
                    Text(p.name).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Text(gb(p.vramBytes)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            }
        }
    }

    /// What the machine's AI runtime reports: its last decode rate and the models it has. One card,
    /// because on a GPU box they are the same subject.
    private func runtimeCard(_ m: MachineMetrics) -> some View {
        card("AI RUNTIME") {
            if let r = m.llm?.rate { tokenRateRows(r) }
            if let o = m.llm?.ollama, o.running {
                if m.llm?.rate != nil { Divider().overlay(Theme.border) }
                ScrollView { ollamaRows(o) }
            }
            if m.llm?.rate == nil && m.llm?.ollama?.running != true {
                Text("no runtime reported").font(Theme.font(.caption)).foregroundStyle(.secondary)
            }
        }
    }

    /// The runtime's own decode rate for work it has already done.
    ///
    /// The age is shown beside the number rather than under it, because the two are one fact: this
    /// machine reached 28 tok/s — *when*. Without the age a rate from an hour ago reads as live,
    /// which is the same mistake as asserting a state with no measurement behind it.
    private func tokenRateRows(_ r: FleetTokenRate) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                Text(String(format: "%.1f", r.tokensPerSec))
                    .font(Theme.font(.emphasis, .strong))
                Text("tok/s").font(Theme.font(.caption)).foregroundStyle(.secondary)
                Spacer()
                Text(Self.ageLabel(r.age)).font(Theme.font(.caption)).foregroundStyle(.secondary)
            }
            HStack(spacing: Space.row) {
                Text(r.sourceLabel).font(Theme.font(.caption)).foregroundStyle(.secondary)
                if let model = r.model {
                    Text(model).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let ttft = r.ttftSec, ttft > 0 {
                    Text(String(format: "first token %.2fs", ttft))
                        .font(Theme.font(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "just now" / "3 min ago" / "2 h ago" — coarse on purpose. The point is whether the number
    /// still describes what the machine is doing, not the exact second it was taken.
    static func ageLabel(_ age: TimeInterval) -> String {
        switch age {
        case ..<45:     return "just now"
        case ..<3600:   return "\(Int(age / 60)) min ago"
        case ..<86_400: return "\(Int(age / 3600)) h ago"
        default:        return "\(Int(age / 86_400)) d ago"
        }
    }

    private func ollamaRows(_ o: FleetOllama) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text("Ollama").font(Theme.font(.caption)).foregroundStyle(.secondary)
            let loadedNames = Set(o.loaded.map(\.name))
            ForEach(o.models, id: \.name) { model in
                HStack {
                    Circle().fill(loadedNames.contains(model.name) ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: Layout.Dot.linux, height: Layout.Dot.linux)
                    Text(model.name).font(.system(.caption, design: .monospaced))
                    if loadedNames.contains(model.name) {
                        Text("loaded").font(Theme.font(.caption)).foregroundStyle(.green)
                    }
                    Spacer()
                    Text(gb(model.sizeBytes)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - building blocks

    private func card<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.row) {
            if let title { Text(title.uppercased()).font(Theme.font(.sectionMinor)).tracking(Theme.tracking(.sectionMinor)).foregroundStyle(.secondary) }
            content()
        }
        .padding(Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.panel).fill(.quaternary.opacity(0.35)))
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(label).font(Theme.font(.caption)).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).lineLimit(1)
        }
    }

    private func dec2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
    private func gbInt(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1_073_741_824).rounded())) GB" }
}
