import Foundation
import Network
import Combine

/// Finds OpenLink Tuner on the local network (Bonjour), keeps a connection to it,
/// and holds everything the screens show: live values, logs, the tune.
@MainActor
final class LinkClient: ObservableObject {
    struct Mac: Identifiable, Hashable { let id: String; let name: String; let endpoint: NWEndpoint }

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
    @Published private(set) var pendingPair: PhonePair?
    private var pairs: [PhonePair] = []
    private var discovered: [String: NWEndpoint] = [:]
    private var autoConnect = true
    private var lastID: String? {
        get { UserDefaults.standard.string(forKey: "lastApprovedMac") }
        set { UserDefaults.standard.set(newValue, forKey: "lastApprovedMac") }
    }

    func beginPairing() {
        disconnect()
        pendingPair = PhonePair(name: "New Mac")
        updateMacs()
    }

    func cancelPairing() {
        disconnect()
        pendingPair = nil
        updateMacs()
    }

    private func updateMacs() {
        let known = pairs + [pendingPair].compactMap { $0 }
        macs = known.compactMap { pair in
            discovered[pair.id].map { Mac(id: pair.id, name: pair.name, endpoint: $0) }
        }
        guard link == nil else { return }
        if let pendingPair, let mac = macs.first(where: { $0.id == pendingPair.id }) { connect(mac) }
        else if pendingPair == nil, autoConnect, let mac = macs.first(where: { $0.id == lastID }) { connect(mac) }
    }

    var isConnected: Bool { connectedMac != nil && hello != nil }
    var isStale: Bool { guard let f = lastFrame else { return true }; return Date().timeIntervalSince(f) > 2 }

    func startBrowsing() {
        guard browser == nil else { return }
        do { pairs = try PairStore.load() }
        catch { notice = "Could not load pairings: " + error.localizedDescription; return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: PhoneLink.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.discovered.removeAll()
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint { self.discovered[name] = result.endpoint }
                }
                self.updateMacs()
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func connect(_ mac: Mac) {
        guard let pair = ([pendingPair].compactMap { $0 } + pairs).first(where: { $0.id == mac.id }) else { return }
        disconnect()
        if pendingPair?.id != mac.id { pendingPair = nil }
        connecting = true
        let l = LinkConnection(NWConnection(to: mac.endpoint, using: pair.parameters))
        l.onState = { [weak self, weak l] state in
            guard let self, let l, self.link === l else { return }
            switch state {
            case .failed(let error):
                let reconnect = self.hello != nil
                self.disconnect()
                self.autoConnect = reconnect
                self.notice = "Secure connection failed: " + error.localizedDescription
            case .cancelled:
                let reconnect = self.hello != nil
                self.disconnect()
                self.autoConnect = reconnect
            default: break
            }
        }
        l.onMessage = { [weak self, weak l] message in
            guard let self, let l, self.link === l else { return }
            if self.hello == nil {
                guard case .hello(let hello) = message, hello.version == PhoneLink.version else {
                    self.disconnect()
                    return
                }
                var approved = pair
                approved.name = hello.macName
                let updated = self.pairs.filter { $0.id != pair.id } + [approved]
                do {
                    if self.pendingPair != nil || pair.name != approved.name { try PairStore.save(updated) }
                } catch {
                    self.disconnect()
                    self.notice = "Could not save pairing: " + error.localizedDescription
                    return
                }
                self.pairs = updated
                self.pendingPair = nil
                self.connectedMac = hello.macName
                self.lastID = mac.id
                self.connecting = false
                self.autoConnect = true
                self.updateMacs()
                l.send(.subscribe(true))
                l.send(.listLogs)
            }
            self.handle(message)
        }
        link = l
        l.start()
    }

    func disconnect() {
        autoConnect = false
        link?.cancel()
        link = nil
        connecting = false
        connectedMac = nil
        hello = nil
        latest = [:]
        history = [:]
        lastFrame = nil
        channels = []
        logs = []
        loadedLogs = [:]
        tune = nil
        tuneLoading = false
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
