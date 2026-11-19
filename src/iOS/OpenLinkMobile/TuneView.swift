import SwiftUI

/// Read-only view of the tune that's open on the Mac (edit it on the Mac).
struct TuneView: View {
    @EnvironmentObject var client: LinkClient
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Group {
                if !client.isConnected { NotConnectedView() }
                else if let t = client.tune { list(t) }
                else if client.tuneLoading { ProgressView("Loading tune from Mac…") }
                else {
                    VStack(spacing: 12) {
                        Image(systemName: "tablecells").font(.system(size: 44)).foregroundStyle(.orange)
                        Text(client.hello?.tuneName ?? "No tune open on the Mac").font(.headline)
                        Button("Load tune") { client.requestTune() }.buttonStyle(.borderedProminent)
                            .disabled(client.hello?.tuneName == nil)
                    }
                }
            }
            .navigationTitle(client.tune?.title ?? "Tune")
            .toolbar {
                if client.tune != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { client.requestTune() } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
        }
    }

    private func list(_ t: TuneDoc) -> some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let params = t.parameters.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        func resolved(_ a: TuneDoc.Axis?) -> Bool { a.map { $0.source != "X axis" && $0.source != "Y axis" } ?? false }
        func generic(_ n: String) -> Bool {
            n.range(of: #"^(G4 Table|GP Table|NV Table|Cal table) *\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let mains = t.parameters.filter { p in
            guard p.isTable, (p.rows?.count ?? 0) >= 2 else { return false }
            let n = (resolved(p.xAxis) ? 1 : 0) + (resolved(p.yAxis) ? 1 : 0)
            return n == 2 || (n == 1 && !generic(p.name))
        }
            .sorted { rank($0.name) == rank($1.name) ? $0.name < $1.name : rank($0.name) < rank($1.name) }
        let cats = Dictionary(grouping: params, by: \.category).sorted { $0.key == "Other" ? false : ($1.key == "Other" ? true : $0.key < $1.key) }
        return List {
            if q.isEmpty {
                Section {
                    Text("Read-only — edit tunes in OpenLink Tuner.").font(.caption).foregroundStyle(.secondary)
                    if let id = t.ecu["linkId"], let fw = t.ecu["firmware"] { LabeledContent("ECU", value: "Link ID \(id) · fw \(fw)") }
                }
                Section("Main tables") {
                    ForEach(mains) { p in NavigationLink(value: p.dataId) { row(p, star: true) } }
                }
            }
            ForEach(cats, id: \.key) { cat, ps in
                Section(cat) {
                    ForEach(ps.sorted { $0.name < $1.name }) { p in
                        if p.isTable { NavigationLink(value: p.dataId) { row(p) } } else { row(p) }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search settings")
        .navigationDestination(for: Int.self) { id in
            if let p = t.parameters.first(where: { $0.dataId == id }) { TableScreen(p: p) }
        }
    }

    private func row(_ p: TuneDoc.Param, star: Bool = false) -> some View {
        HStack {
            Image(systemName: star ? "star.fill" : (p.isTable ? "tablecells" : "slider.horizontal.3"))
                .foregroundStyle(star ? .yellow : (p.isTable ? .orange : .secondary)).frame(width: 20)
            Text(p.name).lineLimit(1)
            Spacer()
            if let v = p.value {
                Text("\(fmtT(v)) \(p.unit ?? "")").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            } else if let r = p.rows {
                Text("\(r.count)×\(r.first?.count ?? 0)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func rank(_ n: String) -> Int {
        let l = n.lowercased()
        if l.contains("fuel table") || l.contains("fueltable") { return 0 }
        if l.hasPrefix("ign") || l.contains("ignition table") { return 1 }
        if l.contains("lambda") { return 2 }
        return 3
    }
}

func fmtT(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.2f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
}

struct TableScreen: View {
    let p: TuneDoc.Param
    private let cw: CGFloat = 50, ch: CGFloat = 26, hw: CGFloat = 54

    var body: some View {
        let rows = p.rows ?? []
        let flat = rows.flatMap { $0 }
        let lo = flat.min() ?? 0, hi = flat.max() ?? 1
        let cols = rows.first?.count ?? 0
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let x = p.xAxis { Text("Across: \(x.source)\(x.unit.isEmpty ? "" : " (\(x.unit))")") }
                    if let y = p.yAxis { Text("Down: \(y.source)\(y.unit.isEmpty ? "" : " (\(y.unit))")") }
                    if let u = p.unit, !u.isEmpty { Text("Values in \(u)") }
                }
                .font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: hw, height: ch)
                            ForEach(0..<cols, id: \.self) { c in
                                head(p.xAxis.flatMap { c < $0.values.count ? fmtT($0.values[c]) : nil } ?? "\(c + 1)", w: cw)
                            }
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                            HStack(spacing: 0) {
                                head(p.yAxis.flatMap { r < $0.values.count ? fmtT($0.values[r]) : nil } ?? "\(r + 1)", w: hw)
                                ForEach(Array(row.enumerated()), id: \.offset) { _, v in
                                    Text(fmtT(v)).font(.system(size: 12, design: .monospaced))
                                        .frame(width: cw, height: ch)
                                        .background(heat(v, lo, hi))
                                        .overlay(Rectangle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(p.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func head(_ s: String, w: CGFloat) -> some View {
        Text(s).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            .frame(width: w, height: ch).background(Color.white.opacity(0.08))
    }
    private func heat(_ v: Double, _ lo: Double, _ hi: Double) -> Color {
        guard hi > lo else { return .green.opacity(0.2) }
        return Color(hue: 0.66 * (1 - (v - lo) / (hi - lo)), saturation: 0.75, brightness: 0.85).opacity(0.55)
    }
}
