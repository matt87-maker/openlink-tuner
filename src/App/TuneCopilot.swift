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

/// A chart the model asks the app to draw from an attached log.
struct CopilotChart: Codable, Hashable {
    var log: String?
    var x: String?
    var y: [String]
    var kind: String?
    var title: String?

    init(log: String? = nil, x: String? = nil, y: [String], kind: String? = nil, title: String? = nil) {
        self.log = log; self.x = x; self.y = y; self.kind = kind; self.title = title
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        log = try? c.decode(String.self, forKey: .log)
        x = try? c.decode(String.self, forKey: .x)
        kind = try? c.decode(String.self, forKey: .kind)
        title = try? c.decode(String.self, forKey: .title)
        if let many = try? c.decode([String].self, forKey: .y) { y = many }
        else { y = [try c.decode(String.self, forKey: .y)] }
    }
}

enum CopilotReply {
    /// Markdown to show, the change operations, charts to draw and any tables the model asked to see.
    static func parse(_ text: String) -> (display: String, changes: [CopilotChange], need: [Int], charts: [CopilotChart]) {
        var display = "", changes: [CopilotChange] = [], need: [Int] = [], charts: [CopilotChart] = []
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
                    if !consume(tag: fenceTag, body: fenceBody, changes: &changes, need: &need, charts: &charts) { display += fenceRaw + line + "\n" }
                } else { fenceBody += line + "\n"; fenceRaw += line + "\n" }
                continue
            }
            display += line + "\n"
        }
        if inFence, !consume(tag: fenceTag, body: fenceBody, changes: &changes, need: &need, charts: &charts) { display += fenceRaw }
        return (display.trimmingCharacters(in: .whitespacesAndNewlines), changes, need, charts)
    }

    /// Text safe to show while the reply is still streaming (hides a half-written changes block).
    static func visible(_ partial: String) -> String {
        var out = partial
        for tag in ["```changes", "```need", "```chart", "```json\n[", "```json\n{"] {
            if let r = out.range(of: tag) { out = String(out[..<r.lowerBound]) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func consume(tag: String, body: String, changes: inout [CopilotChange], need: inout [Int], charts: inout [CopilotChart]) -> Bool {
        let data = Data(body.utf8)
        if tag == "chart" {
            if let list = try? JSONDecoder().decode([CopilotChart].self, from: data) { charts += list }
            else if let one = try? JSONDecoder().decode(CopilotChart.self, from: data) { charts.append(one) }
            return true
        }
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

struct PlannedEdit: Codable, Hashable {
    let row, col: Int          // 0, 0 for a single setting
    let old, new: Double
}

struct CopilotPlan: Identifiable, Hashable, Codable {
    var id = UUID()
    let parameterID: Int
    let name: String
    let unit: String
    let isScalar: Bool
    let rows, cols: Int
    let edits: [PlannedEdit]
    let why: String
    let region: String
    var percentStyle: Bool?    // show changes as % (fuel-type changes) rather than in units
    var note: String?          // e.g. some values clamped to the allowed range
    var problem: String?       // set when the plan can't be applied

    var summary: String {
        guard problem == nil else { return problem! }
        if isScalar, let e = edits.first { return "\(TuneExport.num(e.old)) → \(TuneExport.num(e.new)) \(unit)" }
        let pcts = edits.compactMap { $0.old != 0 ? ($0.new / $0.old - 1) * 100 : nil }
        let deltas = edits.map { $0.new - $0.old }
        let cells = "\(edits.count) cell\(edits.count == 1 ? "" : "s")"
        if percentStyle == true || unit == "%", let lo = pcts.min(), let hi = pcts.max(), pcts.count == edits.count {
            return cells + " · " + (abs(hi - lo) < 0.05 ? CopilotPlan.signed(lo) + "%" : CopilotPlan.signed(lo) + "% to " + CopilotPlan.signed(hi) + "%")
        }
        if let lo = deltas.min(), let hi = deltas.max() {
            let u = unit.isEmpty && (name.lowercased().contains("ign") || name.lowercased().contains("timing")) ? "°" : unit
            return cells + " · " + (lo == hi ? CopilotPlan.signed(lo) : CopilotPlan.signed(lo) + " to " + CopilotPlan.signed(hi)) + (u == "°" ? "°" : " " + u)
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
        case "knock_retard", "knock":
            guard let map = analysis?.knock[c.id], !map.isEmpty else {
                return fail("No knock events were logged in \(name). Attach a log with knock count or knock retard channels.")
            }
            let pull = abs(c.value ?? 2)
            var amount: [[Int]: Double] = [:]
            for (k, _) in map {
                amount[k] = max(amount[k] ?? 0, pull)
                for dr in -1...1 { for dc in -1...1 where dr != 0 || dc != 0 {
                    let rr = k[0] + dr, cc = k[1] + dc
                    if rr >= 0, rr < nRows, cc >= 0, cc < nCols { amount[[rr, cc]] = max(amount[[rr, cc]] ?? 0, pull / 2) }
                } }
            }
            for (k, a) in amount where rows.contains(k[0]) && cols.contains(k[1]) { targets[k] = p.rows[k[0]][k[1]] - a }
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
        plan.percentStyle = ["percent", "scale", "multiply", "lambda_correct", "autotune"].contains(op)
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

/// Reads data logs the way a tuner does:
///  - fuel: compares measured lambda (shifted for sensor delay) with target, includes any closed-loop
///    trim the ECU was already adding, keeps only warm, steady samples, and spreads each sample over
///    the four surrounding table cells by distance. The result is a % fuel change per cell.
///  - knock: maps each knock event to the ignition table cell the engine was in.
///  - safety: lean under boost, knock, temperatures, injector duty, oil pressure.
struct LogAnalysis {
    struct Correction: Codable, Hashable { let percent: Double; let weight: Double; let measured: Double; let target: Double; let trim: Double }
    struct KnockCell: Codable, Hashable { var events: Int; var maxRetard: Double }
    struct Options {
        var minWeight = 2.0          // weighted samples a cell needs before it gets a correction
        var delayCompensation = true
        var includeTrim = true       // fold closed-loop trim into the correction
        var warmECT = 65.0
    }

    /// Fuel table DataId → [row, col] → suggested fuel change.
    var corrections: [Int: [[Int]: Correction]] = [:]
    /// Ignition table DataId → [row, col] → knock events.
    var knock: [Int: [[Int]: KnockCell]] = [:]
    var warnings: [String] = []
    var digest = ""

    enum Kind { case rpm, map, mgp, baro, tps, lambda, afr, target, targetAFR, clTrim, clLTT, ect, iat,
                    knockCount, knockRetard, knockLevel, duty, ignition, oilP, fuelP }

    static func column(_ kind: Kind, in columns: [String]) -> Int? {
        let lc = columns.map { $0.lowercased() }
        func first(_ test: (String) -> Bool) -> Int? { lc.firstIndex(where: test) }
        func cl(_ s: String) -> Bool { s.contains("cll") || s.contains("closed loop") || s.contains("cl lambda") || s.contains("cl fuel") || s.hasPrefix("cl ") || s.contains("stft") || s.contains("ltft") }
        switch kind {
        case .rpm: return first { $0.contains("rpm") && !$0.contains("limit") && !$0.contains("target") } ?? first { $0.contains("engine speed") }
        case .mgp: return first { ($0.hasPrefix("mgp") || $0.contains(" mgp") || $0.contains("gauge press")) && !$0.contains("target") }
        case .map: return first { ($0.hasPrefix("map") || $0.contains(" map") || $0.contains("manifold abs")) && !$0.contains("baro") && !$0.contains("target") && !$0.contains("mgp") }
        case .baro: return first { $0.contains("baro") }
        case .tps: return first { ($0.contains("throttle") || $0.hasPrefix("tps") || $0.hasPrefix("tp ") || $0.hasPrefix("tp(") || $0 == "tp" || $0.contains("tp (main)") || $0.contains("tp main")) && !$0.contains("target") && !$0.contains("error") }
        case .target: return first { $0.contains("lambda") && $0.contains("target") }
        case .targetAFR: return first { $0.contains("afr") && $0.contains("target") }
        case .lambda:
            return first { $0.contains("lambda") && $0.contains("measured") }
                ?? first { $0.contains("lambda") && !$0.contains("target") && !$0.contains("trim") && !$0.contains("corr") && !$0.contains("error") && !cl($0) }
        case .afr: return first { $0.contains("afr") && !$0.contains("target") && !$0.contains("error") }
        case .clTrim: return first { cl($0) && ($0.contains("corr") || $0.contains("trim") || $0.contains("stft")) && !$0.contains("ltt") && !$0.contains("long") && !$0.contains("ltft") }
        case .clLTT: return first { ($0.contains("ltt") || $0.contains("long term") || $0.contains("ltft")) && ($0.contains("cl") || $0.contains("fuel") || $0.contains("trim") || $0.contains("ltft")) }
        case .ect: return first { $0.contains("coolant") || $0.hasPrefix("ect") }
        case .iat: return first { $0.contains("intake air") || $0.hasPrefix("iat") || $0.contains("air temp") }
        case .knockCount: return first { $0.contains("knock") && $0.contains("count") }
        case .knockRetard: return first { $0.contains("knock") && ($0.contains("retard") || $0.contains("ign corr") || $0.contains("ign trim")) }
        case .knockLevel: return first { $0.contains("knock") && $0.contains("level") && !$0.contains("thresh") }
        case .duty: return first { $0.contains("duty") && $0.contains("inj") }
        case .ignition: return first { $0.contains("final ign") } ?? first { $0.contains("ignition angle") || $0.contains("ign angle") } ?? first { $0.contains("ignition") && !$0.contains("trim") && !$0.contains("base") }
        case .oilP: return first { $0.contains("oil") && $0.contains("press") }
        case .fuelP: return first { $0.contains("fuel") && $0.contains("press") }
        }
    }

    /// One log, with derived channels (AFR → lambda, MAP − baro → MGP, summed knock counts).
    struct Channels {
        let log: LogTable
        let n: Int
        init(_ log: LogTable) { self.log = log; n = log.time.count }
        func raw(_ k: Kind) -> [Double?]? { LogAnalysis.column(k, in: log.columns).map { log.data[$0] } }
        var rpm: [Double?]? { raw(.rpm) }
        var map: [Double?]? {
            if let m = raw(.map) { return m }
            if let g = raw(.mgp) { let b = raw(.baro); return (0..<n).map { i in g[i].map { $0 + (b?[i] ?? nil ?? 101.3) } } }
            return nil
        }
        var mgp: [Double?]? {
            if let g = raw(.mgp) { return g }
            if let m = raw(.map) { let b = raw(.baro); return (0..<n).map { i in m[i].map { $0 - (b?[i] ?? nil ?? 101.3) } } }
            return nil
        }
        var lambda: [Double?]? { raw(.lambda) ?? raw(.afr).map { $0.map { $0.map { $0 / 14.7 } } } }
        var target: [Double?]? { raw(.target) ?? raw(.targetAFR).map { $0.map { $0.map { $0 / 14.7 } } } }
        var trim: [Double?]? {
            let st = raw(.clTrim), lt = raw(.clLTT)
            guard st != nil || lt != nil else { return nil }
            return (0..<n).map { i in
                let a = st?[i] ?? nil, b = lt?[i] ?? nil
                return a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0)
            }
        }
        /// Knock counts from every per-cylinder count column, summed.
        var knockCount: [Double?]? {
            let idx = log.columns.indices.filter { let s = log.columns[$0].lowercased(); return s.contains("knock") && s.contains("count") }
            guard !idx.isEmpty else { return nil }
            return (0..<n).map { i in idx.reduce(0.0) { $0 + (log.data[$1][i] ?? 0) } }
        }
        /// Largest knock retard across cylinders, in positive degrees.
        var knockRetard: [Double?]? {
            let idx = log.columns.indices.filter { let s = log.columns[$0].lowercased(); return s.contains("knock") && (s.contains("retard") || s.contains("ign corr") || s.contains("ign trim")) }
            guard !idx.isEmpty else { return nil }
            return (0..<n).map { i in idx.map { abs(log.data[$0][i] ?? 0) }.max() ?? 0 }
        }
        func axis(_ a: TableAxis) -> [Double?]? {
            let s = (a.source + " " + a.unit).lowercased()
            if s.contains("gauge") || s.contains("mgp") { return mgp }
            if s.contains("speed") || s.contains("rpm") { return rpm }
            if s.contains("map") || s.contains("manifold") || s.contains("absolute") || s.contains("kpa") { return map }
            if s.contains("throttle") || s.contains("tps") || s.hasPrefix("tp") { return raw(.tps) }
            if s.contains("coolant") || s.contains("ect") { return raw(.ect) }
            if s.contains("air temp") || s.contains("iat") { return raw(.iat) }
            let src = a.source.lowercased()
            return log.columns.firstIndex { $0.lowercased().contains(src) }.map { log.data[$0] }
        }
    }

    /// Lambda sensor + exhaust transport delay: long at idle, short at high RPM.
    static func sensorDelay(rpm: Double) -> Double { max(0.08, min(0.6, 0.05 + 300 / max(rpm, 500))) }

    init(logs: [(name: String, table: LogTable)], tune: TuneFile?, catalog: Catalog?, minSamples: Int? = nil, options: Options = Options()) {
        guard !logs.isEmpty else { return }
        var opts = options
        if let minSamples { opts.minWeight = Double(minSamples) }
        var text = ""

        // Tables this analysis works on.
        var fuelTables: [(id: Int, x: TableAxis, y: TableAxis)] = []
        var ignTables: [(id: Int, x: TableAxis, y: TableAxis)] = []
        var targetTable: (x: TableAxis?, y: TableAxis?, p: TuneFile.Parameter)?
        if let tune { (fuelTables, ignTables, targetTable) = LogAnalysis.tables(tune, catalog) }

        var fuelStats: [Int: [[Int]: (w: Double, f: Double, m: Double, t: Double, trim: Double)]] = [:]
        var knockStats: [Int: [[Int]: KnockCell]] = [:]
        var anyTrim = false, trimSum = 0.0, trimN = 0, used = 0, rejected = (cold: 0, transient: 0, overrun: 0, range: 0)

        for (name, log) in logs {
            let ch = Channels(log)
            let n = ch.n
            let cols = log.columns
            let duration = (log.time.last ?? 0) - (log.time.first ?? 0)
            text += "### Log “\(name)” — \(LogAnalysis.f((duration * 10).rounded() / 10)) s, \(n) samples\n"
            text += "Channels: " + cols.joined(separator: ", ") + "\n"
            var ranges: [String] = []
            for (i, c) in cols.enumerated() {
                let v = log.data[i].compactMap { $0 }
                guard let lo = v.min(), let hi = v.max() else { continue }
                ranges.append("\(c): \(LogAnalysis.f(lo))–\(LogAnalysis.f(hi)) (avg \(LogAnalysis.f(v.reduce(0, +) / Double(v.count))))")
            }
            if !ranges.isEmpty { text += "Ranges: " + ranges.joined(separator: "; ") + "\n" }

            let rpm = ch.rpm, mgp = ch.mgp, tps = ch.raw(.tps), lam = ch.lambda, tgt = ch.target, trim = ch.trim
            let ect = ch.raw(.ect), iat = ch.raw(.iat), duty = ch.raw(.duty), oil = ch.raw(.oilP)
            let kCount = ch.knockCount, kRetard = ch.knockRetard
            var warn: [String] = []
            func at(_ i: Int) -> String { LogAnalysis.f((log.time[i] * 10).rounded() / 10) + " s" }
            if let lam, let mgp {
                let lean = (0..<n).filter { (mgp[$0] ?? -99) > 20 && (lam[$0] ?? 0) > 0.9 && (lam[$0] ?? 0) < 1.4 }
                if let worst = lean.max(by: { (lam[$0] ?? 0) < (lam[$1] ?? 0) }) {
                    warn.append("LEAN UNDER BOOST: \(lean.count) samples above 20 kPa boost with lambda > 0.90 (worst \(LogAnalysis.f(lam[worst]!)) at \(at(worst)), \(LogAnalysis.f(rpm?[worst] ?? nil ?? 0)) RPM, \(LogAnalysis.f(mgp[worst]!)) kPa boost)")
                }
            }
            var knockEvents: [Int] = []
            if let kCount {
                for i in 1..<max(n, 1) where (kCount[i] ?? 0) > (kCount[i - 1] ?? 0) { knockEvents.append(i) }
            } else if let kRetard {
                for i in 1..<max(n, 1) where (kRetard[i] ?? 0) > 0.1 && (kRetard[i] ?? 0) > (kRetard[i - 1] ?? 0) + 0.1 { knockEvents.append(i) }
            }
            if !knockEvents.isEmpty {
                let peak = kRetard?.compactMap { $0 }.max() ?? 0
                warn.append("KNOCK: \(knockEvents.count) events (first at \(at(knockEvents[0]))\(peak > 0 ? ", up to \(LogAnalysis.f(peak))° retard" : ""))")
            }
            if let ect, let hi = ect.compactMap({ $0 }).max(), hi > 105 { warn.append("Coolant reached \(LogAnalysis.f(hi)) °C") }
            if let iat, let hi = iat.compactMap({ $0 }).max(), hi > 60 { warn.append("Intake air reached \(LogAnalysis.f(hi)) °C (heat soak / intercooler)") }
            if let duty, let hi = duty.compactMap({ $0 }).max(), hi > 85 { warn.append("Injector duty reached \(LogAnalysis.f(hi)) % (injectors near their limit)") }
            if let oil, let rpm {
                let low = (0..<n).filter { (rpm[$0] ?? 0) > 3000 && (oil[$0] ?? 999) < 150 }
                if !low.isEmpty { warn.append("Low oil pressure above 3000 RPM in \(low.count) samples (first at \(at(low[0])))") }
            }
            if let ect, let lo = ect.compactMap({ $0 }).min(), lo < opts.warmECT { warn.append("Engine not fully warm in part of this log (coolant down to \(LogAnalysis.f(lo)) °C); those samples are left out of fuel corrections") }
            if lam == nil { warn.append("No lambda/AFR channel: fuel can't be corrected from this log") }
            if lam != nil && tgt == nil && targetTable == nil { warn.append("No target lambda channel or table: corrections unavailable") }
            if let trim, trim.contains(where: { abs($0 ?? 0) > 0.05 }) { anyTrim = true }
            warnings += warn.map { name + ": " + $0 }
            text += warn.isEmpty ? "Warnings: none\n" : warn.map { "Warning: " + $0 }.joined(separator: "\n") + "\n"

            // Knock events → ignition table cells.
            for it in ignTables {
                guard let xs = ch.axis(it.x), let ys = ch.axis(it.y) else { continue }
                for i in knockEvents {
                    guard let xv = xs[i], let yv = ys[i] else { continue }
                    let key = [CopilotPlanner.nearest(it.y, count: it.y.active, yv), CopilotPlanner.nearest(it.x, count: it.x.active, xv)]
                    var c = knockStats[it.id, default: [:]][key] ?? KnockCell(events: 0, maxRetard: 0)
                    c.events += 1; c.maxRetard = max(c.maxRetard, kRetard?[i] ?? nil ?? 0)
                    knockStats[it.id, default: [:]][key] = c
                }
            }

            // Fuel: warm, steady samples → bilinear weights on each fuel table.
            guard let lam, n > 1 else { text += LogAnalysis.sampleListing(log); continue }
            var lastTransient = -Double.infinity
            var j = 0   // pointer for the delayed lambda lookup
            for i in 0..<n {
                let t = log.time[i]
                if i > 0, let tp = tps, let a = tp[i], let b = tp[i - 1] {
                    let dt = t - log.time[i - 1]
                    if dt > 0, abs(a - b) / dt > 20 { lastTransient = t }
                }
                let r = rpm?[i] ?? nil
                if let r, r < 400 { continue }
                if let e = ect?[i], e < opts.warmECT { rejected.cold += 1; continue }
                if let tp = tps?[i], let r, tp < 1.5, r > 1400 { rejected.overrun += 1; continue }
                if t - lastTransient < 0.6 { rejected.transient += 1; continue }
                // Measured lambda for this moment arrives after the sensor delay.
                var m: Double?
                if opts.delayCompensation, let r {
                    let tt = t + LogAnalysis.sensorDelay(rpm: r)
                    while j > 0 && log.time[j] > tt { j -= 1 }
                    while j < n - 1 && log.time[j + 1] < tt { j += 1 }
                    if j + 1 < n, log.time[j] <= tt, let a = lam[j], let b = lam[j + 1] {
                        let span = log.time[j + 1] - log.time[j]
                        m = span > 0 ? a + (b - a) * (tt - log.time[j]) / span : a
                        // Throttle must not move during the delay, or the reading belongs to another condition.
                        if let tp = tps, let p0 = tp[i], let p1 = tp[j + 1], abs(p1 - p0) > 3 { rejected.transient += 1; continue }
                    } else if tt > (log.time.last ?? 0) { continue }
                } else { m = lam[i] }
                guard let measured = m, (0.65...1.35).contains(measured) else { rejected.range += 1; continue }
                var target = tgt?[i] ?? nil
                if target == nil, let tt = targetTable {
                    target = LogAnalysis.interpolate(tt.p, x: tt.x, y: tt.y, xv: tt.x.flatMap { ch.axis($0) }?[i] ?? nil, yv: tt.y.flatMap { ch.axis($0) }?[i] ?? nil)
                }
                guard let tv = target, (0.6...1.6).contains(tv) else { continue }
                let tr = opts.includeTrim ? (trim?[i] ?? nil ?? 0) : 0
                if trim != nil { trimSum += tr; trimN += 1 }
                let factor = max(0.7, min(1.3, measured / tv * (1 + tr / 100)))
                used += 1
                for ft in fuelTables {
                    guard let xv = ch.axis(ft.x)?[i] ?? nil, let yv = ch.axis(ft.y)?[i] ?? nil else { continue }
                    for (key, w) in LogAnalysis.weights(ft.x, ft.y, xv, yv) where w > 0.01 {
                        var s = fuelStats[ft.id, default: [:]][key] ?? (0, 0, 0, 0, 0)
                        s.w += w; s.f += w * factor; s.m += w * measured; s.t += w * tv; s.trim += w * tr
                        fuelStats[ft.id, default: [:]][key] = s
                    }
                }
            }
            text += LogAnalysis.sampleListing(log)
        }

        let usedNote = "Fuel analysis used \(used) samples; left out \(rejected.cold) cold, \(rejected.transient) throttle-transient, \(rejected.overrun) overrun/fuel-cut, \(rejected.range) out-of-range lambda. Lambda readings shifted for sensor delay (\(Int(LogAnalysis.sensorDelay(rpm: 1000) * 1000)) ms at 1000 RPM, \(Int(LogAnalysis.sensorDelay(rpm: 6000) * 1000)) ms at 6000 RPM)."
        if anyTrim { text += "\nClosed-loop lambda trim was active (average \(LogAnalysis.f((trimSum / Double(max(trimN, 1)) * 10).rounded() / 10)) %). It's included in the corrections, so they show what the table needs with no trim.\n" }

        for ft in fuelTables {
            guard let cells = fuelStats[ft.id], !cells.isEmpty else { continue }
            var map: [[Int]: Correction] = [:]
            for (k, s) in cells where s.w >= opts.minWeight {
                map[k] = Correction(percent: (s.f / s.w - 1) * 100, weight: s.w, measured: s.m / s.w, target: s.t / s.w, trim: s.trim / s.w)
            }
            guard !map.isEmpty else { continue }
            corrections[ft.id] = map
            text += "\n### Lambda correction map for \(catalog?.name(ft.id) ?? "D\(ft.id)") [D\(ft.id)]\n" + usedNote + "\n"
            text += "Cell = suggested fuel change % (+ = lean, add fuel) and weighted sample count. Rows: \(ft.y.title). Columns: \(ft.x.title). Cells without enough data are “·”.\n"
            text += LogAnalysis.grid(map.mapValues { CopilotPlan.signed($0.percent) + "% (\(Int($0.weight.rounded())))" }, x: ft.x, y: ft.y)
            text += "Use op \"lambda_correct\" on [D\(ft.id)] to apply this map, then \"smooth\" lightly if the edges step.\n"
        }
        for it in ignTables {
            guard let cells = knockStats[it.id], !cells.isEmpty else { continue }
            knock[it.id] = cells
            text += "\n### Knock map for \(catalog?.name(it.id) ?? "D\(it.id)") [D\(it.id)]\nCell = knock events (max retard °). Rows: \(it.y.title). Columns: \(it.x.title).\n"
            text += LogAnalysis.grid(cells.mapValues { "\($0.events)" + ($0.maxRetard > 0 ? " (\(LogAnalysis.f($0.maxRetard))°)" : "") }, x: it.x, y: it.y)
            text += "Use op \"knock_retard\" on [D\(it.id)] with value = degrees to pull (2 is typical) to retard these cells and half that in their neighbours.\n"
        }
        digest = text
    }

    /// The fuel tables, ignition tables and lambda target table that logs are analysed against.
    static func tables(_ tune: TuneFile, _ catalog: Catalog?) -> (fuel: [(id: Int, x: TableAxis, y: TableAxis)], ign: [(id: Int, x: TableAxis, y: TableAxis)], target: (x: TableAxis?, y: TableAxis?, p: TuneFile.Parameter)?) {
        func key(_ id: Int) -> String { (catalog?.byId[id]?.name ?? "").lowercased().filter { $0.isLetter || $0.isNumber } }
        func scalar(_ name: String) -> Double? {
            tune.parameters.first { key($0.dataId) == name && $0.scalar != nil }?.scalar
        }
        let dualFuel = (scalar("dualfueltablemode") ?? 0) != 0
        let dualIgn = (scalar("dualignitiontablemode") ?? scalar("dualigntablemode") ?? 0) != 0
        var fuel: [(id: Int, x: TableAxis, y: TableAxis)] = [], ign: [(id: Int, x: TableAxis, y: TableAxis)] = []
        var target: (x: TableAxis?, y: TableAxis?, p: TuneFile.Parameter)?
        for p in tune.parameters where !p.readOnly && p.rows.count > 1 {
            let k = key(p.dataId)
            let ax = TuneAxes.axes(for: p.dataId, in: tune, catalog: catalog)
            guard let x = ax.x, let y = ax.y else { continue }
            let second = k.hasSuffix("2")
            if k.contains("fueltable") && !k.contains("ratio") && !k.contains("trim") && (!second || dualFuel) { fuel.append((p.dataId, x, y)) }
            if (k.contains("igntable") || k.contains("ignitiontable")) && !k.contains("ratio") && !k.contains("trim") && (!second || dualIgn) { ign.append((p.dataId, x, y)) }
            if target == nil && k.contains("lambda") && k.contains("target") && !k.contains("trim") && !second { target = (x, y, p) }
        }
        return (fuel, ign, target)
    }

    /// Bilinear weights of a point over the four surrounding cells ([row, col] → weight, summing to 1).
    static func weights(_ x: TableAxis, _ y: TableAxis, _ xv: Double, _ yv: Double) -> [[Int]: Double] {
        let (c0, c1, fx) = locate(x, xv), (r0, r1, fy) = locate(y, yv)
        var w: [[Int]: Double] = [:]
        w[[r0, c0], default: 0] += (1 - fx) * (1 - fy)
        w[[r0, c1], default: 0] += fx * (1 - fy)
        w[[r1, c0], default: 0] += (1 - fx) * fy
        w[[r1, c1], default: 0] += fx * fy
        return w
    }

    /// Lower index, upper index and fraction between them, clamped to the axis' active breakpoints.
    static func locate(_ axis: TableAxis?, _ v: Double?) -> (Int, Int, Double) {
        guard let axis, let v else { return (0, 0, 0) }
        let vals = axis.activeValues
        guard vals.count > 1 else { return (0, 0, 0) }
        if v <= vals[0] { return (0, 0, 0) }
        if v >= vals[vals.count - 1] { return (vals.count - 1, vals.count - 1, 0) }
        for i in 1..<vals.count where v <= vals[i] {
            let d = vals[i] - vals[i - 1]
            return (i - 1, i, d == 0 ? 0 : (v - vals[i - 1]) / d)
        }
        return (0, 0, 0)
    }

    static func grid(_ cells: [[Int]: String], x: TableAxis, y: TableAxis) -> String {
        let rows = Set(cells.keys.map { $0[0] }).sorted(), cols = Set(cells.keys.map { $0[1] }).sorted()
        var s = "| \(y.unit.isEmpty ? "Y" : y.unit) \\ \(x.unit.isEmpty ? "X" : x.unit) | " + cols.map { TuneExport.num(x.values[$0]) }.joined(separator: " | ") + " |\n"
        s += "|---|" + String(repeating: "---|", count: cols.count) + "\n"
        for r in rows { s += "| **\(TuneExport.num(y.values[r]))** | " + cols.map { cells[[r, $0]] ?? "·" }.joined(separator: " | ") + " |\n" }
        return s
    }

    /// A short, evenly spaced listing so questions about moments in the log can be answered.
    static func sampleListing(_ log: LogTable) -> String {
        let n = log.time.count, shown = min(n, 40)
        guard shown > 0 else { return "\n" }
        var s = "Samples (\(shown) of \(n), evenly spaced):\n```csv\ntime_s," + log.columns.joined(separator: ",") + "\n"
        for k in 0..<shown {
            let i = shown > 1 ? k * (n - 1) / (shown - 1) : 0
            s += f(log.time[i]) + "," + log.data.map { $0[i].map(f) ?? "" }.joined(separator: ",") + "\n"
        }
        return s + "```\n\n"
    }

    static func f(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
        return TuneExport.num((v * 1000).rounded() / 1000)
    }

    /// Bilinear lookup in a table using its active breakpoints.
    static func interpolate(_ p: TuneFile.Parameter, x: TableAxis?, y: TableAxis?, xv: Double?, yv: Double?) -> Double? {
        guard !p.rows.isEmpty else { return p.scalar }
        let (c0, c1, fx) = locate(x, xv), (r0, r1, fy) = locate(y, yv)
        guard p.rows.indices.contains(r1), p.rows[r0].indices.contains(c1), p.rows[r1].indices.contains(c1) else { return nil }
        let top = p.rows[r0][c0] * (1 - fx) + p.rows[r0][c1] * fx
        let bottom = p.rows[r1][c0] * (1 - fx) + p.rows[r1][c1] * fx
        return top * (1 - fy) + bottom * fy
    }
}

// MARK: - Automatic tune check (no AI)

/// Rule-based checks a tuner runs before a dyno day. Findings go to the model and the user.
enum TuneCheck {
    struct Finding: Hashable { let severity: Int; let text: String }   // 2 = danger, 1 = check, 0 = note

    static func run(tune: TuneFile, catalog: Catalog?, analysis: LogAnalysis? = nil) -> [Finding] {
        var out: [Finding] = []
        func key(_ id: Int) -> String { (catalog?.byId[id]?.name ?? "").lowercased().filter { $0.isLetter || $0.isNumber } }
        func name(_ id: Int) -> String { catalog?.name(id) ?? "D\(id)" }
        func scalar(_ k: String) -> (id: Int, v: Double)? {
            tune.parameters.first { key($0.dataId) == k && $0.scalar != nil }.map { ($0.dataId, $0.scalar!) }
        }
        let (fuel, ign, target) = LogAnalysis.tables(tune, catalog)
        func boost(_ axis: TableAxis, _ v: Double) -> Double {   // kPa of boost for a load breakpoint
            let s = (axis.source + axis.unit).lowercased()
            if s.contains("gauge") || s.contains("mgp") { return v }
            if s.contains("map") || s.contains("absolute") { return v - 101.3 }
            return -999
        }
        func at(_ x: TableAxis, _ y: TableAxis, _ r: Int, _ c: Int) -> String {
            "\(TuneExport.num(x.values[c])) \(x.unit.isEmpty ? x.source : x.unit) / \(TuneExport.num(y.values[r])) \(y.unit.isEmpty ? y.source : y.unit)"
        }
        let boosted = fuel.contains { ft in ft.y.activeValues.contains { boost(ft.y, $0) > 15 } }

        for ft in fuel {
            guard let p = tune.parameter(ft.id) else { continue }
            var steps: [(Double, Int, Int)] = []
            let limits = (catalog?.byId[ft.id]).flatMap { e in Double(e.min).flatMap { lo in Double(e.max).map { (lo, $0) } } }
            var pinned = 0
            for r in 0..<min(ft.y.active, p.rows.count) {
                for c in 0..<min(ft.x.active, p.rows[r].count) {
                    let v = p.rows[r][c]
                    if let l = limits, v <= l.0 || v >= l.1 { pinned += 1 }
                    for (dr, dc) in [(0, 1), (1, 0)] {
                        let rr = r + dr, cc = c + dc
                        guard rr < min(ft.y.active, p.rows.count), cc < min(ft.x.active, p.rows[rr].count) else { continue }
                        let o = p.rows[rr][cc], base = max(abs(v), abs(o), 1e-9)
                        let pct = abs(o - v) / base * 100
                        if pct > 15 { steps.append((pct, r, c)) }
                    }
                }
            }
            if let worst = steps.max(by: { $0.0 < $1.0 }) {
                out.append(Finding(severity: 1, text: "\(name(ft.id)): \(steps.count) steps over 15 % between neighbouring cells (worst \(Int(worst.0)) % near \(at(ft.x, ft.y, worst.1, worst.2))). Rough fuel tables cause surging; smooth them."))
            }
            if pinned > 0 { out.append(Finding(severity: 1, text: "\(name(ft.id)): \(pinned) cells sit at the table's limit, so they can't be corrected further.")) }
        }

        for it in ign {
            guard let p = tune.parameter(it.id) else { continue }
            var rising = 0, bigSteps = 0
            var worst: (Double, Int, Int)?
            for c in 0..<it.x.active {
                for r in 1..<min(it.y.active, p.rows.count) where c < p.rows[r].count {
                    let up = p.rows[r][c] - p.rows[r - 1][c]
                    if boost(it.y, it.y.values[r]) > 5 && up > 0.5 { rising += 1; if worst == nil || up > worst!.0 { worst = (up, r, c) } }
                    if abs(up) > 5 { bigSteps += 1 }
                }
            }
            if rising > 0, let w = worst {
                out.append(Finding(severity: 2, text: "\(name(it.id)): timing increases with boost in \(rising) places (e.g. +\(TuneExport.num((w.0 * 10).rounded() / 10))° at \(at(it.x, it.y, w.1, w.2))). Timing normally comes down as boost goes up; check for knock risk."))
            }
            if bigSteps > 0 { out.append(Finding(severity: 1, text: "\(name(it.id)): \(bigSteps) steps over 5° between neighbouring load cells.")) }
        }

        if let tt = target, let x = tt.x, let y = tt.y {
            var lean: [(Double, Int, Int)] = []
            for r in 0..<min(y.active, tt.p.rows.count) where boost(y, y.values[r]) > 20 {
                for c in 0..<min(x.active, tt.p.rows[r].count) where tt.p.rows[r][c] > 0.9 { lean.append((tt.p.rows[r][c], r, c)) }
            }
            if let w = lean.max(by: { $0.0 < $1.0 }) {
                out.append(Finding(severity: 2, text: "\(name(tt.p.dataId)): \(lean.count) cells target leaner than 0.90 λ above 20 kPa boost (up to \(TuneExport.num(w.0)) at \(at(x, y, w.1, w.2))). Most petrol engines want 0.78–0.85 λ on boost."))
            }
        }

        if let dead = tune.parameters.first(where: { key($0.dataId).contains("injectordeadtimeprim") || key($0.dataId) == "injectordeadtime" }),
           !dead.rows.isEmpty, dead.rows.flatMap({ $0 }).allSatisfy({ $0 == 0 }) {
            out.append(Finding(severity: 2, text: "\(name(dead.dataId)) is all zero. Without injector dead times the fuelling changes with battery voltage and idle/low load will be wrong."))
        }
        if boosted, let k = scalar("knockmode"), k.v == 0 {
            out.append(Finding(severity: 1, text: "Knock Mode [D\(k.id)] is 0 (normally Off) on a boosted tune. Without knock detection, timing changes under boost need extra care."))
        }
        if let c = scalar("closedlooplambdamode"), c.v == 0 {
            out.append(Finding(severity: 0, text: "Closed Loop Lambda Mode [D\(c.id)] is 0 (normally Off). Fine for tuning, but the car won't correct its own fuelling on the road."))
        }
        if let rl = tune.parameters.first(where: { key($0.dataId) == "rpmlimit" || key($0.dataId) == "enginespeedlimit" }), let v = rl.scalar ?? rl.rows.first?.first {
            out.append(Finding(severity: v <= 0 ? 2 : 0, text: v <= 0 ? "\(name(rl.dataId)) is 0 — check the rev limiter is set." : "Rev limit (\(name(rl.dataId))): \(TuneExport.num(v)) RPM."))
        }
        if let analysis {
            for w in analysis.warnings where w.contains("LEAN") || w.contains("KNOCK") || w.contains("Injector duty") || w.contains("oil") {
                out.append(Finding(severity: 2, text: "Log: " + w))
            }
        }
        if out.isEmpty { out.append(Finding(severity: 0, text: "No automatic findings.")) }
        return out.sorted { $0.severity > $1.severity }
    }

    static func text(_ findings: [Finding]) -> String {
        findings.map { ($0.severity == 2 ? "DANGER: " : $0.severity == 1 ? "CHECK: " : "Note: ") + $0.text }.joined(separator: "\n")
    }
}

// MARK: - What the model reads

enum TuneContext {
    static func build(tune: TuneFile?, catalog: Catalog?, fileName: String, focusID: Int?, mainTables: [Int],
                      extraTables: Set<Int>, blocked: Set<Int>, logs: LogAnalysis?, live: String?, modified: Set<Int> = []) -> String {
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
        s += "\n# TUNE CHECK (automatic rules, no AI)\n" + TuneCheck.text(TuneCheck.run(tune: tune, catalog: catalog, analysis: logs)) + "\n"
        if !modified.isEmpty {
            s += "\n# EDITED SINCE THE TUNE WAS OPENED\n" + modified.sorted().map { "\(catalog?.name($0) ?? "D\($0)") [D\($0)]" }.joined(separator: ", ") + "\n"
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
    - Closed-loop trim is already folded into the lambda correction map; don't add it again.
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
    - op: "set" (to value), "add" (add value, same units), "percent" (change by value %, e.g. 5 or -3), "multiply", "lambda_correct" (apply the logged lambda correction map to the region; value = max % per cell, default 15), "knock_retard" (pull value degrees from cells that knocked in the logs and half that from their neighbours; default 2), "smooth" (value = strength 0–1, default 0.5).
    - x, y: [from, to] in the axis' own units (RPM, kPa, %…), inclusive. Omit an axis for all of it. Use breakpoints from the table when you can.
    - cells: exact values for individual cells, [[x, y, value], …] using axis values, or [[axisValue, value], …] for 1-D tables. Use with op "set". Use this to write a full new table or a hand-shaped region.
    - For a single setting give just id, op and value.
    - Use several items for several tables or regions. Only use DataIds from the context. Don't mention the JSON in your text; the user sees a preview card for each item.
    Never say a change has been applied; tell the user to review and hit Apply.

    Charts
    To show data from an attached log, add a block tagged `chart` with JSON: {"log": "file name (optional)", "x": "time" or a channel, "y": ["channel", ...], "kind": "line" or "scatter", "title": "..."}. Channel names can be partial (e.g. "Lambda", "RPM"). Use charts when a picture explains it faster, e.g. lambda vs target over a pull, or knock vs RPM.

    Tune check
    TUNE CHECK lists rule-based findings (DANGER / CHECK / Note). When the user asks you to check the tune, go through them like a pro, say which matter and why, and propose fixes.

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
