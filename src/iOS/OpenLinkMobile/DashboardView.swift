import SwiftUI
import UIKit

struct DashboardView: View {
    @EnvironmentObject var client: LinkClient
    @Environment(\.verticalSizeClass) private var vSize

    private var rpm: PhoneLink.Channel? { client.channels.first { $0.id == 1000 } }
    private var others: [PhoneLink.Channel] { client.channels.filter { $0.id != 1000 } }

    var body: some View {
        NavigationStack {
            Group {
                if !client.isConnected { NotConnectedView() }
                else if client.hello?.source == "none" || client.hello?.source == nil { idle }
                else { dash }
            }
            .navigationTitle("Live")
            .toolbar {
                if client.isConnected && client.hello?.source != "none" {
                    ToolbarItem(placement: .topBarTrailing) { recordButton }
                }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var idle: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector.slash").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No live data").font(.title3.bold())
            Text("On the Mac, open Live and choose Link USB.").foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(30)
    }

    private var recordButton: some View {
        Button {
            client.setRecording(!(client.hello?.recording ?? false))
        } label: {
            if client.hello?.recording == true {
                Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(.red)
            } else {
                Label("Record", systemImage: "record.circle")
            }
        }
    }

    private var dash: some View {
        ScrollView {
            VStack(spacing: 14) {
                if client.isStale {
                    Label("Waiting for data…", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
                }
                if vSize == .compact {
                    HStack(alignment: .top, spacing: 14) {
                        if let r = rpm { RPMGauge(channel: r, value: client.latest[r.id]).frame(width: 300, height: 260) }
                        tiles
                    }
                } else {
                    if let r = rpm { RPMGauge(channel: r, value: client.latest[r.id]).frame(height: 290) }
                    tiles
                }
                if client.hello?.recording == true {
                    Label("Recording on the Mac", systemImage: "record.circle.fill").foregroundStyle(.red).font(.footnote)
                }
            }
            .padding()
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(others) { c in Tile(channel: c, value: client.latest[c.id], history: client.history[c.id] ?? []) }
        }
    }
}

struct RPMGauge: View {
    let channel: PhoneLink.Channel
    let value: Double?
    private let start = Angle.degrees(135), sweep = 270.0

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2 + size * 0.05)
            let r = size * 0.44
            let v = value ?? channel.min
            let frac = min(1, max(0, (v - channel.min) / max(1, channel.max - channel.min)))
            let red = channel.warn.map { ($0 - channel.min) / (channel.max - channel.min) } ?? 1
            ZStack {
                Canvas { ctx, _ in
                    func arc(_ a: Double, _ b: Double) -> Path {
                        Path { p in p.addArc(center: c, radius: r, startAngle: start + .degrees(sweep * a), endAngle: start + .degrees(sweep * b), clockwise: false) }
                    }
                    ctx.stroke(arc(0, 1), with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    if red < 1 { ctx.stroke(arc(red, 1), with: .color(.red.opacity(0.45)), style: StrokeStyle(lineWidth: 16)) }
                    ctx.stroke(arc(0, frac), with: .linearGradient(Gradient(colors: [.orange, frac > red ? .red : .yellow]),
                                                                 startPoint: CGPoint(x: c.x - r, y: c.y), endPoint: CGPoint(x: c.x + r, y: c.y)),
                               style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    // ticks every 1000
                    let step = 1000.0
                    var t = channel.min
                    while t <= channel.max + 0.1 {
                        let a = (start + .degrees(sweep * (t - channel.min) / (channel.max - channel.min))).radians
                        let p1 = CGPoint(x: c.x + cos(a) * (r - 22), y: c.y + sin(a) * (r - 22))
                        let p2 = CGPoint(x: c.x + cos(a) * (r - 12), y: c.y + sin(a) * (r - 12))
                        ctx.stroke(Path { $0.move(to: p1); $0.addLine(to: p2) }, with: .color(.white.opacity(0.6)), lineWidth: 2)
                        let lp = CGPoint(x: c.x + cos(a) * (r - 38), y: c.y + sin(a) * (r - 38))
                        ctx.draw(Text("\(Int(t / 1000))").font(.caption.bold()).foregroundColor(.white.opacity(0.7)), at: lp)
                        t += step
                    }
                    // needle
                    let na = (start + .degrees(sweep * frac)).radians
                    let tip = CGPoint(x: c.x + cos(na) * (r - 8), y: c.y + sin(na) * (r - 8))
                    ctx.stroke(Path { $0.move(to: c); $0.addLine(to: tip) }, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.orange))
                }
                VStack(spacing: 0) {
                    Text(value.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(size: size * 0.16, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(frac > red ? .red : .white)
                    Text("RPM  ×1000 on dial").font(.caption2).foregroundStyle(.secondary)
                }
                .position(x: c.x, y: c.y + r * 0.55)
            }
        }
    }
}

struct Tile: View {
    let channel: PhoneLink.Channel
    let value: Double?
    let history: [Double]
    private var hot: Bool { if let w = channel.warn, let v = value { return v >= w }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(channel.name).font(.caption.bold()).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map(fmt) ?? "—").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(hot ? .red : .primary)
                Text(channel.unit).font(.footnote).foregroundStyle(.secondary)
            }
            Spark(values: history, lo: channel.min, hi: channel.max).frame(height: 24)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(hot ? Color.red : .clear, lineWidth: 1.5))
    }
    private func fmt(_ v: Double) -> String {
        abs(v) >= 100 ? String(format: "%.0f", v) : (abs(v) >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v))
    }
}

struct Spark: View {
    let values: [Double]; let lo: Double; let hi: Double
    var body: some View {
        GeometryReader { g in
            Path { p in
                guard values.count > 1, hi > lo else { return }
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = g.size.height * (1 - CGFloat(min(1, max(0, (v - lo) / (hi - lo)))))
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color.orange.opacity(0.85), lineWidth: 1.4)
        }
    }
}
