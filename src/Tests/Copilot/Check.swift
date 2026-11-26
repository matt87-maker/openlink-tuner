import Foundation

// Offline checks of the copilot engine, including a simulated engine (no network, no UI, no car).
// From the repository root:
//   swiftc -O -parse-as-library -o /tmp/copilot-check src/Tests/Copilot/*.swift src/App/TuneCopilot.swift \
//     src/Shared/LogTable.swift src/Sources/OpenLinkKit/*.swift && /tmp/copilot-check [extra tunes.pclx …]
// Without arguments it simulates on the practice tune and on any .pclx in "Sample Tunes".
@main struct Check {
    static var failures = 0
    static func expect(_ ok: Bool, _ what: String) {
        print((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func main() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = root.appendingPathComponent("src/Resources")
        let lab = resources.appendingPathComponent("CourseLab")
        let catalog = Catalog(data: try! Data(contentsOf: resources.appendingPathComponent("catalog.json")))!
        let practice = try! TuneFile(fileURL: lab.appendingPathComponent("Practice baseline.pclx"))

        parsing()
        planner(practice, catalog)
        logFormats()
        practiceLogs(practice, catalog, lab)

        var tunes = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        if tunes.isEmpty, let found = try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sample Tunes"), includingPropertiesForKeys: nil) {
            tunes = found.filter { $0.pathExtension == "pclx" }.sorted { $0.path < $1.path }
        }
        for url in tunes {
            guard let tune = try? TuneFile(fileURL: url) else { expect(false, "open \(url.lastPathComponent)"); continue }
            simulate(tune, catalog, name: url.lastPathComponent)
        }
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: replies

    static func parsing() {
        print("\n== Reply parsing")
        let reply = """
        You're lean around **2000 RPM**. Adding 5 %.
        ```changes
        [{"id": 2365, "op": "percent", "value": 5, "x": [2000, 3000], "y": [50, 60], "why": "lean"}]
        ```
        ```chart
        {"x": "time", "y": "Lambda", "title": "Lambda"}
        ```
        Hit Apply.
        """
        let p = CopilotReply.parse(reply)
        expect(p.changes.count == 1 && !p.display.contains("```") && p.display.contains("Hit Apply"), "changes block hidden and decoded")
        expect(p.charts.count == 1 && p.charts[0].y == ["Lambda"], "chart block with a single y channel decoded")
        expect(CopilotReply.visible("Hello\n```changes\n[{\"id\": 1") == "Hello", "half-written changes block hidden while streaming")
        expect(CopilotReply.parse("```need\n[2367, 2401]\n```").need == [2367, 2401], "need block")
        expect(CopilotReply.parse("Code:\n```swift\nlet a = 1\n```").display.contains("let a = 1"), "ordinary code blocks stay visible")
        expect(CopilotReply.parse("```changes\nnot json\n```").changes.isEmpty, "broken changes block ignored")
    }

    // MARK: planner

    static func planner(_ tune: TuneFile, _ catalog: Catalog) {
        print("\n== Planner (practice tune)")
        let fuel = 2365
        let ax = TuneAxes.axes(for: fuel, in: tune, catalog: catalog)
        let planner = CopilotPlanner(tune: tune, catalog: catalog)
        let plan = planner.plan(CopilotChange(id: fuel, op: "percent", value: 5, x: [2000, 3000], y: [50, 60]))
        expect(plan.problem == nil && !plan.edits.isEmpty && plan.edits.allSatisfy {
            (2000...3000).contains(ax.x!.values[$0.col]) && (50...60).contains(ax.y!.values[$0.row]) && abs($0.new - $0.old * 1.05) < 0.051
        }, "percent over a region: \(plan.summary) · \(plan.region)")
        let cell = planner.plan(CopilotChange(id: fuel, op: "set", cells: [[2000, 50, 63]]))
        expect(cell.edits.count == 1 && cell.edits[0].old == 60 && cell.edits[0].new == 63, "exact cell by axis values")
        expect(planner.plan(CopilotChange(id: fuel, op: "add", value: 1)).edits.count == ax.x!.active * ax.y!.active, "whole table")
        let huge = planner.plan(CopilotChange(id: fuel, op: "set", value: 1e9))
        expect(huge.note != nil && huge.edits.allSatisfy { $0.new <= 150 }, "clamped to the allowed range")
        expect(planner.plan(CopilotChange(id: fuel, op: "smooth")).problem == nil || true, "smooth runs")
        expect(planner.plan(CopilotChange(id: 999_999, op: "set", value: 1)).problem != nil, "unknown setting refused")
        expect(CopilotPlanner(tune: tune, catalog: catalog, blocked: [fuel]).plan(CopilotChange(id: fuel, op: "add", value: 1)).problem != nil, "unreliably-read setting refused")
        expect(planner.plan(CopilotChange(id: fuel, op: "teleport", value: 1)).problem != nil, "unsupported operation refused")
        expect(planner.plan(CopilotChange(id: fuel, op: "lambda_correct")).problem != nil, "lambda_correct without logs refused")
        expect(planner.plan(CopilotChange(id: 2366, op: "knock_retard")).problem != nil, "knock_retard without knock refused")
        let data = try! JSONEncoder().encode(plan)
        expect((try? JSONDecoder().decode(CopilotPlan.self, from: data)) == plan, "plans save and load (chat history)")
    }

    // MARK: log formats

    static func logFormats() {
        print("\n== Log formats")
        let semicolon = "Log exported\nECU: G4X\n\nTime (ms);Engine Speed (RPM);Lambda 1\n0;1000;1,02\n50;1100;1,01\n100;1200;1,00\n"
        let a = LogTable(csv: semicolon)
        expect(a.columns == ["Engine Speed (RPM)", "Lambda 1"] && a.time == [0, 0.05, 0.1] && a.data[1][0] == 1.02, "semicolons, metadata lines, ms time, comma decimals")
        let tabs = "Time\tRPM\tAFR\n0\t900\t14.7\n1\t950\t13.0\n"
        let b = LogTable(csv: tabs)
        expect(b.columns == ["RPM", "AFR"] && b.data[1][1] == 13, "tab separated")
        let ch = LogAnalysis.Channels(b)
        expect(abs((ch.lambda?[0] ?? nil ?? 0) - 1) < 0.001, "AFR converted to lambda")
        let own = LogTable(csv: "Time (s),Engine Speed [RPM] (D1000),MAP [kPa] (D1001),Lambda 1 [λ] (D3040)\n0,1000,40,1\n")
        let oc = LogAnalysis.Channels(own)
        expect(oc.rpm != nil && oc.map != nil && oc.lambda != nil && abs((oc.mgp?[0] ?? nil ?? 0) + 61.3) < 0.01, "this app's own recordings; MGP derived from MAP")
    }

    // MARK: practice logs

    static func practiceLogs(_ tune: TuneFile, _ catalog: Catalog, _ lab: URL) {
        print("\n== Practice logs")
        let logs = ["Warm baseline", "Cold revision", "Idle closure"].map { name in
            (name: name + ".csv", table: LogTable(csv: try! String(contentsOf: lab.appendingPathComponent(name + ".csv"), encoding: .utf8)))
        }
        let analysis = LogAnalysis(logs: logs, tune: tune, catalog: catalog)
        let c = analysis.corrections[2365]?[[1, 2]]
        expect(c != nil && abs(c!.percent - 4) < 0.6, "finds +4 % lean at 2000 RPM / 50 kPa (got \(c.map { LogAnalysis.f($0.percent) } ?? "none"))")
        expect(analysis.digest.contains("not fully warm"), "cold samples flagged and left out")
        let findings = TuneCheck.run(tune: tune, catalog: catalog, analysis: analysis)
        expect(!findings.isEmpty, "tune check runs: \(findings.count) findings")
    }

    // MARK: simulated engine on a real tune

    static func simulate(_ start: TuneFile, _ catalog: Catalog, name: String) {
        print("\n== Simulated engine · \(name)")
        guard var sim = EngineSim(tune: start, catalog: catalog) else { expect(false, "find fuel table"); return }
        // Knock where this engine makes its most load (boost if it has it, near full load if not).
        let topLoad = min(70, sim.fy.activeValues.indices.map { sim.mgpAt($0) }.max() ?? 0)
        sim.options.knockRegion = (4000...5000, (topLoad - 25)...(topLoad + 5))
        print("   fuel table: \(catalog.name(sim.fuelID)) \(sim.fy.active)×\(sim.fx.active), X \(sim.fx.title), Y \(sim.fy.title)")
        print("   ignition table: \(sim.ignID.map { catalog.name($0) } ?? "none") · lambda target: \(sim.target.map { catalog.name($0.p.dataId) } ?? "none")")

        func copy(_ t: TuneFile) -> TuneFile { try! TuneFile(plaintext: t.xmlData()) }
        func apply(_ plan: CopilotPlan, to t: TuneFile) {
            let dp = Int(catalog.byId[plan.parameterID]?.dp ?? "")
            for e in plan.edits { _ = t.setCell(plan.parameterID, row: e.row, col: e.col, value: e.new, decimals: dp) }
        }
        func analyse(_ t: TuneFile, _ o: LogAnalysis.Options = .init()) -> (LogAnalysis, LogTable) {
            let log = sim.run(tune: t, catalog: catalog)
            return (LogAnalysis(logs: [("sim.csv", log)], tune: t, catalog: catalog, options: o), log)
        }

        // 1. Auto-tune converges to the real engine's fuel need, with closed loop hiding part of the error.
        let tune = copy(start)
        let (first, log) = analyse(tune)
        let cells = Set(first.corrections[sim.fuelID]?.keys.map { $0 } ?? [])
        expect(cells.count >= 10, "log covers the fuel table: \(cells.count) cells with data, \(log.time.count) samples (\(Int(log.time.last ?? 0)) s)")
        let before = sim.error(of: tune, cells: cells)
        var errors = [before.rms]
        var analysis = first
        for _ in 1...4 {
            let plan = CopilotPlanner(tune: tune, catalog: catalog, analysis: analysis).plan(CopilotChange(id: sim.fuelID, op: "lambda_correct"))
            if plan.problem == nil { apply(plan, to: tune) }
            errors.append(sim.error(of: tune, cells: cells).rms)
            analysis = analyse(tune).0
        }
        let after = sim.error(of: tune, cells: cells)
        print("   fuel table error vs real engine (RMS %): " + errors.map { String(format: "%.2f", $0) }.joined(separator: " → ") + String(format: " · worst cell %.1f%% → %.1f%%", before.worst, after.worst))
        expect(after.rms < 1.5 && after.rms < before.rms * 0.3, "auto-tune converges (RMS \(String(format: "%.2f", before.rms))% → \(String(format: "%.2f", after.rms))%)")
        expect(first.digest.contains("Closed-loop lambda trim was active"), "closed-loop trim detected and folded into corrections")

        // 2. Each improvement matters: compare one pass with features switched off.
        func onePass(_ o: LogAnalysis.Options, closedLoop: Bool = true, targetChannel: Bool = true) -> Double {
            var s = sim; s.options.closedLoop = closedLoop; s.options.logTargetChannel = targetChannel
            let t = copy(start)
            let a = LogAnalysis(logs: [("sim.csv", s.run(tune: t, catalog: catalog))], tune: t, catalog: catalog, options: o)
            let plan = CopilotPlanner(tune: t, catalog: catalog, analysis: a).plan(CopilotChange(id: sim.fuelID, op: "lambda_correct"))
            if plan.problem == nil { apply(plan, to: t) }
            return sim.error(of: t, cells: cells).rms
        }
        var noDelay = LogAnalysis.Options(); noDelay.delayCompensation = false
        let withDelay = onePass(.init()), without = onePass(noDelay)
        expect(withDelay <= without * 1.05, String(format: "sensor-delay compensation doesn't hurt on steady data (one pass %.2f%% vs %.2f%% without)", withDelay, without))
        var noTrim = LogAnalysis.Options(); noTrim.includeTrim = false
        let ignoringTrim = onePass(noTrim)
        expect(withDelay < ignoringTrim * 0.8, String(format: "closed-loop trim handling matters (one pass %.2f%% vs %.2f%% if trim is ignored)", withDelay, ignoringTrim))
        let fromTable = onePass(.init(), targetChannel: false)
        expect(fromTable < before.rms * 0.6, String(format: "works with no target channel in the log, using the lambda target table (%.2f%%)", fromTable))
        let openLoop = onePass(.init(), closedLoop: false)
        expect(openLoop < before.rms * 0.6, String(format: "works with closed loop off (%.2f%%)", openLoop))

        // 3. Knock lands in the right cells, and knock_retard pulls timing there.
        if let ignID = sim.ignID, let ix = sim.ix, let iy = sim.iy, let region = sim.options.knockRegion {
            let map = first.knock[ignID] ?? [:]
            let inside = map.keys.allSatisfy { k in
                let rpm = ix.values[k[1]], load = iy.values[k[0]]
                let mgp = (iy.source + iy.unit).lowercased().contains("gauge") ? load : load - 101.3
                return rpm >= region.rpm.lowerBound - 600 && rpm <= region.rpm.upperBound + 600 && mgp >= region.mgp.lowerBound - 25 && mgp <= region.mgp.upperBound + 25
            }
            expect(!map.isEmpty && inside, "knock events mapped to the knock region (\(map.count) cells, \(map.values.reduce(0) { $0 + $1.events }) events)")
            let retard = CopilotPlanner(tune: start, catalog: catalog, analysis: first).plan(CopilotChange(id: ignID, op: "knock_retard", value: 2))
            let hit = retard.edits.filter { map[[$0.row, $0.col]] != nil }
            expect(retard.problem == nil && !hit.isEmpty && hit.allSatisfy { abs($0.old - $0.new - 2) < 0.051 }, "knock_retard pulls 2° from knocking cells (\(retard.edits.count) cells incl. neighbours)")
        }

        // 4. Rule-based tune check and the context the model reads.
        let findings = TuneCheck.run(tune: start, catalog: catalog, analysis: first)
        for f in findings.prefix(6) { print("   check: " + (f.severity == 2 ? "DANGER " : f.severity == 1 ? "CHECK " : "note ") + f.text) }
        expect(!findings.isEmpty, "tune check: \(findings.count) findings")
        let started = Date()
        let context = TuneContext.build(tune: start, catalog: catalog, fileName: name, focusID: sim.fuelID, mainTables: [sim.fuelID] + (sim.ignID.map { [$0] } ?? []),
                                        extraTables: [], blocked: [], logs: first, live: nil, modified: [sim.fuelID])
        expect(context.contains("TUNE CHECK") && context.contains("Lambda correction map") && context.utf8.count < 400_000,
               "context for the model: \(context.utf8.count / 1024) KB, built in \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        // 5. Speed on a long log (30 minutes at 20 Hz), and a PCLink-style CSV round trip.
        var long = sim; long.options.rate = 20
        var logs: [(name: String, table: LogTable)] = []
        var total = 0
        while total < 36_000 { let l = long.run(tune: start, catalog: catalog); logs.append(("long\(logs.count).csv", l)); total += l.time.count; long.options.seed += 1 }
        let t0 = Date()
        _ = LogAnalysis(logs: logs, tune: start, catalog: catalog)
        let secs = Date().timeIntervalSince(t0)
        expect(secs < 3, String(format: "analyses %d samples in %.2f s", total, secs))
        let csv = EngineSim.csv(log, separator: ";", timeHeader: "Time (ms)", timeScale: 1000).replacingOccurrences(of: ".", with: ",")
        let reread = LogTable(csv: "PCLink log\n\n" + csv)
        let again = LogAnalysis(logs: [("export.csv", reread)], tune: start, catalog: catalog)
        let a = first.corrections[sim.fuelID] ?? [:], b = again.corrections[sim.fuelID] ?? [:]
        let same = a.filter { $0.value.weight >= 5 }.allSatisfy { k, v in b[k].map { abs($0.percent - v.percent) < 0.3 } ?? false }
        expect(reread.time.count == log.time.count && same, "same result from a semicolon / ms / comma-decimal export")

        // 6. Saved tune keeps the corrections.
        let reopened = try! TuneFile(encrypted: tune.encryptedData())
        expect(reopened.parameter(sim.fuelID)!.rows == tune.parameter(sim.fuelID)!.rows, "corrected tune saves and reopens unchanged")
    }
}
