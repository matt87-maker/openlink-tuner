import SwiftUI
import AppKit
import Charts

/// Tuning-software style table editor: axis headers, heat map, range selection,
/// type-to-edit, +/− stepping, scale, interpolate, smooth, copy/paste, compare.
struct TableEditor: View {
    @EnvironmentObject var model: AppModel
    let id: Int

    enum Mode: String, CaseIterable, Identifiable { case values = "This tune", other = "Compared", delta = "Difference"; var id: String { rawValue } }

    @State private var anchor = CellRef(r: 0, c: 0)
    @State private var cursor = CellRef(r: 0, c: 0)
    @State private var buffer: String? = nil        // in-cell typing
    @State private var replaceOnType = false
    @State private var mode: Mode = .values
    @State private var showUnused = false
    @State private var showGraph = false
    @State private var setText = ""
    @State private var stepText = ""
    @State private var pctText = "5"
    @FocusState private var gridFocused: Bool

    private let cw: CGFloat = 58, ch: CGFloat = 24, hw: CGFloat = 72, hh: CGFloat = 26

    // MARK: data

    private var p: TuneFile.Parameter? { _ = model.revision; return model.tune?.parameter(id) }
    private var b: TuneFile.Parameter? { model.compared(id) }
    private var axes: (x: TableAxis?, y: TableAxis?) { model.axes(id) }
    private var fullRows: Int { p?.rows.count ?? 0 }
    private var fullCols: Int { p?.rows.first?.count ?? 0 }
    private var nr: Int { showUnused ? fullRows : min(fullRows, axes.y?.active ?? fullRows) }
    private var nc: Int { showUnused ? fullCols : min(fullCols, axes.x?.active ?? fullCols) }
    private var hasHiddenCells: Bool { nr < fullRows || nc < fullCols }

    private var rect: (r0: Int, r1: Int, c0: Int, c1: Int) {
        (min(anchor.r, cursor.r), max(anchor.r, cursor.r), min(anchor.c, cursor.c), max(anchor.c, cursor.c))
    }
    private var selected: [CellRef] {
        let s = rect
        return (s.r0...s.r1).flatMap { r in (s.c0...s.c1).map { CellRef(r: r, c: $0) } }
    }
    private func isSelected(_ r: Int, _ c: Int) -> Bool {
        let s = rect; return r >= s.r0 && r <= s.r1 && c >= s.c0 && c <= s.c1
    }
    private func value(_ r: Int, _ c: Int) -> Double { p?.rows[safe: r]?[safe: c] ?? 0 }
    private func valueB(_ r: Int, _ c: Int) -> Double? { b?.rows[safe: r]?[safe: c] }
    private func shown(_ r: Int, _ c: Int) -> Double? {
        switch mode {
        case .values: return value(r, c)
        case .other: return valueB(r, c)
        case .delta: return valueB(r, c).map { $0 - value(r, c) }
        }
    }
    private var visibleValues: [Double] {
        (0..<nr).flatMap { r in (0..<nc).compactMap { shown(r, $0) } }
    }
    private var step: Double { Double(stepText) ?? model.step(id) }

    // MARK: body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            if showGraph { graph } else { grid }
            statusBar
        }
        .onAppear {
            stepText = TuneExport.num(model.step(id))
            gridFocused = true
        }
    }

    // MARK: toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("value", text: $setText).frame(width: 64).onSubmit(setSelection)
                Button("Set", action: setSelection).help("Set all selected cells to this value")
                Divider().frame(height: 18)
                Button { adjust(-1) } label: { Image(systemName: "minus") }.help("Decrease selection by step  ( - )")
                TextField("step", text: $stepText).frame(width: 46).help("Step size for + / −")
                Button { adjust(1) } label: { Image(systemName: "plus") }.help("Increase selection by step  ( + )")
                Divider().frame(height: 18)
                TextField("%", text: $pctText).frame(width: 40)
                Button("Scale %") { scale() }.help("Multiply selection by (1 + %/100). Use a negative % to reduce.")
                Divider().frame(height: 18)
                Button { interpolate(horizontal: true) } label: { Label("Interp", systemImage: "arrow.left.and.right") }
                    .help("Interpolate across each selected row (axis-weighted)")
                Button { interpolate(horizontal: false) } label: { Label("Interp", systemImage: "arrow.up.and.down") }
                    .help("Interpolate down each selected column (axis-weighted)")
                Button("Smooth") { smooth() }.help("Average each selected cell with its neighbours")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if model.compare != nil {
                    Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 290).labelsHidden()
                    Button("Copy selection from compared") { model.takeFromCompare(id, cells: selected) }
                        .disabled(b == nil)
                }
                Spacer(minLength: 0)
                if hasHiddenCells || showUnused {
                    Toggle("Show unused cells", isOn: $showUnused).toggleStyle(.checkbox)
                        .help("Breakpoints past the configured axis size aren't used by the ECU")
                }
                Picker("", selection: $showGraph) {
                    Image(systemName: "tablecells").tag(false)
                    Image(systemName: "chart.xyaxis.line").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 90).labelsHidden()
                Menu {
                    Button("Copy selection (⌘C)") { copySelection() }
                    Button("Paste at selection (⌘V)") { pasteFromClipboard() }
                    Button("Select all") { selectAll() }
                    Divider()
                    Button("Revert table to original") { model.revert(id) }.disabled(!model.modifiedIds.contains(id))
                    Button("Copy whole table from compared") { model.takeFromCompare(id) }.disabled(b == nil)
                    Divider()
                    Button("Copy table for AI") { model.copyParamForAI(id) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 34)
            }
        }
        .controlSize(.small)
        .disabled(p?.readOnly == true && model.compare == nil)
    }

    // MARK: grid

    private struct Range { let lo: Double; let hi: Double; let maxAbs: Double }
    private var range: Range {
        let v = visibleValues
        return Range(lo: v.min() ?? 0, hi: v.max() ?? 0, maxAbs: v.map { abs($0) }.max() ?? 0)
    }

    private var grid: some View {
        let rng = range
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        corner
                        ForEach(0..<nc, id: \.self) { c in colHeader(c) }
                    }
                    ForEach(0..<nr, id: \.self) { r in
                        HStack(spacing: 0) {
                            rowHeader(r)
                            ForEach(0..<nc, id: \.self) { c in cell(r, c, rng) }
                        }
                    }
                }
                selectionOutline
            }
            .contentShape(Rectangle())
            .gesture(dragSelect)
            .simultaneousGesture(TapGesture(count: 2).onEnded { beginEdit() })
            .padding(1)
        }
        .frame(minHeight: 200, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(gridFocused ? Color.accentColor.opacity(0.6) : .secondary.opacity(0.25)))
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onKeyPress(phases: .down) { handleKey($0) }
        .onCopyCommand { copySelection(); return [] }
        .onPasteCommand(of: [.plainText, .utf8PlainText]) { _ in pasteFromClipboard() }
    }

    private var corner: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(axes.x.map { short($0.source) } ?? "").font(.system(size: 9)).foregroundStyle(.secondary)
            Text(axes.y.map { short($0.source) } ?? "").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(width: hw, height: hh, alignment: .trailing)
        .padding(.trailing, 2)
        .background(Color.secondary.opacity(0.18))
    }

    private func short(_ s: String) -> String {
        s.replacingOccurrences(of: "Engine Speed", with: "RPM")
         .replacingOccurrences(of: "Manifold Absolute Pressure (MAP)", with: "MAP")
         .replacingOccurrences(of: "Gauge Pressure (MGP)", with: "MGP")
         .replacingOccurrences(of: "Engine Coolant Temperature (ECT)", with: "ECT")
         .replacingOccurrences(of: "Inlet Air Temperature (IAT)", with: "IAT")
    }

    private func colHeader(_ c: Int) -> some View {
        let txt = axes.x.map { c < $0.values.count ? TuneExport.num($0.values[c]) : "" } ?? "\(c + 1)"
        let hot = c >= rect.c0 && c <= rect.c1
        return Text(txt)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .frame(width: cw, height: hh)
            .background(hot ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18))
            .overlay(Rectangle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .opacity(c >= (axes.x?.active ?? Int.max) ? 0.45 : 1)
    }

    private func rowHeader(_ r: Int) -> some View {
        let txt = axes.y.map { r < $0.values.count ? TuneExport.num($0.values[r]) : "" } ?? "\(r + 1)"
        let hot = r >= rect.r0 && r <= rect.r1
        return Text(txt)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .frame(width: hw, height: ch, alignment: .trailing)
            .padding(.trailing, 0)
            .background(hot ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18))
            .overlay(Rectangle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .opacity(r >= (axes.y?.active ?? Int.max) ? 0.45 : 1)
    }

    @ViewBuilder
    private func cell(_ r: Int, _ c: Int, _ rng: Range) -> some View {
        let isCursor = cursor == CellRef(r: r, c: c)
        let v = shown(r, c)
        let text: String = {
            if isCursor, let buf = buffer { return buf + "▏" }
            guard let v else { return "—" }
            return (mode == .delta && v > 0 ? "+" : "") + TuneExport.num(v, dp: model.decimals(id))
        }()
        let unused = r >= (axes.y?.active ?? Int.max) || c >= (axes.x?.active ?? Int.max)
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: cw, height: ch)
            .background(cellColor(v, rng))
            .overlay(isSelected(r, c) ? Color.accentColor.opacity(buffer != nil && isCursor ? 0.45 : 0.28) : Color.clear)
            .overlay(Rectangle().stroke(Color.black.opacity(0.22), lineWidth: 0.5))
            .overlay(alignment: .topLeading) {
                if model.isCellModified(id, r, c) {
                    Circle().fill(Color.orange).frame(width: 5, height: 5).padding(2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if mode == .values, b != nil, let p, TuneDiff.cellDiffers(p, b, r, c) {
                    Triangle().fill(Color.purple).frame(width: 7, height: 7)
                }
            }
            .opacity(unused ? 0.45 : 1)
    }

    private var selectionOutline: some View {
        let s = rect
        return Rectangle()
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: CGFloat(s.c1 - s.c0 + 1) * cw, height: CGFloat(s.r1 - s.r0 + 1) * ch)
            .offset(x: hw + CGFloat(s.c0) * cw, y: hh + CGFloat(s.r0) * ch)
            .allowsHitTesting(false)
    }

    private func cellColor(_ v: Double?, _ rng: Range) -> Color {
        guard let v else { return .clear }
        if mode == .delta {
            if abs(v) < 1e-9 { return .clear }
            let t = min(1, abs(v) / max(rng.maxAbs, 1e-9))
            return (v > 0 ? Color.red : Color.blue).opacity(0.15 + 0.5 * t)
        }
        guard rng.hi > rng.lo else { return Color.green.opacity(0.18) }
        let t = (v - rng.lo) / (rng.hi - rng.lo)
        return Color(hue: 0.66 * (1 - t), saturation: 0.7, brightness: 0.85).opacity(0.5)
    }

    // MARK: selection gestures

    private func cellAt(_ pt: CGPoint) -> CellRef? {
        let c = Int(floor((pt.x - hw) / cw)), r = Int(floor((pt.y - hh) / ch))
        return CellRef(r: max(-1, min(r, nr - 1)), c: max(-1, min(c, nc - 1)))
    }

    private var dragSelect: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                gridFocused = true
                commitBuffer()
                guard let start = cellAt(g.startLocation), let now = cellAt(g.location) else { return }
                if start.r < 0 && start.c < 0 { selectAll(); return }                // corner
                if start.r < 0 {                                                     // column header(s)
                    anchor = CellRef(r: 0, c: max(0, start.c)); cursor = CellRef(r: nr - 1, c: max(0, now.c)); return
                }
                if start.c < 0 {                                                     // row header(s)
                    anchor = CellRef(r: max(0, start.r), c: 0); cursor = CellRef(r: max(0, now.r), c: nc - 1); return
                }
                if !(NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift) {   // shift-click extends from the anchor
                    anchor = CellRef(r: max(0, start.r), c: max(0, start.c))
                }
                cursor = CellRef(r: max(0, now.r), c: max(0, now.c))
            }
    }

    private func selectAll() {
        anchor = CellRef(r: 0, c: 0); cursor = CellRef(r: max(0, nr - 1), c: max(0, nc - 1))
    }

    // MARK: keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .upArrow: commitBuffer(); move(-1, 0, shift); return .handled
        case .downArrow: commitBuffer(); move(1, 0, shift); return .handled
        case .leftArrow: commitBuffer(); move(0, -1, shift); return .handled
        case .rightArrow: commitBuffer(); move(0, 1, shift); return .handled
        case .return:
            if buffer != nil { commitBuffer() } else { beginEdit() }
            return .handled
        case .escape:
            if buffer != nil { buffer = nil } else { anchor = cursor }
            return .handled
        case .delete:
            if var b = buffer { if replaceOnType { b = "" ; replaceOnType = false } else if !b.isEmpty { b.removeLast() }; buffer = b }
            return .handled
        case .tab: commitBuffer(); move(0, shift ? -1 : 1, false); return .handled
        default: break
        }
        guard let chr = press.characters.first else { return .ignored }
        if buffer != nil {
            if chr.isNumber || chr == "." || (chr == "-" && (replaceOnType || buffer!.isEmpty)) {
                buffer = (replaceOnType ? "" : buffer!) + String(chr); replaceOnType = false
                return .handled
            }
            return .ignored
        }
        if chr.isNumber || chr == "." {
            guard p?.readOnly == false, mode == .values else { return .ignored }
            buffer = String(chr); replaceOnType = false
            return .handled
        }
        if chr == "+" || chr == "=" { adjust(shift && chr == "=" ? 10 : 1); return .handled }
        if chr == "-" || chr == "_" { adjust(chr == "_" ? -10 : -1); return .handled }
        if chr == "*" { scale(); return .handled }
        if chr == "h" || chr == "H" { interpolate(horizontal: true); return .handled }
        if chr == "v" || chr == "V" { interpolate(horizontal: false); return .handled }
        if chr == "s" || chr == "S" { smooth(); return .handled }
        return .ignored
    }

    private func move(_ dr: Int, _ dc: Int, _ extend: Bool) {
        cursor = CellRef(r: min(max(0, cursor.r + dr), max(0, nr - 1)), c: min(max(0, cursor.c + dc), max(0, nc - 1)))
        if !extend { anchor = cursor }
    }

    private func beginEdit() {
        guard p?.readOnly == false, mode == .values else { return }
        buffer = TuneExport.num(value(cursor.r, cursor.c), dp: model.decimals(id))
        replaceOnType = true
        gridFocused = true
    }

    private func commitBuffer() {
        guard let buf = buffer else { return }
        buffer = nil
        guard let v = Double(buf.trimmingCharacters(in: .whitespaces)) else { return }
        model.apply(id, selected.map { (.cell($0.r, $0.c), v) })
    }

    // MARK: operations

    private func setSelection() {
        guard let v = Double(setText.trimmingCharacters(in: .whitespaces)) else { return }
        model.apply(id, selected.map { (.cell($0.r, $0.c), v) }, label: "Set \(selected.count) cells to \(TuneExport.num(v))")
        gridFocused = true
    }

    private func adjust(_ times: Double) {
        let d = step * times
        model.apply(id, selected.map { (.cell($0.r, $0.c), value($0.r, $0.c) + d) })
    }

    private func scale() {
        guard let pct = Double(pctText) else { return }
        let f = 1 + pct / 100
        model.apply(id, selected.map { (.cell($0.r, $0.c), value($0.r, $0.c) * f) },
                    label: "Scaled \(selected.count) cells by \(pct > 0 ? "+" : "")\(TuneExport.num(pct))%")
    }

    /// Linear interpolation between the selection's edges, weighted by axis breakpoints.
    private func interpolate(horizontal: Bool) {
        let s = rect
        var ch: [(EditTarget, Double)] = []
        func pos(_ axis: TableAxis?, _ i: Int) -> Double {
            guard let a = axis, i < a.values.count else { return Double(i) }
            return a.values[i]
        }
        if horizontal {
            guard s.c1 > s.c0 else { return }
            for r in s.r0...s.r1 {
                let x0 = pos(axes.x, s.c0), x1 = pos(axes.x, s.c1)
                let v0 = value(r, s.c0), v1 = value(r, s.c1)
                for c in (s.c0 + 1)..<s.c1 {
                    let t = x1 != x0 ? (pos(axes.x, c) - x0) / (x1 - x0) : Double(c - s.c0) / Double(s.c1 - s.c0)
                    ch.append((.cell(r, c), v0 + (v1 - v0) * t))
                }
            }
        } else {
            guard s.r1 > s.r0 else { return }
            for c in s.c0...s.c1 {
                let y0 = pos(axes.y, s.r0), y1 = pos(axes.y, s.r1)
                let v0 = value(s.r0, c), v1 = value(s.r1, c)
                for r in (s.r0 + 1)..<s.r1 {
                    let t = y1 != y0 ? (pos(axes.y, r) - y0) / (y1 - y0) : Double(r - s.r0) / Double(s.r1 - s.r0)
                    ch.append((.cell(r, c), v0 + (v1 - v0) * t))
                }
            }
        }
        if ch.isEmpty { model.flash("Select at least 3 cells in a line to interpolate"); return }
        model.apply(id, ch, label: "Interpolated \(ch.count) cells")
    }

    private func smooth() {
        var ch: [(EditTarget, Double)] = []
        for cell in selected {
            var sum = 0.0, n = 0.0
            for dr in -1...1 { for dc in -1...1 {
                let r = cell.r + dr, c = cell.c + dc
                guard r >= 0, r < nr, c >= 0, c < nc else { continue }
                let w = (dr == 0 && dc == 0) ? 2.0 : 1.0
                sum += value(r, c) * w; n += w
            } }
            ch.append((.cell(cell.r, cell.c), sum / n))
        }
        model.apply(id, ch, label: "Smoothed \(ch.count) cells")
    }

    // MARK: clipboard (tab-separated, Excel/PCLink compatible)

    private func copySelection() {
        let s = rect
        let lines = (s.r0...s.r1).map { r in
            (s.c0...s.c1).map { TuneExport.num(shown(r, $0) ?? 0, dp: model.decimals(id)) }.joined(separator: "\t")
        }
        model.copy(lines.joined(separator: "\n"))
        model.flash("Copied \(selected.count) cells")
    }

    private func pasteFromClipboard() {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        let rows = str.split(whereSeparator: \.isNewline).map {
            $0.split(whereSeparator: { $0 == "\t" || $0 == "," || $0 == " " }).compactMap { Double($0) }
        }.filter { !$0.isEmpty }
        guard !rows.isEmpty else { model.flash("Clipboard has no numbers"); return }
        let s = rect
        var ch: [(EditTarget, Double)] = []
        // a single value fills the whole selection; a block pastes from the top-left
        if rows.count == 1 && rows[0].count == 1 {
            ch = selected.map { (.cell($0.r, $0.c), rows[0][0]) }
        } else {
            for (i, row) in rows.enumerated() { for (j, v) in row.enumerated() {
                let r = s.r0 + i, c = s.c0 + j
                if r < nr && c < nc { ch.append((.cell(r, c), v)) }
            } }
        }
        model.apply(id, ch, label: "Pasted \(ch.count) cells")
    }

    // MARK: status bar

    private var statusBar: some View {
        let r = cursor.r, c = cursor.c
        var parts: [String] = []
        func axisText(_ a: TableAxis, _ i: Int) -> String {
            let n = short(a.source), u = a.unit
            return u.isEmpty || n == u ? "\(n) \(TuneExport.num(a.values[i]))" : "\(n) \(TuneExport.num(a.values[i])) \(u)"
        }
        if let x = axes.x, c < x.values.count { parts.append(axisText(x, c)) }
        if let y = axes.y, r < y.values.count { parts.append(axisText(y, r)) }
        let u = model.unit(id)
        parts.append("value \(TuneExport.num(value(r, c), dp: model.decimals(id)))\(u.isEmpty ? "" : " " + u)")
        if model.isCellModified(id, r, c), let o = model.original(id)?.rows[safe: r]?[safe: c] {
            parts.append("was \(TuneExport.num(o, dp: model.decimals(id)))")
        }
        if let vb = valueB(r, c) { parts.append("compared \(TuneExport.num(vb, dp: model.decimals(id)))") }
        let sel = selected.map { value($0.r, $0.c) }
        var selText = ""
        if sel.count > 1 {
            let avg = sel.reduce(0, +) / Double(sel.count)
            selText = "\(sel.count) cells · min \(TuneExport.num(sel.min()!, dp: 2)) · avg \(TuneExport.num(avg, dp: 2)) · max \(TuneExport.num(sel.max()!, dp: 2))"
        }
        return HStack {
            Text(parts.joined(separator: "  ·  "))
            Spacer()
            Text(selText)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    // MARK: graph

    private var graph: some View {
        let xs = (0..<nc).map { c in axes.x.map { c < $0.values.count ? $0.values[c] : Double(c) } ?? Double(c) }
        let rowLabel: (Int) -> String = { r in axes.y.map { r < $0.values.count ? TuneExport.num($0.values[r]) : "\(r)" } ?? "row \(r + 1)" }
        return Chart {
            ForEach(0..<nr, id: \.self) { r in
                ForEach(0..<nc, id: \.self) { c in
                    if let v = shown(r, c) {
                        LineMark(x: .value(axes.x?.source ?? "X", xs[c]), y: .value("Value", v),
                                 series: .value("Row", rowLabel(r)))
                            .foregroundStyle(by: .value("Row", rowLabel(r)))
                            .interpolationMethod(.linear)
                        if isSelected(r, c) {
                            PointMark(x: .value(axes.x?.source ?? "X", xs[c]), y: .value("Value", v)).symbolSize(20)
                        }
                    }
                }
            }
            if nr == 1, mode == .values, b != nil {
                ForEach(0..<nc, id: \.self) { c in
                    if let vb = valueB(0, c) {
                        LineMark(x: .value(axes.x?.source ?? "X", xs[c]), y: .value("Value", vb), series: .value("Row", "compared"))
                            .foregroundStyle(Color.purple)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
            }
        }
        .chartXAxisLabel(axes.x?.title ?? "")
        .chartYAxisLabel(model.unit(id))
        .chartLegend(nr > 1 ? .visible : .hidden)
        .frame(minHeight: 260, maxHeight: .infinity)
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.closeSubpath(); return p
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
