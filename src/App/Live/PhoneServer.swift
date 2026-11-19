import Foundation
import Network
import SystemConfiguration

/// Advertises the Mac on the local network (Bonjour) and serves connected iPhones:
/// live frames, channel list, logs, the open tune, and remote start/stop recording.
final class PhoneServer: ObservableObject {
    @Published var state = "Starting…"
    @Published var clients = 0
    @Published var port: UInt16 = 0

    private var listener: NWListener?
    private var conns: [ObjectIdentifier: (link: LinkConnection, subscribed: Bool)] = [:]
    private var lastSent = Date.distantPast
    weak var app: AppModel?
    weak var live: LiveEngine?

    /// The Mac's name as set in System Settings → General → Sharing.
    var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: macName, type: PhoneLink.serviceType)
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    switch st {
                    case .ready: self?.state = "Visible to iPhones as “\(self?.macName ?? "Mac")”"; self?.port = l.port?.rawValue ?? 0
                    case .failed(let e): self?.state = "Network error: \(e)"
                    case .waiting(let e): self?.state = "Waiting: \(e)"
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] c in DispatchQueue.main.async { self?.accept(c) } }
            l.start(queue: .main)
            listener = l
        } catch { state = "Couldn't start: \(error)" }
    }

    private func accept(_ c: NWConnection) {
        let link = LinkConnection(c)
        let key = ObjectIdentifier(link)
        link.onState = { [weak self] st in
            switch st {
            case .ready: self?.greet(link)
            case .failed, .cancelled: self?.conns[key] = nil; self?.clients = self?.conns.count ?? 0
            default: break
            }
        }
        link.onMessage = { [weak self] m in self?.handle(m, from: link, key: key) }
        conns[key] = (link, false)
        clients = conns.count
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
