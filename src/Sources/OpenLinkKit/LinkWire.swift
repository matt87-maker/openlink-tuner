import Foundation

/// Link G4X USB wire protocol, reverse-engineered from PCLink 7.8.2
/// (`TECUProtocolG4x`, see docs/G4X-PROTOCOL.md). Pure functions only — no I/O.
///
/// Request:  5A | addr | cmd(16 BE) | len+2 (16 BE) | payload | CRC16 (BE)
/// Response: addr | 5A/01 | cmd(16 BE) | len (16 BE) | payload… | CRC16 (BE)
/// CRC-16/XMODEM (poly 0x1021, init 0, MSB first) over everything before it.
public enum LinkWire {

    /// Address PCLink uses for normal traffic, and the broadcast address used for discovery.
    public static let ecuAddress: UInt8 = 0x5B
    public static let broadcastAddress: UInt8 = 0x7D

    /// Command codes seen in PCLink. Only `allowed` ones may ever be sent by this app.
    public enum Command: UInt16, CaseIterable {
        case discover = 0x07        // broadcast discovery
        case identify = 0x0A        // broadcast identify / connect
        case capabilities = 0x0B    // returns packet-size and info fields
        case firmwareVersion = 0x16 // u32 + 3 bytes
        case bootVersion = 0x18
        case versionB = 0x3B
        case commsVersion = 0x3D
        case readParameter = 0x2B   // payload: DataId(16) + arg(16), response: parameter record

        // ---- never sent (documented only) ----
        case writeBlock = 0x14      // writes memory/flash in 1 KB blocks
        case writeParameter = 0x2A  // writes parameter values
        case store = 0x20
        case reset = 0x21
        case modeA = 0x22, modeB = 0x12, setFlag = 0x23, setWords = 0x24, setLong = 0x1E
        case fileTransfer = 0x2E    // ECU log file download (format not fully mapped yet)
    }

    /// Commands that only read. Anything else is refused by `frame(...)`.
    public static let allowed: Set<Command> = [.discover, .identify, .capabilities, .firmwareVersion,
                                               .bootVersion, .versionB, .commsVersion, .readParameter]

    public enum WireError: Error, CustomStringConvertible {
        case blocked(UInt16), badHeader, badAddress(UInt8), badCRC, short, ecuError(UInt16)
        public var description: String {
            switch self {
            case .blocked(let c): return String(format: "command 0x%02X is blocked (read-only mode)", c)
            case .badHeader: return "bad response header"
            case .badAddress(let a): return String(format: "response from unexpected address 0x%02X", a)
            case .badCRC: return "response CRC mismatch"
            case .short: return "response too short"
            case .ecuError(let c): return String(format: "ECU replied with error 0x%04X", c)
            }
        }
    }

    // MARK: CRC

    public static func crc16(_ bytes: some Sequence<UInt8>, initial: UInt16 = 0) -> UInt16 {
        var crc = initial
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    // MARK: requests

    public static func frame(_ cmd: Command, payload: [UInt8] = [], address: UInt8 = ecuAddress) throws -> [UInt8] {
        guard allowed.contains(cmd) else { throw WireError.blocked(cmd.rawValue) }
        let len = payload.count + 2
        var f: [UInt8] = [0x5A, address, UInt8(cmd.rawValue >> 8), UInt8(cmd.rawValue & 0xFF),
                          UInt8(len >> 8), UInt8(len & 0xFF)]
        f += payload
        let c = crc16(f)
        f += [UInt8(c >> 8), UInt8(c & 0xFF)]
        return f
    }

    /// PCLink sends read-parameter requests as a fixed 56-byte payload; arg 0xFFFF = all values
    /// (as in PCLink's read loop at 0x425C40).
    public static func readParameterPayload(dataId: UInt16, arg: UInt16 = 0xFFFF) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 0x38)
        p[0] = UInt8(dataId >> 8); p[1] = UInt8(dataId & 0xFF)
        p[2] = UInt8(arg >> 8); p[3] = UInt8(arg & 0xFF)
        return p
    }

    // MARK: responses

    public struct Response {
        public let address: UInt8
        public let status: UInt8       // 0x5A = ok; 0x01 also accepted by PCLink
        public let command: UInt16
        public let payload: [UInt8]    // without CRC
    }

    /// Response command 0x19 = error reply; payload u16 = ECU error code (PCLink 0x425E69).
    public static let errorReply: UInt16 = 0x19

    /// Length of the body that follows a 6-byte header.
    public static func bodyLength(header h: [UInt8]) -> Int { Int(h[4]) << 8 | Int(h[5]) }

    public static func parse(header h: [UInt8], body: [UInt8], expectAddress: UInt8, checkCRC: Bool = true) throws -> Response {
        guard h.count == 6 else { throw WireError.short }
        guard h[1] == 0x5A || h[1] == 0x01 else { throw WireError.badHeader }
        // replies to a broadcast come back from the ECU's own address
        guard h[0] == expectAddress || expectAddress == broadcastAddress else { throw WireError.badAddress(h[0]) }
        guard body.count == bodyLength(header: h), body.count >= 2 else { throw WireError.short }
        if checkCRC, crc16(h + body) != 0 { throw WireError.badCRC }
        return Response(address: h[0], status: h[1], command: UInt16(h[2]) << 8 | UInt16(h[3]),
                        payload: Array(body.dropLast(2)))
    }

    // MARK: parameter records (responses to 0x2B; also 0x2A / 0x0F)

    public struct ParameterRecord {
        public let type: UInt16
        public let dataId: UInt16
        public let startIndex: Int
        public let count: Int
        public let values: [Double]
        public let raw: [UInt8]
    }

    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { o + 1 < b.count ? UInt16(b[o]) << 8 | UInt16(b[o + 1]) : 0 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        o + 3 < b.count ? UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) : 0
    }

    /// Type codes from PCLink's dispatcher: 1/5 = float32, 2/3/8/9 = int32, 4/7 = blob.
    public static func isFloatType(_ t: UInt16) -> Bool { t == 1 || t == 5 }

    /// Layout (as read by PCLink at 0x424FF0): +2 type, +4 DataId, +6 start index (−1 → 0),
    /// +8 count, values from +10 as 4-byte big-endian float32/int32.
    /// The value offset (+10) is inferred and must be confirmed against a real ECU.
    public static func parseParameter(_ payload: [UInt8], valueOffset: Int = 10) -> ParameterRecord? {
        guard payload.count >= valueOffset else { return nil }
        let type = u16(payload, 2)
        let id = u16(payload, 4)
        let startRaw = Int16(bitPattern: u16(payload, 6))
        let count = Int(u16(payload, 8))
        var vals: [Double] = []
        var o = valueOffset
        while o + 3 < payload.count && vals.count < max(count, 1) {
            let bits = u32(payload, o)
            if isFloatType(type) {
                // shortest decimal that round-trips the float32 (0.1f → 0.1, not 0.10000000149)
                let f = Float(bitPattern: bits)
                vals.append(Double(f.description) ?? Double(f))
            } else {
                vals.append(Double(Int32(bitPattern: bits)))
            }
            o += 4
        }
        return ParameterRecord(type: type, dataId: id, startIndex: startRaw < 0 ? 0 : Int(startRaw),
                               count: count, values: vals, raw: payload)
    }

    /// Reply to a 0x2B read, as confirmed on a real G4X (fw 6.31.2):
    /// payload = [00 00][type u16][value(s), 4 bytes big-endian]. Type 1 = float scalar,
    /// 5 = float array cell; values are already in display units.
    /// Request arg = cell index for tables (row-major), 0xFFFF for scalars.
    public static func parseValue(_ payload: [UInt8], dataId: UInt16) -> ParameterRecord? {
        guard payload.count >= 8 else { return nil }
        let type = u16(payload, 2)
        var vals: [Double] = []
        var o = 4
        while o + 3 < payload.count {
            let bits = u32(payload, o)
            if isFloatType(type) {
                let f = Float(bitPattern: bits)
                vals.append(Double(f.description) ?? Double(f))
            } else {
                vals.append(Double(Int32(bitPattern: bits)))
            }
            o += 4
        }
        return ParameterRecord(type: type, dataId: dataId, startIndex: 0, count: vals.count, values: vals, raw: payload)
    }

    public static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
