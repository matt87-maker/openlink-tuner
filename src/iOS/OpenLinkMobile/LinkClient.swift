import Foundation
import Network
import Combine

/// Finds OpenLink Tuner on the local network (Bonjour), keeps a connection to it,
/// and holds everything the screens show: live values, logs, the tune.
@MainActor
final class LinkClient: ObservableObject {
    struct Mac: Identifiable, Hashable { let id: String; let endpoint: NWEndpoint }

    @Published var macs: [Mac] = []
    @Published var connectedMac: String?
    @Published var connecting = false
    @Published var hello: PhoneLink.Hello?
    @Published var channels: [PhoneLink.Channel] = []
    @Published var latest: [Int: Double] = [:]
    @Published var lastFrame: Date?
    @Published var logs: [PhoneLink.LogInfo] = []
    @Published var loadedLogs: [String: String] = [:]
    @Published var tune: TuneDoc?
    @Published var tuneLoading = false
    @Published var notice: String?

    private(set) var history: [Int: [Double]] = [:]
    private var browser: NWBrowser?
    private var link: LinkConnection?
    private var lastMacName: String? {
        get { UserDefaults.standard.string(forKey: "lastMac") }
        set { UserDefaults.standard.set(newValue, forKey: "lastMac") }
    }

    var isConnected: Bool { connectedMac != nil && hello != nil }
    var isStale: Bool { guard let f = lastFrame else { return true }; return Date().timeIntervalSince(f) > 2 }

    func startBrowsing() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: PhoneLink.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Mac] = results.compactMap {
                if case let .service(name, _, _, _) = $0.endpoint { return Mac(id: name, endpoint: $0.endpoint) }
                return nil
            }
            Task { @MainActor in
                guard let self else { return }
                self.macs = found.sorted { $0.id < $1.id }
                if self.link == nil, let last = self.lastMacName, let m = found.first(where: { $0.id == last }) { self.connect(m) }
                else if self.link == nil, found.count == 1 { self.connect(found[0]) }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func connect(_ mac: Mac) {
        disconnect()
        connecting = true
        let conn = NWConnection(to: mac.endpoint, using: .tcp)
        let l = LinkConnection(conn)
        l.onState = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .ready:
                    self.connecting = false
                    self.connectedMac = mac.id
                    self.lastMacName = mac.id
                    l.send(.subscribe(true))
                    l.send(.listLogs)
                case .failed, .cancelled:
                    if self.link === l { self.link = nil; self.connectedMac = nil; self.hello = nil; self.connecting = false }
                default: break
                }
            }
        }
        l.onMessage = { [weak self] m in Task { @MainActor in self?.handle(m) } }
        link = l
        l.start()
    }

    func disconnect() {
        link?.cancel(); link = nil
        connectedMac = nil; hello = nil; latest = [:]; history = [:]; lastFrame = nil
    }

    private func handle(_ m: PhoneLink.Message) {
        switch m {
        case .hello(let h): hello = h
        case .channels(let c): channels = c
        case .frame(let f):
            lastFrame = Date(timeIntervalSince1970: f.t)
            var v: [Int: Double] = [:]
            for (i, c) in channels.enumerated() where i < f.values.count {
                if let x = f.values[i] {
                    v[c.id] = x
                    var h = history[c.id] ?? []; h.append(x); if h.count > 200 { h.removeFirst(h.count - 200) }
                    history[c.id] = h
                }
            }
            latest = v
        case .logs(let l): logs = l
        case .logData(let name, let csv): loadedLogs[name] = csv
        case .tune(_, let json):
            tuneLoading = false
            tune = try? JSONDecoder().decode(TuneDoc.self, from: Data(json.utf8))
            if tune == nil { notice = "Couldn't read the tune from the Mac" }
        case .notice(let s): notice = s; tuneLoading = false
        default: break
        }
    }

    func requestLog(_ name: String) { if loadedLogs[name] == nil { link?.send(.getLog(name)) } }
    func requestTune() { tuneLoading = true; link?.send(.getTune) }
    func refreshLogs() { link?.send(.listLogs) }
    func setRecording(_ on: Bool) { link?.send(.setRecording(on)) }
}

// MARK: - Tune document (the Mac's AI/JSON export)

struct TuneDoc: Decodable {
    struct Axis: Decodable { let source: String; let unit: String; let values: [Double] }
    struct Param: Decodable, Identifiable {
        let dataId: Int
        let name: String
        let category: String
        let unit: String?
        let readOnly: Bool?
        let value: Double?
        let rows: [[Double]]?
        let xAxis: Axis?
        let yAxis: Axis?
        var id: Int { dataId }
        var isTable: Bool { rows != nil }
    }
    let title: String
    let ecu: [String: String]
    let parameters: [Param]
}

// MARK: - CSV logs

struct LogTable {
    let columns: [String]          // without the time column
    let time: [Double]
    let data: [[Double?]]          // [column][row]

    init(csv: String) {
        var lines = csv.split(whereSeparator: \.isNewline).map(String.init)
        let header = lines.isEmpty ? [] : LogTable.split(lines.removeFirst())
        columns = Array(header.dropFirst())
        var t: [Double] = []
        var cols = Array(repeating: [Double?](), count: max(0, header.count - 1))
        for (i, l) in lines.enumerated() {
            let f = LogTable.split(l)
            guard !f.isEmpty else { continue }
            t.append(Double(f[0]) ?? Double(i))
            for c in 0..<cols.count { cols[c].append(c + 1 < f.count ? Double(f[c + 1]) : nil) }
        }
        time = t; data = cols
    }

    static func split(_ line: String) -> [String] {
        var out: [String] = [], cur = "", q = false
        for ch in line {
            if ch == "\"" { q.toggle() } else if ch == "," && !q { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }
}
