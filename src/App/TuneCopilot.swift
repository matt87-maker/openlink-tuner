import Foundation

// Tune copilot engine: everything the AI sees and everything it can change.
// No UI and no network here, so the check in Tests/Copilot can run it directly.
//
// How it works:
//  1. TuneContext writes the open tune, attached logs and live data as text for the model.
//  2. The model answers in markdown and, when it changes something, adds a ```changes block
//     with region-based operations ("+5% between 3000–5000 RPM and 100–150 kPa").
//  3. CopilotPlanner turns each operation into exact cell edits on the current tune,
//     rounded to the setting's precision and clamped to its allowed range.
//  4. The user previews each plan and clicks Apply (undoable). Nothing is written to the ECU.

// MARK: - What the model sends back

struct CopilotChange: Codable, Hashable {
    var id: Int
    var op: String
    var value: Double?
    var x: [Double]?
    var y: [Double]?
    var cells: [[Double]]?
    var why: String?
}

enum CopilotReply {
    /// Markdown to show, the change operations and any tables the model asked to see.
    static func parse(_ text: String) -> (display: String, changes: [CopilotChange], need: [Int]) {
        var display = "", changes: [CopilotChange] = [], need: [Int] = []
        var inFence = false, fenceTag = "", fenceBody = "", fenceRaw = ""
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inFence, trimmed.hasPrefix("```") {
                inFence = true; fenceTag = String(trimmed.dropFirst(3)).lowercased().trimmingCharacters(in: .whitespaces)
                fenceBody = ""; fenceRaw = line + "\n"
                continue
            }
            if inFence {
                if trimmed == "```" {
                    inFence = false
                    if !consume(tag: fenceTag, body: fenceBody, changes: &changes, need: &need) { display += fenceRaw + line + "\n" }
                } else { fenceBody += line + "\n"; fenceRaw += line + "\n" }
                continue
            }
            display += line + "\n"
        }
        if inFence, !consume(tag: fenceTag, body: fenceBody, changes: &changes, need: &need) { display += fenceRaw }
        return (display.trimmingCharacters(in: .whitespacesAndNewlines), changes, need)
    }

    /// Text safe to show while the reply is still streaming (hides a half-written changes block).
    static func visible(_ partial: String) -> String {
        var out = partial
        for tag in ["```changes", "```need", "```json\n[", "```json\n{"] {
            if let r = out.range(of: tag) { out = String(out[..<r.lowerBound]) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func consume(tag: String, body: String, changes: inout [CopilotChange], need: inout [Int]) -> Bool {
        let data = Data(body.utf8)
        if tag == "need" {
            if let ids = try? JSONDecoder().decode([Int].self, from: data) { need += ids; return true }
            let ids = body.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            need += ids; return !ids.isEmpty
        }
        guard tag == "changes" || tag == "json" || tag.isEmpty else { return false }
        if let list = try? JSONDecoder().decode([CopilotChange].self, from: data) { changes += list; return true }
        struct Wrapped: Decodable { let changes: [CopilotChange] }
        if let w = try? JSONDecoder().decode(Wrapped.self, from: data) { changes += w.changes; return true }
        if let one = try? JSONDecoder().decode(CopilotChange.self, from: data) { changes.append(one); return true }
        return tag == "changes"   // a broken changes block is hidden rather than shown as JSON
    }
}

// MARK: - Exact edits the user reviews

struct PlannedEdit: Hashable {
    let row, col: Int          // 0, 0 for a single setting
    let old, new: Double
}

struct CopilotPlan: Identifiable, Hashable {
    let id = UUID()
    let parameterID: Int
    let name: String
    let unit: String
    let isScalar: Bool
    let rows, cols: Int
    let edits: [PlannedEdit]
    let why: String
    let region: String
    var note: String?          // e.g. some values clamped to the allowed range
    var problem: String?       // set when the plan can't be applied

    var summary: String {
        guard problem == nil else { return problem! }
        if isScalar, let e = edits.first { return "\(TuneExport.num(e.old)) → \(TuneExport.num(e.new)) \(unit)" }
        let pcts = edits.compactMap { $0.old != 0 ? ($0.new / $0.old - 1) * 100 : nil }
        let deltas = edits.map { $0.new - $0.old }
        let cells = "\(edits.count) cell\(edits.count == 1 ? "" : "s")"
        if let lo = pcts.min(), let hi = pcts.max(), pcts.count == edits.count {
            return cells + " · " + (abs(hi - lo) < 0.05 ? CopilotPlan.signed(lo) + "%" : CopilotPlan.signed(lo) + "% to " + CopilotPlan.signed(hi) + "%")
        }
        if let lo = deltas.min(), let hi = deltas.max() {
            return cells + " · " + (lo == hi ? CopilotPlan.signed(lo) : CopilotPlan.signed(lo) + " to " + CopilotPlan.signed(hi)) + " " + unit
        }
        return cells
    }
    static func signed(_ v: Double) -> String { (v >= 0 ? "+" : "−") + TuneExport.num((abs(v) * 10).rounded() / 10) }
}

struct CopilotPlanner {
    let tune: TuneFile
    let catalog: Catalog?
    var blocked: Set<Int> = []
    var analysis: LogAnalysis? = nil

    func plan(_ c: CopilotChange) -> CopilotPlan {
        let entry = catalog?.byId[c.id]
        let name = entry?.name ?? "D\(c.id)"
        let unit = TuneAxes.unit(entry)
        func fail(_ why: String) -> CopilotPlan {
            CopilotPlan(parameterID: c.id, name: name, unit: unit, isScalar: true, rows: 0, cols: 0, edits: [],
                        why: c.why ?? "", region: "", problem: why)
        }
        guard let p = tune.parameter(c.id) else { return fail("D\(c.id) isn't in this tune.") }
        if p.readOnly { return fail("\(name) is read-only.") }
        if blocked.contains(c.id) { return fail("\(name) wasn't read reliably from the ECU, so it can't be edited here.") }
        let op = c.op.lowercased()
        let dp = entry.flatMap { Int($0.dp) }
        let low = entry.flatMap { Double($0.min) }, high = entry.flatMap { Double($0.max) }
        var clamped = false
        func finish(_ v: Double) -> Double {
            var x = v
            if let high, x > high { x = high; clamped = true }
            if let low, x < low { x = low; clamped = true }
            if let dp, (0...7).contains(dp) { let f = pow(10, Double(dp)); x = (x * f).rounded() / f }
            return x
        }
        func compute(_ old: Double, cellValue: Double? = nil) -> Double? {
            let v = cellValue ?? c.value
            switch op {
            case "set": return v
            case "add": return v.map { old + $0 }
            case "percent", "scale": return v.map { old * (1 + $0 / 100) }
            case "multiply": return v.map { old * $0 }
            default: return nil
            }
        }

        // A single setting
        if let scalar = p.scalar {
            guard let raw = compute(scalar), raw.isFinite else { return fail("Unsupported change “\(c.op)” for \(name).") }
            let new = finish(raw)
            var plan = CopilotPlan(parameterID: c.id, name: name, unit: unit, isScalar: true, rows: 1, cols: 1,
                                   edits: new == scalar ? [] : [PlannedEdit(row: 0, col: 0, old: scalar, new: new)],
                                   why: c.why ?? "", region: "")
            if plan.edits.isEmpty { plan.problem = "\(name) is already \(TuneExport.num(scalar)) \(unit)." }
            if clamped { plan.note = "Limited to the allowed range \(TuneExport.num(low ?? 0))–\(TuneExport.num(high ?? 0)) \(unit)." }
            return plan
        }

        // A table
        guard !p.rows.isEmpty, let width = p.rows.first?.count, width > 0 else { return fail("\(name) has no values.") }
        let ax = TuneAxes.axes(for: c.id, in: tune, catalog: catalog)
        let nRows = min(p.rows.count, ax.y?.active ?? p.rows.count)
        let nCols = min(width, ax.x?.active ?? width)
        // 1-D tables: accept either x or y for the one axis that exists.
        let oneRow = nRows == 1, oneCol = nCols == 1
        let colRange = c.x ?? (oneRow ? c.y : nil)
        let rowRange = c.y ?? (oneCol ? c.x : nil)
        let cols = CopilotPlanner.indices(ax.x, count: nCols, range: oneCol ? nil : colRange)
        let rows = CopilotPlanner.indices(ax.y, count: nRows, range: oneRow ? nil : rowRange)
        var targets: [[Int]: Double] = [:]   // [row, col] → new raw value

        switch op {
        case _ where c.cells != nil:
            for cell in c.cells ?? [] {
                guard let v = cell.last, cell.count >= 2 else { continue }
                var r = 0, col = 0
                if cell.count >= 3 {
                    col = CopilotPlanner.nearest(ax.x, count: nCols, cell[0]); r = CopilotPlanner.nearest(ax.y, count: nRows, cell[1])
                } else if oneRow { col = CopilotPlanner.nearest(ax.x ?? ax.y, count: nCols, cell[0]) }
                else { r = CopilotPlanner.nearest(ax.y ?? ax.x, count: nRows, cell[0]) }
                let old = p.rows[r][col]
                if let n = compute(old, cellValue: v) { targets[[r, col]] = n }
            }
        case "lambda_correct", "autotune":
            guard let map = analysis?.corrections[c.id], !map.isEmpty else {
                return fail("No usable lambda data for \(name). Attach a warm, steady-state log with RPM, load and lambda.")
            }
            let cap = abs(c.value ?? 15)
            for r in rows { for col in cols {
                guard let k = map[[r, col]] else { continue }
                targets[[r, col]] = p.rows[r][col] * (1 + max(-cap, min(cap, k.percent)) / 100)
            } }
        case "smooth":
            let k = max(0, min(1, c.value ?? 0.5))
            for r in rows { for col in cols {
                var sum = 0.0, n = 0.0
                for dr in -1...1 { for dc in -1...1 {
                    let rr = r + dr, cc = col + dc
                    if rr >= 0, rr < nRows, cc >= 0, cc < nCols { sum += p.rows[rr][cc]; n += 1 }
                } }
                targets[[r, col]] = p.rows[r][col] * (1 - k) + (sum / n) * k
            } }
        default:
            guard compute(1) != nil else { return fail("Unsupported change “\(c.op)” for \(name).") }
            for r in rows { for col in cols {
                if let n = compute(p.rows[r][col]) { targets[[r, col]] = n }
            } }
        }

        let edits = targets.sorted { $0.key.lexicographicallyPrecedes($1.key) }.compactMap { key, raw -> PlannedEdit? in
            guard raw.isFinite else { return nil }
            let old = p.rows[key[0]][key[1]], new = finish(raw)
            return new == old ? nil : PlannedEdit(row: key[0], col: key[1], old: old, new: new)
        }
        let touchedRows = Set(edits.map(\.row)).sorted(), touchedCols = Set(edits.map(\.col)).sorted()
        func span(_ axis: TableAxis?, _ idx: [Int], _ total: Int) -> String? {
            guard let axis, let a = idx.first, let b = idx.last, idx.count < total else { return nil }
            let lo = TuneExport.num(axis.values[a]), hi = TuneExport.num(axis.values[b])
            return (a == b ? lo : lo + "–" + hi) + " " + (axis.unit.isEmpty ? axis.source : axis.unit)
        }
        let region = [span(ax.x, touchedCols, nCols), span(ax.y, touchedRows, nRows)].compactMap { $0 }.joined(separator: " × ")
        var plan = CopilotPlan(parameterID: c.id, name: name, unit: unit, isScalar: false, rows: nRows, cols: nCols,
                               edits: edits, why: c.why ?? "", region: region.isEmpty ? (edits.isEmpty ? "" : "whole table") : region)
        if edits.isEmpty { plan.problem = "No cells in \(name) would change." }
        if clamped { plan.note = "Some values were limited to the allowed range \(TuneExport.num(low ?? 0))–\(TuneExport.num(high ?? 0)) \(unit)." }
        return plan
    }

    /// Breakpoint indices inside [from, to]; nearest breakpoints if the range falls between them.
    static func indices(_ axis: TableAxis?, count: Int, range: [Double]?) -> [Int] {
        guard let range, !range.isEmpty, let axis else { return Array(0..<count) }
        let vals = Array(axis.values.prefix(count))
        guard !vals.isEmpty else { return Array(0..<count) }
        let lo = range.min()!, hi = range.max()!
        let tol = max(abs((vals.max() ?? 0) - (vals.min() ?? 0)), 1) * 0.002
        let inside = vals.indices.filter { vals[$0] >= lo - tol && vals[$0] <= hi + tol }
        if !inside.isEmpty { return inside }
        let a = nearest(axis, count: count, lo), b = nearest(axis, count: count, hi)
        return Array(min(a, b)...max(a, b))
    }

    static func nearest(_ axis: TableAxis?, count: Int, _ v: Double) -> Int {
        guard let axis, count > 0 else { return 0 }
        let vals = axis.values.prefix(count)
        return vals.indices.min { abs(vals[$0] - v) < abs(vals[$1] - v) } ?? 0
    }
}

// MARK: - Log analysis (deterministic, all samples)

struct LogAnalysis {
    struct Correction { let percent: Double; let samples: Int; let measured: Double; let target: Double }
    /// Fuel table DataId → [row, col] → suggested fuel change.
    var corrections: [Int: [[Int]: Correction]] = [:]
    var digest = ""

    enum Kind { case rpm, map, tps, lambda, target, ect, iat, knock, duty, ignition, oilP, fuelP }

    static func column(_ kind: Kind, in columns: [String]) -> Int? {
        let lc = columns.map { $0.lowercased() }
        func first(_ test: (String) -> Bool) -> Int? { lc.firstIndex(where: test) }
        switch kind {
        case .rpm: return first { $0.contains("rpm") || $0.contains("engine speed") }
        case .map: return first { ($0.hasPrefix("map") || $0.contains(" map") || $0.contains("manifold")) && !$0.contains("baro") }
        case .tps: return first { $0.contains("throttle") || $0.hasPrefix("tps") || $0.hasPrefix("tp ") }
        case .target: return first { $0.contains("lambda") && $0.contains("target") }
        case .lambda:
            return first { $0.contains("lambda") && $0.contains("measured") }
                ?? first { $0.contains("lambda") && !$0.contains("target") && !$0.contains("trim") && !$0.contains("corr") }
        case .ect: return first { $0.contains("coolant") || $0.hasPrefix("ect") }
        case .iat: return first { $0.contains("intake air") || $0.hasPrefix("iat") || $0.contains("air temp") }
        case .knock: return first { $0.contains("knock") && !$0.contains("thresh") }
        case .duty: return first { $0.contains("duty") && $0.contains("inj") }
        case .ignition: return first { $0.contains("final ign") } ?? first { $0.contains("ignition") && !$0.contains("trim") }
        case .oilP: return first { $0.contains("oil") && $0.contains("press") }
        case .fuelP: return first { $0.contains("fuel") && $0.contains("press") }
        }
    }

    /// Which log channel feeds a table axis, from the axis source name.
    static func column(forAxis axis: TableAxis, in columns: [String]) -> Int? {
        let s = (axis.source + " " + axis.unit).lowercased()
        if s.contains("speed") || s.contains("rpm") { return column(.rpm, in: columns) }
        if s.contains("map") || s.contains("manifold") || s.contains("kpa") { return column(.map, in: columns) }
        if s.contains("throttle") || s.contains("tps") || s.hasPrefix("tp") { return column(.tps, in: columns) }
        if s.contains("coolant") || s.contains("ect") { return column(.ect, in: columns) }
        if s.contains("air temp") || s.contains("iat") { return column(.iat, in: columns) }
        let src = axis.source.lowercased()
        return columns.firstIndex { $0.lowercased().contains(src) }
    }

    init(logs: [(name: String, table: LogTable)], tune: TuneFile?, catalog: Catalog?, minSamples: Int = 3) {
        guard !logs.isEmpty else { return }
        var text = ""
        // Fuel tables to correct, and the lambda target table for logs without a target channel.
        var fuelTables: [(id: Int, x: TableAxis, y: TableAxis, p: TuneFile.Parameter)] = []
        var targetTable: (x: TableAxis?, y: TableAxis?, p: TuneFile.Parameter)?
        if let tune {
            for p in tune.parameters where !p.readOnly && !p.rows.isEmpty {
                let name = (catalog?.byId[p.dataId]?.name ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
                let ax = TuneAxes.axes(for: p.dataId, in: tune, catalog: catalog)
                if name.contains("fueltable"), let x = ax.x, let y = ax.y { fuelTables.append((p.dataId, x, y, p)) }
                if targetTable == nil, name.contains("lambda"), name.contains("target"), !name.contains("trim") {
                    targetTable = (ax.x, ax.y, p)
                }
            }
        }
        var stats: [Int: [[Int]: (n: Int, m: Double, t: Double)]] = [:]

        for (name, log) in logs {
            let cols = log.columns
            func col(_ k: Kind) -> [Double?]? { LogAnalysis.column(k, in: cols).map { log.data[$0] } }
            let n = log.time.count
            let duration = (log.time.last ?? 0) - (log.time.first ?? 0)
            text += "### Log “\(name)” — \(TuneExport.num((duration * 10).rounded() / 10)) s, \(n) samples\n"
            text += "Channels: " + cols.joined(separator: ", ") + "\n"
            var ranges: [String] = []
            for (i, c) in cols.enumerated() {
                let v = log.data[i].compactMap { $0 }
                guard let lo = v.min(), let hi = v.max() else { continue }
                let avg = v.reduce(0, +) / Double(v.count)
                ranges.append("\(c): \(LogAnalysis.f(lo))–\(LogAnalysis.f(hi)) (avg \(LogAnalysis.f(avg)))")
            }
            if !ranges.isEmpty { text += "Ranges: " + ranges.joined(separator: "; ") + "\n" }

            let rpm = col(.rpm), map = col(.map), tps = col(.tps), lam = col(.lambda), tgt = col(.target)
            let ect = col(.ect), iat = col(.iat), knock = col(.knock), duty = col(.duty), oil = col(.oilP)
            var warnings: [String] = []
            func count(_ test: (Int) -> Bool) -> [Int] { (0..<n).filter(test) }
            if let lam, let map {
                let lean = count { (map[$0] ?? 0) > 120 && (lam[$0] ?? 0) > 0.9 }
                if let worst = lean.map({ lam[$0]! }).max() {
                    warnings.append("LEAN UNDER BOOST: \(lean.count) samples above 120 kPa with lambda > 0.90 (worst \(LogAnalysis.f(worst)) at \(LogAnalysis.f(log.time[lean[0]])) s)")
                }
            }
            if let knock, let peak = knock.compactMap({ $0 }).max(), peak > 0 {
                let hits = count { (knock[$0] ?? 0) > 0 }
                warnings.append("Knock channel non-zero in \(hits.count) samples (peak \(LogAnalysis.f(peak)), first at \(LogAnalysis.f(log.time[hits[0]])) s)")
            }
            if let ect, let hi = ect.compactMap({ $0 }).max(), hi > 105 { warnings.append("Coolant reached \(LogAnalysis.f(hi)) °C") }
            if let iat, let hi = iat.compactMap({ $0 }).max(), hi > 60 { warnings.append("Intake air reached \(LogAnalysis.f(hi)) °C (heat soak / intercooler)") }
            if let duty, let hi = duty.compactMap({ $0 }).max(), hi > 85 { warnings.append("Injector duty reached \(LogAnalysis.f(hi)) % (injectors near their limit)") }
            if let oil, let rpm {
                let low = count { (rpm[$0] ?? 0) > 3000 && (oil[$0] ?? 999) < 150 }
                if !low.isEmpty { warnings.append("Low oil pressure above 3000 RPM in \(low.count) samples") }
            }
            if let ect, let lo = ect.compactMap({ $0 }).min(), lo < 65 { warnings.append("Engine not fully warm in part of this log (coolant down to \(LogAnalysis.f(lo)) °C); those samples are excluded from fuel corrections") }
            if lam == nil { warnings.append("No lambda channel: fuel can't be corrected from this log") }
            if tgt == nil && targetTable == nil && lam != nil { warnings.append("No target lambda channel or table: corrections unavailable") }
            text += warnings.isEmpty ? "Warnings: none\n" : warnings.map { "Warning: " + $0 }.joined(separator: "\n") + "\n"

            // Bin warm, steady-state samples onto each fuel table.
            if let lam {
                for ft in fuelTables {
                    guard let xc = LogAnalysis.column(forAxis: ft.x, in: cols), let yc = LogAnalysis.column(forAxis: ft.y, in: cols) else { continue }
                    for i in 0..<n {
                        guard let m = lam[i], (0.6...1.6).contains(m), let xv = log.data[xc][i], let yv = log.data[yc][i] else { continue }
                        if let r = rpm?[i], r < 400 { continue }
                        if let e = ect?[i], e < 65 { continue }
                        if let t = tps?[i], let r = rpm?[i], t < 1.5, r > 1400 { continue }   // overrun / fuel cut
                        let dt = i > 0 ? log.time[i] - log.time[i - 1] : 0
                        if dt > 0 {
                            if let t = tps, let a = t[i], let b = t[i - 1], abs(a - b) / dt > 40 { continue }
                            if let r = rpm, let a = r[i], let b = r[i - 1], abs(a - b) / dt > 2500 { continue }
                        }
                        var target = tgt?[i] ?? nil
                        if target == nil, let tt = targetTable {
                            let tx = tt.x.flatMap { LogAnalysis.column(forAxis: $0, in: cols) }.flatMap { log.data[$0][i] }
                            let ty = tt.y.flatMap { LogAnalysis.column(forAxis: $0, in: cols) }.flatMap { log.data[$0][i] }
                            target = LogAnalysis.interpolate(tt.p, x: tt.x, y: tt.y, xv: tx, yv: ty)
                        }
                        guard let tv = target, (0.6...1.6).contains(tv) else { continue }
                        let key = [CopilotPlanner.nearest(ft.y, count: ft.y.active, yv), CopilotPlanner.nearest(ft.x, count: ft.x.active, xv)]
                        var s = stats[ft.id, default: [:]][key] ?? (0, 0, 0)
                        s.n += 1; s.m += m; s.t += tv
                        stats[ft.id, default: [:]][key] = s
                    }
                }
            }

            // A short, evenly spaced sample listing so questions about moments in the log can be answered.
            let shown = min(n, 40)
            if shown > 0 {
                text += "Samples (\(shown) of \(n), evenly spaced):\n```csv\ntime_s," + cols.joined(separator: ",") + "\n"
                for k in 0..<shown {
                    let i = shown > 1 ? k * (n - 1) / (shown - 1) : 0
                    text += LogAnalysis.f(log.time[i]) + "," + log.data.map { $0[i].map(LogAnalysis.f) ?? "" }.joined(separator: ",") + "\n"
                }
                text += "```\n"
            }
            text += "\n"
        }

        for ft in fuelTables {
            guard let cells = stats[ft.id], !cells.isEmpty else { continue }
            var map: [[Int]: Correction] = [:]
            for (k, s) in cells where s.n >= minSamples {
                let m = s.m / Double(s.n), t = s.t / Double(s.n)
                map[k] = Correction(percent: (m / t - 1) * 100, samples: s.n, measured: m, target: t)
            }
            guard !map.isEmpty else { continue }
            corrections[ft.id] = map
            let name = catalog?.byId[ft.id]?.name ?? "D\(ft.id)"
            let usedRows = Set(map.keys.map { $0[0] }).sorted(), usedCols = Set(map.keys.map { $0[1] }).sorted()
            text += "### Lambda correction map for \(name) [D\(ft.id)] — all attached logs, warm steady-state samples (≥\(minSamples) per cell)\n"
            text += "Cell = suggested fuel change % (+ = lean, add fuel) and sample count. Rows: \(ft.y.title). Columns: \(ft.x.title). Only cells with data shown.\n"
            text += "| \(ft.y.unit) \\ \(ft.x.unit) | " + usedCols.map { TuneExport.num(ft.x.values[$0]) }.joined(separator: " | ") + " |\n"
            text += "|---|" + String(repeating: "---|", count: usedCols.count) + "\n"
            for r in usedRows {
                text += "| **\(TuneExport.num(ft.y.values[r]))** | " + usedCols.map { c in
                    map[[r, c]].map { CopilotPlan.signed($0.percent) + "% (\($0.samples))" } ?? "·"
                }.joined(separator: " | ") + " |\n"
            }
            text += "Use op \"lambda_correct\" on [D\(ft.id)] to apply this map.\n\n"
        }
        digest = text
    }

    static func f(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
        return TuneExport.num((v * 1000).rounded() / 1000)
    }

    /// Bilinear lookup in a table using its active breakpoints.
    static func interpolate(_ p: TuneFile.Parameter, x: TableAxis?, y: TableAxis?, xv: Double?, yv: Double?) -> Double? {
        guard !p.rows.isEmpty else { return p.scalar }
        func locate(_ axis: TableAxis?, _ v: Double?, _ count: Int) -> (Int, Int, Double) {
            guard let axis, let v, count > 1 else { return (0, 0, 0) }
            let vals = Array(axis.values.prefix(min(axis.active, count)))
            guard vals.count > 1 else { return (0, 0, 0) }
            if v <= vals[0] { return (0, 0, 0) }
            if v >= vals[vals.count - 1] { return (vals.count - 1, vals.count - 1, 0) }
            for i in 1..<vals.count where v <= vals[i] {
                let d = vals[i] - vals[i - 1]
                return (i - 1, i, d == 0 ? 0 : (v - vals[i - 1]) / d)
            }
            return (0, 0, 0)
        }
        let (c0, c1, fx) = locate(x, xv, p.rows[0].count)
        let (r0, r1, fy) = locate(y, yv, p.rows.count)
        guard p.rows.indices.contains(r1), p.rows[r0].indices.contains(c1), p.rows[r1].indices.contains(c1) else { return nil }
        let top = p.rows[r0][c0] * (1 - fx) + p.rows[r0][c1] * fx
        let bottom = p.rows[r1][c0] * (1 - fx) + p.rows[r1][c1] * fx
        return top * (1 - fy) + bottom * fy
    }
}

// MARK: - What the model reads

enum TuneContext {
    static func build(tune: TuneFile?, catalog: Catalog?, fileName: String, focusID: Int?, mainTables: [Int],
                      extraTables: Set<Int>, blocked: Set<Int>, logs: LogAnalysis?, live: String?) -> String {
        var s = ""
        guard let tune else {
            s += "# TUNE CONTEXT\nNo tune is open. You can answer general tuning questions, but you can't propose changes until the user opens a tune or reads one from the ECU.\n"
            if let live { s += "\n# LIVE ECU DATA\n" + live }
            return s
        }
        let mem = tune.memory
        s += "# TUNE CONTEXT\nFile: \(fileName.isEmpty ? "untitled" : fileName) · Link ECU ID \(mem.linkID) · firmware \(mem.firmware)\n"
        if !mem.memo.isEmpty { s += "Memo: \(mem.memo)\n" }
        if let focusID { s += "The user currently has \(catalog?.name(focusID) ?? "D\(focusID)") [D\(focusID)] open in the editor.\n" }
        if !blocked.isEmpty { s += "Not reliably read from the ECU (don't change): " + blocked.sorted().map { "D\($0)" }.joined(separator: ", ") + "\n" }
        s += "Values are engineering units as PCLink shows them. Tables: header row = X breakpoints, first column = Y breakpoints.\n\n"

        var axisIDs = Set<Int>()
        for e in (catalog?.byId ?? [:]).values { if let x = e.xl { axisIDs.insert(x) }; if let y = e.yl { axisIDs.insert(y) } }
        let editable = tune.parameters.filter { !$0.readOnly && !axisIDs.contains($0.dataId) }
        let tables = editable.filter { $0.scalar == nil && !$0.rows.isEmpty }

        // Full tables: the main ones, the one in the editor, anything requested. Everything if small.
        var full = Set(mainTables.prefix(8)).union(extraTables)
        if let focusID { full.insert(focusID) }
        let allCells = tables.reduce(0) { $0 + $1.rows.count * ($1.rows.first?.count ?? 0) }
        if allCells < 6000 { full.formUnion(tables.map(\.dataId)) }

        s += "## Tables shown in full\n"
        let ordered = (mainTables + tables.map(\.dataId)).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        for id in ordered where full.contains(id) {
            if let p = tune.parameter(id), !p.rows.isEmpty { s += TuneExport.parameterMarkdown(p, tune: tune, catalog: catalog) }
        }

        // Every other setting, by category.
        var byCat: [String: [TuneFile.Parameter]] = [:]
        for p in editable where !full.contains(p.dataId) {
            byCat[Catalog.prettyGroup(catalog?.topic(p.dataId) ?? ""), default: []].append(p)
        }
        s += "## All other settings (tables listed by name; ask with a need block to see their values)\n"
        for cat in byCat.keys.sorted() {
            s += "### \(cat.isEmpty ? "Other" : cat)\n"
            for p in byCat[cat]!.sorted(by: { (catalog?.name($0.dataId) ?? "") < (catalog?.name($1.dataId) ?? "") }) {
                let e = catalog?.byId[p.dataId]
                let name = e?.name ?? "D\(p.dataId)"
                let unit = TuneAxes.unit(e)
                if let v = p.scalar {
                    s += "- \(name) [D\(p.dataId)] = \(TuneExport.num(v, dp: e.flatMap { Int($0.dp) }))\(unit.isEmpty ? "" : " " + unit)\n"
                } else {
                    let ax = TuneAxes.axes(for: p.dataId, in: tune, catalog: catalog)
                    let w = p.rows.first?.count ?? 0
                    let size = "\(min(p.rows.count, ax.y?.active ?? p.rows.count))×\(min(w, ax.x?.active ?? w))"
                    let axes = [ax.x.map { "X: " + $0.title }, ax.y.map { "Y: " + $0.title }].compactMap { $0 }.joined(separator: ", ")
                    s += "- \(name) [D\(p.dataId)] table \(size)\(axes.isEmpty ? "" : " (" + axes + ")")\(unit.isEmpty ? "" : ", " + unit)\n"
                }
            }
        }
        if let logs, !logs.digest.isEmpty { s += "\n# LOG ANALYSIS\n" + logs.digest }
        else { s += "\n# LOG ANALYSIS\nNo logs attached. The user can attach CSV logs with the + button.\n" }
        if let live { s += "\n# LIVE ECU DATA\n" + live }
        return s
    }
}

// MARK: - How the model behaves

enum CopilotPrompt {
    static let instructions = """
    You are OpenLink Copilot, an expert Link ECU (G4+, G4X) calibrator built into OpenLink Tuner on the user's Mac. Talk like an experienced professional tuner working with a customer at the dyno: direct, practical, confident and brief. No lectures, no filler, no disclaimers paragraphs.

    How you work
    - Do what the user asks. If the request is clear, make the change. If it's a bit ambiguous, choose the most sensible interpretation, state the assumption in one short line and go ahead. Only ask a question when you truly can't proceed without a number or fact only the user has.
    - Never refuse normal tuning work: fuel, ignition, boost, idle, cold start, acceleration enrichment, rev limiters, launch control / two-step, flat shift, overrun pops and bangs (overrun fuel cut, decel ignition retard), anti-lag, traction, etc. For riskier items add ONE short line on the risk (exhaust/cat/turbo heat, drivetrain load, road legality) and then help.
    - You have the TUNE CONTEXT below: every setting with its DataId [D####]. The main tables are shown in full; other tables are listed by name. LOG ANALYSIS has a summary of each attached log, warnings, sample rows, and for fuel tables a lambda correction map from warm steady-state samples, already binned to the table's cells.
    - Work like a pro:
      • Check the basics before chasing table numbers: injector characterisation and dead times, fuel pressure, sensor calibrations, TPS, lambda target table.
      • Correct fuel from logged lambda at steady state, warm engine. Use the correction map when it's there.
      • Be conservative with ignition: never add timing under boost without knock monitoring or the dyno; small steps (1–2°).
      • Change boost in small increments and watch lambda, knock and IAT.
      • Keep tables smooth, no steps between neighbouring cells.
      • Finish with what to log or check next when it matters.
    - If the logs show something dangerous (lean under boost, knock, high coolant or IAT, injector duty above 85 %, low oil pressure), lead with it.
    - Mode/option settings are stored as numeric codes. Don't change one unless you're certain what the code means; otherwise tell the user what to select in PCLink.
    - Nothing you do touches the ECU directly. Changes edit the open tune file in the app; the user reviews them and clicks Apply, and can undo.

    Making changes
    When you change anything, say briefly what and why, then add ONE fenced block tagged `changes` containing a JSON array:
    ```changes
    [{"id": 2365, "op": "percent", "value": 5, "x": [3000, 5000], "y": [100, 150], "why": "Lean 4–6 % here in the logs"}]
    ```
    Fields:
    - id: the DataId.
    - op: "set" (to value), "add" (add value, same units), "percent" (change by value %, e.g. 5 or -3), "multiply", "lambda_correct" (apply the logged lambda correction map to the region; value = max % per cell, default 15), "smooth" (value = strength 0–1, default 0.5).
    - x, y: [from, to] in the axis' own units (RPM, kPa, %…), inclusive. Omit an axis for all of it. Use breakpoints from the table when you can.
    - cells: exact values for individual cells, [[x, y, value], …] using axis values, or [[axisValue, value], …] for 1-D tables. Use with op "set". Use this to write a full new table or a hand-shaped region.
    - For a single setting give just id, op and value.
    - Use several items for several tables or regions. Only use DataIds from the context. Don't mention the JSON in your text; the user sees a preview card for each item.
    Never say a change has been applied; tell the user to review and hit Apply.

    Getting more data
    If you need the values of a table that's only listed by name, reply with ONLY a block tagged `need` holding a JSON array of DataIds, e.g.
    ```need
    [2367, 2401]
    ```
    The app sends those tables and asks you again. Never guess values you haven't seen.

    Formatting: short paragraphs, bullet lists, and small markdown tables when they help. Bold the key numbers. Keep answers tight.
    """
}

// MARK: - Live data for the model

/// Recent USB readings, kept for the copilot. Up to four samples per second for the last few seconds.
struct CopilotTelemetry {
    struct Sample { let time: Date; let readings: [String: Double] }
    private(set) var samples: [Sample] = []

    mutating func record(_ values: [String: Double], at time: Date) {
        let valid = values.filter { $0.value.isFinite }
        guard !valid.isEmpty else { return }
        if let last = samples.last {
            let elapsed = time.timeIntervalSince(last.time)
            if elapsed < 0 || elapsed > 3 { samples.removeAll() } else if elapsed < 0.25 { return }
        }
        samples.append(Sample(time: time, readings: valid))
        if samples.count > 24 { samples.removeFirst() }
    }

    /// Text for the model, or nil when nothing fresh has arrived.
    func summary(at now: Date) -> String? {
        let fresh = samples.filter { (0...8).contains(now.timeIntervalSince($0.time)) }
        guard let latest = fresh.last else { return nil }
        var s = "ECU connected over USB. Latest readings (\(TuneExport.num((now.timeIntervalSince(latest.time) * 10).rounded() / 10)) s ago):\n"
        for key in latest.readings.keys.sorted() {
            let series = fresh.compactMap { $0.readings[key] }
            let lo = series.min() ?? 0, hi = series.max() ?? 0
            s += "- \(key): \(LogAnalysis.f(latest.readings[key]!))" + (hi > lo ? " (last \(fresh.count) samples \(LogAnalysis.f(lo))–\(LogAnalysis.f(hi)))" : "") + "\n"
        }
        s += "The ECU's active calibration may differ from the open file.\n"
        return s
    }
}
