import Foundation

/// Human/AI-readable exports of a decrypted tune: Markdown, JSON, comparison report.
public enum TuneExport {

    public struct Options {
        public var includeReadOnly = false     // runtime values: not tune settings
        public var trimUnusedAxis = true       // drop breakpoints past the configured axis size
        public init() {}
    }

    // MARK: formatting

    public static func num(_ v: Double, dp: Int? = nil) -> String {
        if !v.isFinite { return "—" }
        if v == v.rounded() && abs(v) < 1e12 { return String(Int(v)) }
        if let dp, dp >= 0 { return trimZeros(String(format: "%.\(dp)f", v)) }
        return trimZeros(String(format: "%.3f", v))
    }
    static func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }

    struct Meta {
        let name: String, category: String, unit: String, dp: Int?
    }
    static func meta(_ id: Int, _ catalog: Catalog?) -> Meta {
        let e = catalog?.byId[id]
        return Meta(name: e?.name ?? "D\(id)",
                    category: Catalog.prettyGroup(e?.topic ?? ""),
                    unit: TuneAxes.unit(e),
                    dp: e.flatMap { Int($0.dp) })
    }

    /// DataIds that only exist as another table's axis breakpoints.
    static func axisLabelIds(_ catalog: Catalog?) -> Set<Int> {
        var s = Set<Int>()
        for e in (catalog?.byId ?? [:]).values { if let x = e.xl { s.insert(x) }; if let y = e.yl { s.insert(y) } }
        return s
    }

    /// Visible slice of a table (respecting axis trimming) plus its axes.
    struct TableView {
        let rows: [[Double]]
        let x: TableAxis?
        let y: TableAxis?
        let fullRows: Int, fullCols: Int
    }
    static func view(_ p: TuneFile.Parameter, _ tune: TuneFile, _ catalog: Catalog?, trim: Bool) -> TableView {
        let ax = TuneAxes.axes(for: p.dataId, in: tune, catalog: catalog)
        let fullR = p.rows.count, fullC = p.rows.first?.count ?? 0
        var nr = fullR, nc = fullC
        if trim {
            if let x = ax.x { nc = min(nc, x.active) }
            if let y = ax.y { nr = min(nr, y.active) }
        }
        let rows = p.rows.prefix(nr).map { Array($0.prefix(nc)) }
        return TableView(rows: rows, x: ax.x, y: ax.y, fullRows: fullR, fullCols: fullC)
    }

    static func tableMarkdown(_ p: TuneFile.Parameter, _ tune: TuneFile, _ catalog: Catalog?,
                              trim: Bool, cell: ((Int, Int, Double) -> String)? = nil) -> String {
        let m = meta(p.dataId, catalog)
        let v = view(p, tune, catalog, trim: trim)
        var s = "### \(esc(m.name))\(m.unit.isEmpty ? "" : " — \(m.unit)") [D\(p.dataId)]\n"
        var info: [String] = []
        if let x = v.x { info.append("X (columns): \(x.title)") }
        if let y = v.y { info.append("Y (rows): \(y.title)") }
        let shown = "\(v.rows.count)×\(v.rows.first?.count ?? 0)"
        info.append(shown == "\(v.fullRows)×\(v.fullCols)" ? "size \(shown)" : "showing \(shown) of \(v.fullRows)×\(v.fullCols) (rest unused)")
        if p.readOnly { info.append("read-only") }
        s += info.joined(separator: " · ") + "\n\n"
        let cols = v.rows.first?.count ?? 0
        guard cols > 0 else { return s + "_(empty)_\n\n" }
        let xHead = (0..<cols).map { c in v.x.map { c < $0.values.count ? num($0.values[c]) : "" } ?? "c\(c)" }
        s += "| \(v.y != nil ? "Y \\ X" : "row") | " + xHead.joined(separator: " | ") + " |\n"
        s += "|---|" + String(repeating: "---|", count: cols) + "\n"
        for (r, row) in v.rows.enumerated() {
            let yHead = v.y.map { r < $0.values.count ? num($0.values[r]) : "" } ?? "r\(r)"
            let cells = row.enumerated().map { c, val in cell?(r, c, val) ?? num(val, dp: m.dp) }
            s += "| **\(yHead)** | " + cells.joined(separator: " | ") + " |\n"
        }
        return s + "\n"
    }

    static func header(_ tune: TuneFile, title: String) -> String {
        let mem = tune.memory
        var s = "# Link ECU tune: \(title)\n\n"
        s += "- ECU: Link ID \(mem.linkID), firmware \(mem.firmware), bootcode \(mem.bootcode), HW rev \(mem.hwRevision), serial \(mem.serialNumber)\n"
        if !mem.memo.isEmpty { s += "- Memo: \(mem.memo)\n" }
        s += "- Exported by OpenLink Tuner, \(ISO8601DateFormatter().string(from: Date()))\n\n"
        return s
    }

    static let howToRead = """
    ## How to read this
    - Values are exactly as PCLink shows them (engineering units).
    - Tables: the header row holds the X-axis breakpoints, the first column the Y-axis breakpoints.
      Each cell is the table value at that X/Y point.
    - Breakpoints past a table's configured axis size are unused by the ECU and omitted.
    - Every item carries its DataId, e.g. [D2367], so changes can be referred back precisely.
    - Option/mode settings are stored as numeric codes (0, 1, 2…).


    """

    // MARK: full tune → Markdown

    public static func markdown(_ tune: TuneFile, catalog: Catalog?, title: String, options: Options = Options()) -> String {
        var s = header(tune, title: title) + howToRead
        let skip = axisLabelIds(catalog)
        var byCat: [String: [TuneFile.Parameter]] = [:]
        for p in tune.parameters where (options.includeReadOnly || !p.readOnly) && !skip.contains(p.dataId) {
            byCat[meta(p.dataId, catalog).category, default: []].append(p)
        }
        let cats = byCat.keys.sorted { ($0 == "Other" ? "~" : $0) < ($1 == "Other" ? "~" : $1) }
        s += "## Contents\n" + cats.map { "- \($0) (\(byCat[$0]!.count))" }.joined(separator: "\n") + "\n\n"
        for cat in cats {
            let ps = byCat[cat]!.sorted { meta($0.dataId, catalog).name < meta($1.dataId, catalog).name }
            s += "## \(cat)\n\n"
            let scalars = ps.filter { $0.scalar != nil }
            if !scalars.isEmpty {
                s += "| Setting | Value | Unit | DataId |\n|---|---|---|---|\n"
                for p in scalars {
                    let m = meta(p.dataId, catalog)
                    s += "| \(esc(m.name)) | \(num(p.scalar!, dp: m.dp)) | \(m.unit) | D\(p.dataId) |\n"
                }
                s += "\n"
            }
            for p in ps where p.scalar == nil && !p.rows.isEmpty {
                s += tableMarkdown(p, tune, catalog, trim: options.trimUnusedAxis)
            }
        }
        return s
    }

    /// One parameter, ready to paste into a chat.
    public static func parameterMarkdown(_ p: TuneFile.Parameter, tune: TuneFile, catalog: Catalog?) -> String {
        let m = meta(p.dataId, catalog)
        if let v = p.scalar {
            return "\(m.name) [D\(p.dataId)] (\(m.category)) = \(num(v, dp: m.dp))\(m.unit.isEmpty ? "" : " \(m.unit)")\n"
        }
        return "Category: \(m.category)\n" + tableMarkdown(p, tune, catalog, trim: true)
    }

    // MARK: JSON

    public static func json(_ tune: TuneFile, catalog: Catalog?, title: String, options: Options = Options()) -> Data {
        let skip = axisLabelIds(catalog)
        var params: [[String: Any]] = []
        for p in tune.parameters where (options.includeReadOnly || !p.readOnly) && !skip.contains(p.dataId) {
            let m = meta(p.dataId, catalog)
            var d: [String: Any] = ["dataId": p.dataId, "name": m.name, "category": m.category]
            if !m.unit.isEmpty { d["unit"] = m.unit }
            if p.readOnly { d["readOnly"] = true }
            if let v = p.scalar { d["value"] = v }
            else if !p.rows.isEmpty {
                let v = view(p, tune, catalog, trim: options.trimUnusedAxis)
                d["rows"] = v.rows
                if let x = v.x { d["xAxis"] = ["source": x.source, "unit": x.unit, "values": Array(x.values.prefix(v.rows.first?.count ?? 0))] }
                if let y = v.y { d["yAxis"] = ["source": y.source, "unit": y.unit, "values": Array(y.values.prefix(v.rows.count))] }
            }
            params.append(d)
        }
        let mem = tune.memory
        let root: [String: Any] = [
            "title": title,
            "ecu": ["linkId": mem.linkID, "firmware": mem.firmware, "bootcode": mem.bootcode,
                    "hwRevision": mem.hwRevision, "serial": mem.serialNumber, "memo": mem.memo],
            "note": "Values as displayed in PCLink. Table rows = Y axis, columns = X axis.",
            "parameters": params,
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    // MARK: comparison report

    public static func comparisonMarkdown(a: TuneFile, b: TuneFile, nameA: String, nameB: String,
                                          catalog: Catalog?, items: [TuneDiff.Item]) -> String {
        var s = "# Tune comparison\n\n- **A**: \(nameA) (Link ID \(a.memory.linkID), fw \(a.memory.firmware))\n"
        s += "- **B**: \(nameB) (Link ID \(b.memory.linkID), fw \(b.memory.firmware))\n"
        s += "- \(items.count) parameters differ. Cells show `A→B` where they differ.\n\n"
        let skip = axisLabelIds(catalog)
        var byCat: [String: [TuneDiff.Item]] = [:]
        for it in items { byCat[meta(it.dataId, catalog).category, default: []].append(it) }
        for cat in byCat.keys.sorted() {
            s += "## \(cat)\n\n"
            let its = byCat[cat]!.sorted { meta($0.dataId, catalog).name < meta($1.dataId, catalog).name }
            let scalars = its.filter { $0.kind == .scalar || $0.kind == .onlyInA || $0.kind == .onlyInB }
            if !scalars.isEmpty {
                s += "| Setting | A | B | Δ (B−A) | DataId |\n|---|---|---|---|---|\n"
                for it in scalars {
                    let m = meta(it.dataId, catalog)
                    let d = (it.a != nil && it.b != nil) ? num(it.b! - it.a!, dp: m.dp) : ""
                    s += "| \(esc(m.name)) | \(it.a.map { num($0, dp: m.dp) } ?? "—") | \(it.b.map { num($0, dp: m.dp) } ?? "—") | \(d) | D\(it.dataId) |\n"
                }
                s += "\n"
            }
            for it in its where it.kind == .table {
                guard let pa = a.parameter(it.dataId) else { continue }
                let pb = b.parameter(it.dataId)
                let m = meta(it.dataId, catalog)
                if skip.contains(it.dataId) {
                    s += "**Axis breakpoints changed:** \(m.name) [D\(it.dataId)]\n\n"
                }
                s += "_\(it.changedCells) of \(it.totalCells) cells differ, largest change \(num(it.maxAbsDelta, dp: m.dp))_\n\n"
                s += tableMarkdown(pa, a, catalog, trim: false) { r, c, va in
                    guard let pb, r < pb.rows.count, c < pb.rows[r].count else { return num(va, dp: m.dp) }
                    let vb = pb.rows[r][c]
                    return TuneDiff.same(va, vb) ? num(va, dp: m.dp) : "\(num(va, dp: m.dp))→\(num(vb, dp: m.dp))"
                }
            }
        }
        return s
    }
}
