import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What happens when an ECU shows up:
/// - no tune open (and auto-read on) → read the tune from the ECU and open it, then go live
/// - a tune file already open → just start live data (reading is one click away)
final class EcuManager: ObservableObject {
    enum Target { case open, compare }

    @Published var cablePresent = false
    @Published var reading = false
    @Published var progress = 0.0
    @Published var step = ""
    @AppStorage("autoReadTune") var autoRead = true
    @AppStorage("autoLive") var autoLive = true

    weak var app: AppModel?
    weak var live: LiveEngine?
    private let watcher = UsbWatcher()
    private var cancelFlag = false

    var connected: Bool { cablePresent }

    func start() {
        // ECU powered back up after being off (cable stayed plugged in): read its tune if none is open
        live?.onEcuReturned = { [weak self] in
            guard let self, let app = self.app, !self.reading else { return }
            app.flash("ECU is back online")
            if app.tune == nil && self.autoRead { self.readTune(into: .open) }
        }
        watcher.onChange = { [weak self] present in
            DispatchQueue.main.async { self?.cableChanged(present) }
        }
        watcher.start()
    }

    /// The Link USB cable.
    func makeTransport() throws -> LinkTransport { try FTDI() }

    private func cableChanged(_ present: Bool) {
        guard present != cablePresent else { return }
        cablePresent = present
        guard let app, let live else { return }
        if present {
            app.flash("Link ECU cable connected")
            if app.tune == nil && autoRead { readTune(into: .open) }
            else if autoLive { live.select(.usb) }
        } else {
            cancelFlag = true
            if live.source == .usb { live.select(.off) }
            app.flash("ECU disconnected")
        }
    }

    func cancel() { cancelFlag = true }

    /// Ask for Link's free PCLink installer (.exe) and learn every ECU layout in it.
    func importLayouts() {
        let panel = NSOpenPanel()
        panel.title = "Choose Link's PCLink installer (PCLink-EN-x.y.z.exe from linkecu.com)"
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app?.flash("Importing ECU layouts…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try EcuTuneReader.importFromInstaller(url) }
            DispatchQueue.main.async {
                switch result {
                case .success(let ids):
                    let known = EcuTuneReader.templates().map(\.linkId).joined(separator: ", ")
                    self.app?.flash(ids.isEmpty ? "No new layouts — already known: \(known)" : "Imported layouts for Link ID \(ids.joined(separator: ", "))")
                case .failure(let e):
                    self.app?.error = e.localizedDescription
                }
            }
        }
    }

    /// Read the whole tune (read-only), then open it or load it as the comparison.
    func readTune(into target: Target) {
        guard !reading, let live else { return }
        if live.source == .usb { live.select(.off) }      // the cable can only do one job at a time
        reading = true; progress = 0; step = "Connecting to the ECU…"; cancelFlag = false
        let transportMaker = { [weak self] () throws -> LinkTransport in
            guard let self else { throw EcuTuneReader.ReadError.cancelled }
            return try self.makeTransport()
        }
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            var ecu: LinkECU?
            var answered = false
            do {
                let e = LinkECU(transport: try transportMaker())
                ecu = e
                _ = try e.open()
                self.post(0.01, "Identifying ECU…")
                let id = try e.identify()
                answered = true
                let info = e.info()
                let reader = EcuTuneReader()
                reader.progress = { [weak self] p, s in self?.post(p, s) }
                reader.isCancelled = { [weak self] in self?.cancelFlag ?? true }
                reader.firmwareReply = info.byName["Firmware"]
                let (tune, rep) = try reader.run(e, replies: [id.payload] + info.payloads)
                e.close(); ecu = nil
                DispatchQueue.main.async {
                    self.reading = false
                    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm"
                    let name = "ECU \(rep.linkId) read \(f.string(from: Date())).pclx"
                    switch target {
                    case .open: self.app?.openFromECU(tune, name: name, report: rep)
                    case .compare: self.app?.setCompare(tune, name: name)
                    }
                    if self.autoLive && self.connected { self.live?.select(.usb) }
                }
            } catch {
                ecu?.close()
                DispatchQueue.main.async {
                    self.reading = false
                    if case EcuTuneReader.ReadError.cancelled = error { self.app?.flash("Reading the tune was cancelled") }
                    else if !answered && self.connected {
                        // cable is there but the ECU is silent (ignition off): wait for it instead of erroring;
                        // live data's reconnect will call back and read the tune when it powers up
                        self.app?.flash("ECU not responding — will read the tune when it powers up")
                        self.live?.select(.usb)
                    }
                    else { self.app?.error = "Couldn't read the tune from the ECU: \(error)\n\nRaw USB log: ~/Library/Logs/OpenLink Tuner/" }
                }
            }
        }
    }

    private func post(_ p: Double, _ s: String) {
        DispatchQueue.main.async { self.progress = p; self.step = s }
    }
}
