import Foundation
import Combine

/// Live data hub: owns the USB connection to the ECU, the latest values, short history
/// for sparklines, recording to CSV, and fans frames out to connected iPhones.
final class LiveEngine: ObservableObject {
    enum Source: String, CaseIterable, Identifiable { case off = "Off", usb = "Link USB"; var id: String { rawValue } }

    @Published var source: Source = .off
    @Published var status = "Not connected"
    @Published var connected = false
    @Published var latest: [Int: Double] = [:]
    @Published var recording = false
    @Published var recordStart: Date?
    @Published var console: [String] = []
    @Published var rate: Double = 0                 // frames per second
    @Published private(set) var channels: [PhoneLink.Channel] = LiveEngine.defaultChannels

    private(set) var history: [Int: [Double]] = [:] // last N values per channel
    private let historyLen = 240
    weak var app: AppModel?
    var transportFactory: () throws -> LinkTransport = { try FTDI() }
    let logs = LogStore()
    private(set) var copilotTelemetry = CopilotTelemetry()
    var onFrame: ((PhoneLink.Frame) -> Void)?
    var onStateChange: (() -> Void)?

    private var usbThread: Thread?
    private var usbStop = false
    private var usbGen = 0                          // each start gets a new generation; old threads exit
    var onEcuReturned: (() -> Void)?                // ECU answered again after being silent
    private var ecu: LinkECU?
    private var frameTimes: [Date] = []

    static let defaultChannels: [PhoneLink.Channel] = [
        .init(id: 1000, name: "Engine Speed", unit: "RPM", min: 0, max: 8000, warn: 7200),
        .init(id: 1001, name: "MAP", unit: "kPa", min: 0, max: 250, warn: nil),
        .init(id: 1078, name: "Throttle", unit: "%", min: 0, max: 100, warn: nil),
        .init(id: 3040, name: "Lambda 1", unit: "λ", min: 0.6, max: 1.4, warn: nil),
        .init(id: 1004, name: "Coolant Temp", unit: "°C", min: -20, max: 130, warn: 105),
        .init(id: 1011, name: "Intake Air Temp", unit: "°C", min: -20, max: 90, warn: 60),
        .init(id: 1064, name: "Ignition Angle", unit: "°", min: -10, max: 50, warn: nil),
        .init(id: 1007, name: "Injector Duty", unit: "%", min: 0, max: 100, warn: 85),
        .init(id: 1081, name: "Battery", unit: "V", min: 8, max: 16, warn: nil),
        .init(id: 1012, name: "Oil Pressure", unit: "kPa", min: 0, max: 800, warn: nil),
        .init(id: 1014, name: "Oil Temp", unit: "°C", min: 0, max: 150, warn: 125),
        .init(id: 1013, name: "Fuel Pressure", unit: "kPa", min: 0, max: 600, warn: nil),
    ]

    // MARK: control

    func select(_ s: Source) {
        guard s != source else { return }
        stopSource()
        source = s
        switch s {
        case .off: status = "Not connected"
        case .usb: startUSB()
        }
        onStateChange?()
    }

    private func stopSource() {
        usbGen += 1
        copilotTelemetry = CopilotTelemetry()
        usbStop = true; usbThread = nil
        connected = false
        if recording { setRecording(false) }
        latest = [:]; history = [:]; rate = 0
    }

    // MARK: ingest

    private func ingest(_ values: [Int: Double], at now: Date) {
        let readings = channels.compactMap { channel -> (String, Double)? in
            guard let value = values[channel.id] else { return nil }
            return ("\(channel.name) [\(channel.unit)] D\(channel.id)", value)
        }
        copilotTelemetry.record(Dictionary(uniqueKeysWithValues: readings), at: now)
        latest = values
        for (k, v) in values {
            var h = history[k] ?? []
            h.append(v); if h.count > historyLen { h.removeFirst(h.count - historyLen) }
            history[k] = h
        }
        frameTimes.append(now); frameTimes = frameTimes.filter { now.timeIntervalSince($0) < 1 }
        rate = Double(frameTimes.count)
        let frame = PhoneLink.Frame(t: now.timeIntervalSince1970, values: channels.map { values[$0.id] })
        if recording { logs.append(frame) }
        onFrame?(frame)
    }

    // MARK: recording

    func setRecording(_ on: Bool) {
        guard on != recording else { return }
        if on {
            guard connected else { return }
            logs.start(channels: channels)
            recordStart = Date(); recording = true
        } else {
            logs.finish(); recording = false; recordStart = nil
        }
        onStateChange?()
    }

    // MARK: USB source (experimental, read-only)

    private func say(_ s: String) {
        DispatchQueue.main.async { self.console.append(s); if self.console.count > 300 { self.console.removeFirst(100) } }
    }

    private func startUSB() {
        status = "Connecting to Link USB…"
        console = []
        usbStop = false
        usbGen += 1
        let gen = usbGen
        let chans = channels
        let th = Thread { [weak self] in
            guard let self else { return }
            func alive() -> Bool { !self.usbStop && self.usbGen == gen }
            var lastState = ""
            func setState(_ connected: Bool, _ text: String) {
                guard text != lastState else { return }
                lastState = text
                DispatchQueue.main.async {
                    guard self.usbGen == gen else { return }
                    self.connected = connected
                    self.status = text
                    if !connected { self.copilotTelemetry = CopilotTelemetry(); self.latest = [:]; self.rate = 0 }
                    self.onStateChange?()
                }
            }

            let ecu: LinkECU
            do { ecu = LinkECU(transport: try self.transportFactory()) }
            catch { self.say("Stopped: \(error)"); setState(false, "USB error: \(error)"); return }
            self.ecu = ecu
            self.say("Raw frame log: \(ecu.rawLogPath)")
            var isOpen = false, everConnected = false

            /// Open the cable if needed, then ping the ECU (read-only capabilities query) until it
            /// answers. Returns true when it answers, and whether we had to wait for it.
            func waitForECU() -> (ok: Bool, waited: Bool) {
                var misses = 0, waited = false
                while alive() {
                    if !isOpen {
                        do {
                            let d = try ecu.reopenTransport()
                            isOpen = true
                            if !everConnected { self.say("Opened \(d)") }
                        } catch {
                            waited = true
                            setState(false, "Can't open the Link cable — retrying (\(error))")
                            Thread.sleep(forTimeInterval: 2)
                            continue
                        }
                    }
                    do {
                        let id = try ecu.identify(timeout: 0.5)
                        if !everConnected { self.say("ECU answered: \(LinkWire.hex(id.payload))") }
                        return (true, waited)
                    } catch {
                        waited = true
                        misses += 1
                        if misses == 1 {
                            self.say("ECU not answering — waiting for it (\(error))")
                            ecu.log("WAITING for ECU")
                        }
                        setState(false, "ECU not responding — waiting for it (ignition off?)")
                        if misses % 5 == 0 { isOpen = false }        // every few tries, reopen the cable too
                        Thread.sleep(forTimeInterval: 1)
                    }
                }
                return (false, waited)
            }

            while alive() {
                ecu.logFrames = !everConnected
                let w = waitForECU()
                guard w.ok else { break }
                if !everConnected {
                    for l in ecu.info().lines { self.say(l) }
                } else {
                    self.say("ECU is back — resuming live data")
                    ecu.log("ECU BACK")
                }
                if w.waited { DispatchQueue.main.async { if self.usbGen == gen { self.onEcuReturned?() } } }
                everConnected = true
                ecu.logFrames = false                      // live polling: log only events and errors
                setState(true, "Connected (read-only)")

                var emptyCycles = 0
                while alive() {
                    let cycleStart = Date()
                    var vals: [Int: Double] = [:]
                    var failsInRow = 0
                    for c in chans where alive() && failsInRow < 4 {
                        do {
                            let rec = try ecu.read(c.id, timeout: 0.25)
                            if let v = rec.values.first { vals[c.id] = v }  // display units, as sent
                            failsInRow = 0
                        } catch {
                            failsInRow += 1
                        }
                    }
                    if vals.isEmpty { emptyCycles += 1 } else {
                        emptyCycles = 0
                        let acquired = Date()
                        let readings = vals
                        DispatchQueue.main.async { if self.usbGen == gen { self.ingest(readings, at: acquired) } }
                    }
                    if emptyCycles >= 2 {                   // ECU went quiet (ignition off / power loss)
                        self.say("ECU stopped answering — waiting for it to come back")
                        ecu.log("ECU STOPPED ANSWERING")
                        break
                    }
                    let left = 0.02 - Date().timeIntervalSince(cycleStart)   // at most ~50 polls/s
                    if left > 0 { Thread.sleep(forTimeInterval: left) }
                }
            }
            ecu.close()
            if self.usbGen == gen { self.ecu = nil }
        }
        th.name = "Link USB"
        usbThread = th
        th.start()
    }
}
