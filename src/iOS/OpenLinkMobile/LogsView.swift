import SwiftUI
import Charts

struct LogsView: View {
    @EnvironmentObject var client: LinkClient

    var body: some View {
        NavigationStack {
            Group {
                if !client.isConnected { NotConnectedView() }
                else if client.logs.isEmpty {
                    ContentUnavailableView("No logs yet", systemImage: "waveform.path.ecg",
                                           description: Text("Record on the Mac (or from the Live tab), or import a CSV there."))
                } else {
                    List(client.logs) { l in
                        NavigationLink(value: l) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(l.id.replacingOccurrences(of: ".csv", with: "")).font(.headline).lineLimit(1)
                                Text("\(duration(l.duration)) · \(l.samples) samples · \(l.channels.count) channels")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .refreshable { client.refreshLogs() }
                }
            }
            .navigationTitle("Logs")
            .navigationDestination(for: PhoneLink.LogInfo.self) { LogDetail(info: $0) }
        }
    }
}

func duration(_ s: Double) -> String {
    let m = Int(s) / 60, sec = Int(s) % 60
    return m > 0 ? "\(m) min \(sec) s" : "\(sec) s"
}

struct LogDetail: View {
    @EnvironmentObject var client: LinkClient
    let info: PhoneLink.LogInfo
    @State private var table: LogTable?
    @State private var picked: Set<Int> = [0]
    @State private var cursor: Double?

    var body: some View {
        Group {
            if let t = table { content(t) }
            else { ProgressView("Loading from Mac…") }
        }
        .navigationTitle(info.id.replacingOccurrences(of: ".csv", with: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let csv = client.loadedLogs[info.id] {
                ShareLink(item: csv, preview: SharePreview(info.id)) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear { client.requestLog(info.id); load() }
        .onChange(of: client.loadedLogs[info.id]) { _, _ in load() }
    }

    private func load() {
        if table == nil, let csv = client.loadedLogs[info.id] { table = LogTable(csv: csv) }
    }

    private func content(_ t: LogTable) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(t.columns.enumerated()), id: \.offset) { i, name in
                            let on = picked.contains(i)
                            Button { if on { picked.remove(i) } else { picked.insert(i) } } label: {
                                Text(short(name)).font(.caption.bold())
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(on ? Color.orange : Color.white.opacity(0.1), in: Capsule())
                                    .foregroundStyle(on ? .black : .primary)
                            }
                        }
                    }
                }
                ForEach(picked.sorted(), id: \.self) { i in
                    if i < t.data.count { chart(t, i) }
                }
            }
            .padding()
        }
    }

    private func chart(_ t: LogTable, _ i: Int) -> some View {
        let col = t.data[i]
        let pts = zip(t.time, col).compactMap { x, y in y.map { (x, $0) } }
        let step = max(1, pts.count / 1500)                     // keep charts fast on long logs
        let shown = stride(from: 0, to: pts.count, by: step).map { pts[$0] }
        let vals = pts.map(\.1)
        let at = cursor.flatMap { c in pts.min(by: { abs($0.0 - c) < abs($1.0 - c) }) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(short(t.columns[i])).font(.subheadline.bold())
                Spacer()
                if let at { Text("\(fmt(at.1)) @ \(String(format: "%.1f", at.0)) s").font(.caption.monospacedDigit()).foregroundStyle(.orange) }
            }
            Chart {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", p.0), y: .value("Value", p.1)).interpolationMethod(.linear)
                }
                .foregroundStyle(.orange)
                if let at { RuleMark(x: .value("Time", at.0)).foregroundStyle(.white.opacity(0.5)) }
            }
            .chartXAxisLabel("seconds")
            .chartOverlay { proxy in
                GeometryReader { g in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if let frame = proxy.plotFrame {
                                    cursor = proxy.value(atX: v.location.x - g[frame].origin.x, as: Double.self)
                                }
                            }
                            .onEnded { _ in })
                }
            }
            .frame(height: 170)
            if let lo = vals.min(), let hi = vals.max() {
                Text("min \(fmt(lo)) · avg \(fmt(vals.reduce(0, +) / Double(vals.count))) · max \(fmt(hi))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func short(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*\(D\d+\)"#, with: "", options: .regularExpression)
    }
    private func fmt(_ v: Double) -> String {
        abs(v) >= 100 ? String(format: "%.0f", v) : (abs(v) >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v))
    }
}
