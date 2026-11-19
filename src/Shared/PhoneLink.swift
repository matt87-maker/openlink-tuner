import Foundation
import Network

/// Mac ↔ iPhone link: Bonjour-advertised TCP, each message = 4-byte big-endian length + JSON.
/// Compiled into both the Mac app and the iPhone app.
enum PhoneLink {
    static let serviceType = "_openlink._tcp"
    static let version = 1

    struct Channel: Codable, Hashable, Identifiable {
        var id: Int            // ECU DataId
        var name: String
        var unit: String
        var min: Double
        var max: Double
        var warn: Double?      // optional warning threshold (high)
    }

    struct Hello: Codable {
        var version: Int
        var macName: String
        var tuneName: String?
        var ecu: String?             // e.g. "Link ID 23000, fw 6.31.2"
        var source: String           // "none" | "usb"
        var sourceDetail: String
        var recording: Bool
    }

    /// One sample of every channel, in the order of the last `channels` message.
    struct Frame: Codable {
        var t: Double                // seconds since 1970
        var values: [Double?]
    }

    struct LogInfo: Codable, Identifiable, Hashable {
        var id: String               // file name
        var date: Date
        var duration: Double         // seconds
        var samples: Int
        var bytes: Int
        var channels: [String]
    }

    enum Message: Codable {
        // Mac → iPhone
        case hello(Hello)
        case channels([Channel])
        case frame(Frame)
        case logs([LogInfo])
        case logData(name: String, csv: String)
        case tune(name: String, json: String)
        case notice(String)
        // iPhone → Mac
        case subscribe(Bool)
        case listLogs
        case getLog(String)
        case getTune
        case setRecording(Bool)
    }
}

/// Wraps an NWConnection with message framing. Callbacks arrive on the main queue.
final class LinkConnection {
    let connection: NWConnection
    var onMessage: ((PhoneLink.Message) -> Void)?
    var onState: ((NWConnection.State) -> Void)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(_ c: NWConnection) {
        connection = c
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] st in DispatchQueue.main.async { self?.onState?(st) } }
        connection.start(queue: .global(qos: .userInitiated))
        receiveLength()
    }

    func cancel() { connection.cancel() }

    func send(_ m: PhoneLink.Message) {
        guard let body = try? encoder.encode(m) else { return }
        var len = UInt32(body.count).bigEndian
        var data = Data(bytes: &len, count: 4)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLength() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, done, err in
            guard let self, let data, data.count == 4, err == nil else { if done || err != nil { self?.connection.cancel() }; return }
            let n = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            guard n > 0, n < 64 << 20 else { self.connection.cancel(); return }
            self.receiveBody(n)
        }
    }

    private func receiveBody(_ n: Int) {
        connection.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, done, err in
            guard let self, let data, data.count == n, err == nil else { if done || err != nil { self?.connection.cancel() }; return }
            if let m = try? self.decoder.decode(PhoneLink.Message.self, from: data) {
                DispatchQueue.main.async { self.onMessage?(m) }
            }
            self.receiveLength()
        }
    }
}
