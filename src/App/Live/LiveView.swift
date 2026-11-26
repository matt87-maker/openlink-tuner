import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LiveView: View {
    @EnvironmentObject var live: LiveEngine
    @EnvironmentObject var phone: PhoneServer
    @State private var logs: [PhoneLink.LogInfo] = []
    private struct Recording: Identifiable {
        let id: String
        let table: LogTable
    }
    @State private var recordingToReview: Recording?
    @State private var showConsole = false
    @State private var phoneName = ""
    @State private var pairingCode = ""
    private let cols = [GridItem(.adaptive(minimum: 190), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if live.source == .usb { usbNotice }
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(live.channels) { c in GaugeTile(channel: c, value: live.latest[c.id], history: live.history[c.id] ?? []) }
                }
                .opacity(live.connected ? 1 : 0.4)
                phoneCard
                logsCard
            }
            .padding(20)
        }
        .sheet(item: $recordingToReview) { recording in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(recording.id).font(.title2.bold())
                    Spacer()
                    Button("Done") { recordingToReview = nil }
                }
                LogInspector(table: recording.table)
            }.padding(20).frame(width: 680, height: 570)
        }
        .onAppear { logs = live.logs.list() }
        .onChange(of: live.recording) { _, _ in logs = live.logs.list() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Live").font(.largeTitle.bold())
            Picker("", selection: Binding(get: { live.source }, set: { live.select($0) })) {
                ForEach(LiveEngine.Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 260).labelsHidden()
            Circle().fill(live.connected ? Color.green : Color.secondary).frame(width: 9, height: 9)
            Text(live.status).foregroundStyle(.secondary).lineLimit(1)
            if live.connected { Text("\(Int(live.rate)) Hz").font(.caption.monospaced()).foregroundStyle(.tertiary) }
            Spacer()
            Button {
                live.setRecording(!live.recording)
            } label: {
                if live.recording, let s = live.recordStart {
                    Label { Text(s, style: .timer).monospacedDigit() } icon: { Image(systemName: "stop.circle.fill").foregroundStyle(.red) }
                } else {
                    Label("Record", systemImage: "record.circle")
                }
            }
            .disabled(!live.connected)
            .controlSize(.large)
        }
    }

    private var usbNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Link USB is read-only", systemImage: "cable.connector")
                .font(.callout.bold())
            Text("Tested on a Link G4X (firmware 6.31.2). OpenLink only ever sends identify, version and read commands — every write, store, reset and firmware command is blocked in code, twice. Each session is logged to ~/Library/Logs/OpenLink Tuner.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("USB console (\(live.console.count) lines)", isExpanded: $showConsole) {
                ScrollView {
                    Text(live.console.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)
                Button("Show raw logs in Finder") {
                    let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OpenLink Tuner")
                    NSWorkspace.shared.activateFileViewerSelecting([u])
                }
            }
            .font(.caption)
            if !FTDI.libraryAvailable {
                Text("libftdi not found — install it with `brew install libftdi`.").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var phoneCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approved phones", systemImage: "lock.iphone").font(.headline)
            Text("On your iPhone, open Mac → Pair with a Mac. Enter its code here to approve it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Phone name", text: $phoneName)
                SecureField("Pairing code from iPhone", text: $pairingCode)
                Button("Approve Phone") {
                    if phone.approve(code: pairingCode, name: phoneName.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        pairingCode = ""
                        phoneName = ""
                    }
                }
                .disabled(phoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || PhonePair(code: pairingCode, name: "") == nil)
            }
            ForEach(phone.phones) { pair in
                HStack { Text(pair.name); Spacer(); Button("Revoke") { phone.revoke(pair) } }
            }
            Text("\(phone.clients) encrypted connection(s)").font(.caption).foregroundStyle(.secondary)
            if let error = phone.error { Text(error).foregroundStyle(.red) }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs").font(.title3.bold())
                Spacer()
                Button("Import CSV…") { importCSV() }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([live.logs.folder]) }
                Button { logs = live.logs.list(); phone.broadcastLogs() } label: { Image(systemName: "arrow.clockwise") }
            }
            if logs.isEmpty {
                Text("No logs yet. Press Record while connected, or import a CSV exported from PCLink.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(logs) { l in
                HStack {
                    Image(systemName: "waveform.path.ecg")
                    Button(l.id) {
                        if let csv = live.logs.read(l.id) {
                            recordingToReview = Recording(id: l.id, table: LogTable(csv: csv))
                        } else { live.app?.error = "Could not read " + l.id }
                    }.buttonStyle(.link).lineLimit(1)
                    Spacer()
                    Text("\(Int(l.duration)) s · \(l.samples) samples · \(l.channels.count) channels")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func importCSV() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls { try? live.logs.importCSV(u) }
        logs = live.logs.list()
        phone.broadcastLogs()
    }
}

struct GaugeTile: View {
    let channel: PhoneLink.Channel
    let value: Double?
    let history: [Double]

    private var hot: Bool { if let w = channel.warn, let v = value { return v >= w }; return false }
    private var frac: Double {
        guard let v = value, channel.max > channel.min else { return 0 }
        return min(1, max(0, (v - channel.min) / (channel.max - channel.min)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(channel.name).font(.caption.bold()).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("D\(channel.id)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { fmtLive($0) } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(hot ? .red : .primary)
                Text(channel.unit).font(.callout).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(hot ? Color.red : Color.accentColor).frame(width: g.size.width * frac)
                }
            }
            .frame(height: 5)
            Sparkline(values: history, lo: channel.min, hi: channel.max).frame(height: 28)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Sparkline: View {
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
            .stroke(Color.accentColor.opacity(0.8), lineWidth: 1.2)
        }
    }
}

func fmtLive(_ v: Double) -> String {
    abs(v) >= 100 ? String(format: "%.0f", v) : (abs(v) >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v))
}
