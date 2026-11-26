import Foundation
import Network
import SystemConfiguration

/// Advertises the Mac on the local network (Bonjour) and serves connected iPhones:
/// live frames, channel list, logs, the open tune, and remote start/stop recording.
final class PhoneServer: ObservableObject {
    @Published private(set) var phones: [PhonePair] = []
    @Published private(set) var clients = 0
    @Published var error: String?
    private var started = false
    private var listeners: [String: NWListener] = [:]
    private var sessions: [ObjectIdentifier: (link: LinkConnection, pairID: String)] = [:]
    private var conns: [ObjectIdentifier: (link: LinkConnection, subscribed: Bool)] = [:]
    private var lastSent = Date.distantPast
    weak var app: AppModel?
    weak var live: LiveEngine?

    /// The Mac's name as set in System Settings → General → Sharing.
    var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    func start() {
        guard !started else { return }
        do {
            phones = try PairStore.load()
            started = true
            for pair in phones { listen(for: pair) }
        } catch { self.error = "Could not load approved phones: " + error.localizedDescription }
    }

    func approve(code: String, name: String) -> Bool {
        start()
        guard started, let pair = PhonePair(code: code, name: name), !name.isEmpty else { return false }
        do {
            let updated = phones.filter { $0.id != pair.id } + [pair]
            try PairStore.save(updated)
            phones = updated
            listen(for: pair)
            return true
        } catch { self.error = "Could not save approval: " + error.localizedDescription; return false }
    }

    func revoke(_ pair: PhonePair) {
        do {
            let updated = phones.filter { $0.id != pair.id }
            try PairStore.save(updated)
            phones = updated
            listeners.removeValue(forKey: pair.id)?.cancel()
            for (key, session) in sessions.filter({ $0.value.pairID == pair.id }) {
                sessions.removeValue(forKey: key)
                conns.removeValue(forKey: key)
                session.link.cancel()
            }
            clients = conns.count
        } catch { self.error = "Could not remove approval: " + error.localizedDescription }
    }

    private func listen(for pair: PhonePair) {
        guard listeners[pair.id] == nil else { return }
        do {
            let listener = try NWListener(using: pair.parameters)
            listener.service = NWListener.Service(name: pair.id, type: PhoneLink.serviceType)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listeners[pair.id] === listener else { return }
                if case .failed(let reason) = state {
                    self.listeners.removeValue(forKey: pair.id)
                    self.error = "Could not listen for " + pair.name + ": " + reason.localizedDescription
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener, self.listeners[pair.id] === listener else { connection.cancel(); return }
                self.accept(connection, pairID: pair.id)
            }
            listeners[pair.id] = listener
            listener.start(queue: .main)
        } catch { self.error = "Could not start encrypted link: " + error.localizedDescription }
    }

    private func accept(_ connection: NWConnection, pairID: String) {
        let link = LinkConnection(connection)
        let key = ObjectIdentifier(link)
        sessions[key] = (link, pairID)
        link.onState = { [weak self, weak link] state in
            guard let self, let link, self.sessions[key] != nil else { return }
            switch state {
            case .ready:
                self.conns[key] = (link, false)
                self.greet(link)
            case .failed, .cancelled:
                self.sessions.removeValue(forKey: key)
                self.conns.removeValue(forKey: key)
                link.cancel()
            default: break
            }
            self.clients = self.conns.count
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link, self.conns[key] != nil else { return }
            self.handle(message, from: link, key: key)
        }
        link.start()
    }

    private func hello() -> PhoneLink.Hello {
        let t = app?.tune
        return PhoneLink.Hello(version: PhoneLink.version, macName: macName,
                               tuneName: app?.fileName.isEmpty == false ? app?.fileName : nil,
                               ecu: t.map { "Link ID \($0.memory.linkID), fw \($0.memory.firmware)" },
                               source: live?.source == .usb ? "usb" : "none",
                               sourceDetail: live?.status ?? "",
                               recording: live?.recording ?? false)
    }

    private func greet(_ link: LinkConnection) {
        link.send(.hello(hello()))
        link.send(.channels(live?.channels ?? []))
        link.send(.logs(live?.logs.list() ?? []))
    }

    /// Re-send status to everyone (source changed, recording toggled, tune opened…).
    func broadcastState() {
        for (_, c) in conns { c.link.send(.hello(hello())); c.link.send(.channels(live?.channels ?? [])) }
    }

    func broadcastLogs() {
        let l = live?.logs.list() ?? []
        for (_, c) in conns { c.link.send(.logs(l)) }
    }

    /// Frames are throttled to ~20 Hz for the phone.
    func send(frame: PhoneLink.Frame) {
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= 0.05 else { return }
        lastSent = now
        for (_, c) in conns where c.subscribed { c.link.send(.frame(frame)) }
    }

    private func handle(_ m: PhoneLink.Message, from link: LinkConnection, key: ObjectIdentifier) {
        switch m {
        case .subscribe(let on): conns[key]?.subscribed = on
        case .listLogs: link.send(.logs(live?.logs.list() ?? []))
        case .getLog(let name):
            if let csv = live?.logs.read(name) { link.send(.logData(name: name, csv: csv)) }
            else { link.send(.notice("Log \(name) not found")) }
        case .getTune:
            if let t = app?.tune {
                let json = String(decoding: TuneExport.json(t, catalog: app?.catalog, title: app?.fileName ?? "tune"), as: UTF8.self)
                link.send(.tune(name: app?.fileName ?? "tune", json: json))
            } else { link.send(.notice("No tune is open on the Mac")) }
        case .setRecording(let on):
            live?.setRecording(on)
            if !on { broadcastLogs() }
            broadcastState()
        default: break
        }
    }
}
