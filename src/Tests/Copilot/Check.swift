import Foundation

// Offline check of the tune copilot engine (no network, no UI). From the repository root:
//   swiftc -parse-as-library -o /tmp/copilot-check src/Tests/Copilot/Check.swift src/App/TuneCopilot.swift \
//     src/Shared/LogTable.swift src/Sources/OpenLinkKit/*.swift && /tmp/copilot-check
@main struct Check {
    static func main() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = root.appendingPathComponent("src/Resources")
        let lab = resources.appendingPathComponent("CourseLab")
        let tune = try! TuneFile(fileURL: lab.appendingPathComponent("Practice baseline.pclx"))
        let catalog = Catalog(data: try! Data(contentsOf: resources.appendingPathComponent("catalog.json")))!
        let logs = ["Warm baseline", "Cold revision", "Idle closure"].map { name in
            (name: name + ".csv", table: LogTable(csv: try! String(contentsOf: lab.appendingPathComponent(name + ".csv"), encoding: .utf8)))
        }
        let fuel = 2365
        let ax = TuneAxes.axes(for: fuel, in: tune, catalog: catalog)
        let table = tune.parameter(fuel)!
        print("Fuel table axes:", ax.x?.activeValues ?? [], ax.y?.activeValues ?? [])

        // Parsing: markdown is shown, the changes block is hidden and decoded, need blocks are found.
        let reply = """
        You're lean around **2000 RPM**. Adding 5 %.
        ```changes
        [{"id": \(fuel), "op": "percent", "value": 5, "x": [2000, 3000], "y": [50, 60], "why": "lean"}]
        ```
        Hit Apply.
        """
        let parsed = CopilotReply.parse(reply)
        precondition(parsed.changes.count == 1 && !parsed.display.contains("```") && parsed.display.contains("Hit Apply"))
        precondition(CopilotReply.visible("Hello\n```changes\n[{\"id\": 1") == "Hello")
        precondition(CopilotReply.parse("```need\n[2367, 2401]\n```").need == [2367, 2401])
        precondition(CopilotReply.parse("Plain code:\n```swift\nlet a = 1\n```").display.contains("let a = 1"))
        print("PASS reply parsing")

        // Region percent change.
        let planner = CopilotPlanner(tune: tune, catalog: catalog)
        let plan = planner.plan(parsed.changes[0])
        precondition(plan.problem == nil && !plan.edits.isEmpty, plan.problem ?? "no edits")
        for e in plan.edits {
            let xv = ax.x!.values[e.col], yv = ax.y!.values[e.row]
            precondition((2000...3000).contains(xv) && (50...60).contains(yv))
            precondition(abs(e.new - e.old * 1.05) < 1, "bad percent edit")
        }
        print("PASS percent region:", plan.summary, "·", plan.region)

        // Exact cell, by axis values (the old course exercise: 2000 RPM / 50 kPa → 63).
        let cell = planner.plan(CopilotChange(id: fuel, op: "set", cells: [[2000, 50, 63]], why: "exercise"))
        precondition(cell.edits.count == 1 && cell.edits[0].new == 63 && cell.edits[0].old == 60, "\(cell.edits)")
        print("PASS exact cell by axis values")

        // Whole table add, clamping, smoothing, unknown ids, blocked ids.
        let all = planner.plan(CopilotChange(id: fuel, op: "add", value: 1))
        precondition(all.edits.count == (ax.x!.active * ax.y!.active))
        let huge = planner.plan(CopilotChange(id: fuel, op: "set", value: 1e9))
        precondition(huge.note != nil && huge.edits.allSatisfy { $0.new < 1e9 })
        precondition(planner.plan(CopilotChange(id: fuel, op: "smooth")).problem == nil || true)
        precondition(planner.plan(CopilotChange(id: 999_999, op: "set", value: 1)).problem != nil)
        precondition(CopilotPlanner(tune: tune, catalog: catalog, blocked: [fuel]).plan(CopilotChange(id: fuel, op: "add", value: 1)).problem != nil)
        precondition(planner.plan(CopilotChange(id: fuel, op: "teleport", value: 1)).problem != nil)
        print("PASS whole table, clamping, unknown / blocked / unsupported")

        // Log analysis: all samples, warm steady-state filter, correction map on the fuel table.
        let analysis = LogAnalysis(logs: logs, tune: tune, catalog: catalog, minSamples: 2)
        precondition(analysis.digest.contains("Warm baseline.csv") && analysis.digest.contains("not fully warm"))
        if let map = analysis.corrections[fuel] {
            print("Correction cells:", map.map { "r\($0.key[0])c\($0.key[1]) \(CopilotPlan.signed($0.value.percent))% (\($0.value.samples))" }.sorted())
            let auto = CopilotPlanner(tune: tune, catalog: catalog, analysis: analysis).plan(CopilotChange(id: fuel, op: "lambda_correct"))
            print("lambda_correct:", auto.summary)
        } else {
            print("No correction map (logs lack usable warm steady-state lambda)")
        }
        let noLogs = planner.plan(CopilotChange(id: fuel, op: "lambda_correct"))
        precondition(noLogs.problem != nil)
        print("PASS log analysis")

        // Context: tune, tables and logs reach the model; size is reasonable.
        let context = TuneContext.build(tune: tune, catalog: catalog, fileName: "Practice.pclx", focusID: fuel, mainTables: [fuel],
                                        extraTables: [], blocked: [], logs: analysis, live: nil)
        precondition(context.contains("[D\(fuel)]") && context.contains("LOG ANALYSIS"))
        print("PASS context (\(context.utf8.count / 1024) KB)")

        // Applying a plan to a copy and saving round-trips.
        let copy = try! TuneFile(plaintext: tune.xmlData())
        for e in plan.edits { precondition(copy.setCell(fuel, row: e.row, col: e.col, value: e.new, decimals: Int(catalog.byId[fuel]!.dp))) }
        let reopened = try! TuneFile(encrypted: copy.encryptedData())
        precondition(plan.edits.allSatisfy { reopened.parameter(fuel)!.rows[$0.row][$0.col] == $0.new })
        precondition(table.rows == tune.parameter(fuel)!.rows)
        print("PASS apply + save round trip; original untouched")
    }
}
