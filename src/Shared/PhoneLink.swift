import Foundation
import Network
import Security
import CryptoKit

/// Mac ↔ iPhone link: Bonjour-advertised authenticated TLS, each message = 4-byte big-endian length + JSON.
/// Compiled into both the Mac app and the iPhone app.
enum PhoneLink {
    static let serviceType = "_openlink2._tcp"
    static let version = 2

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

/// Each approval has a random 128-bit secret. Only its discovery hash is advertised.
struct PhonePair: Codable, Identifiable {
    let secret: Data
    var name: String
    var id: String { "OL-" + SHA256.hash(data: secret).prefix(12).map { String(format: "%02x", $0) }.joined() }
    var code: String {
        stride(from: 0, to: secret.count, by: 2).map { index in
            secret[index..<index + 2].map { String(format: "%02X", $0) }.joined()
        }.joined(separator: "-")
    }

    init(name: String) {
        self.name = name
        secret = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    init?(code: String, name: String) {
        let hex = code.filter { !$0.isWhitespace && $0 != "-" }
        guard hex.utf8.count == 32, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        secret = bytes
        self.name = name
    }

    static let cipher = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!

    var parameters: NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        // Require a fresh proof of this phone’s key on every connection.
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_false_start_enabled(options, false)
        sec_protocol_options_append_tls_ciphersuite(options, Self.cipher)
        let key = secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(id.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }

    static func authenticated(_ connection: NWConnection) -> Bool {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls.securityProtocolMetadata) == cipher
    }
}

enum PairStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "OpenLink") + ".pairing.v2",
         kSecAttrAccount as String: "approved-peers"]
    }

    static func load() throws -> [PhonePair] {
        var request = query
        request[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let pairs = try JSONDecoder().decode([PhonePair].self, from: data)
        guard pairs.allSatisfy({ $0.secret.count == 16 }) else { throw CocoaError(.fileReadCorruptFile) }
        return pairs
    }

    static func save(_ pairs: [PhonePair]) throws {
        let data = try JSONEncoder().encode(pairs)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
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
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                guard PhonePair.authenticated(self.connection) else { self.cancel(); return }
                self.onState?(state)
                self.receiveLength()
            } else { self.onState?(state) }
        }
        connection.start(queue: .main)
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
