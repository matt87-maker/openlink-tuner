import Foundation

/// Byte pipe to an ECU (the Link USB cable, via FTDI).
protocol LinkTransport: AnyObject {
    func openLink() throws -> String
    func closeLink()
    func purge()
    func write(_ bytes: [UInt8]) throws
    func read(_ count: Int, timeout: TimeInterval) throws -> [UInt8]
}

extension FTDI: LinkTransport {
    func openLink() throws -> String {
        try open()
        return String(format: "cable 0403:%04X, chip type %d, %d baud", productId, chipType, baud)
    }
    func closeLink() { close() }
}

/// A read-only session with a Link G4X. All traffic goes through `LinkWire.frame`,
/// which refuses any command outside the read-only allowlist.
/// Every frame is written to a raw log so the first real-ECU session can be analysed.
final class LinkECU {
    private let io: LinkTransport
    private var address = LinkWire.ecuAddress
    private let logURL: URL
    private var logHandle: FileHandle?
    var onUnsolicited: ((LinkWire.ParameterRecord) -> Void)?
    var valueOffset = 10            // where values start in a parameter record (to be confirmed)
    var logFrames = true

    init(transport: LinkTransport) {
        io = transport
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OpenLink Tuner", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        logURL = dir.appendingPathComponent("usb-\(stamp).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
    }

    convenience init() throws { self.init(transport: try FTDI()) }

    deinit { close() }

    var rawLogPath: String { logURL.path }

    func log(_ s: String) {
        let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(s)\n"
        logHandle?.write(Data(line.utf8))
    }

    func open() throws -> String {
        let d = try io.openLink()
        log("OPEN \(d)")
        return d
    }

    /// Close and reopen the cable (used while waiting for an ECU to power back up).
    func reopenTransport() throws -> String {
        io.closeLink()
        let d = try io.openLink()
        log("OPEN \(d)")
        return d
    }

    func close() {
        if logHandle != nil { log("CLOSE") }
        io.closeLink()
        try? logHandle?.close(); logHandle = nil
    }

    private func send(_ cmd: LinkWire.Command, payload: [UInt8], to a: UInt8) throws {
        let f = try LinkWire.frame(cmd, payload: payload, address: a)
        io.purge()
        if logFrames { log("TX " + LinkWire.hex(f)) }
        try io.write(f)
    }

    private func readPacket(from a: UInt8, until deadline: Date) throws -> LinkWire.Response {
        let h = try io.read(6, timeout: max(0.05, deadline.timeIntervalSinceNow))
        let body = try io.read(LinkWire.bodyLength(header: h), timeout: max(0.05, deadline.timeIntervalSinceNow))
        if logFrames { log("RX " + LinkWire.hex(h + body)) }
        return try LinkWire.parse(header: h, body: body, expectAddress: a)
    }

    /// Send one allowlisted command and return the response that echoes it.
    /// Parameter records arriving in between are passed to `onUnsolicited`, as PCLink does.
    func transact(_ cmd: LinkWire.Command, payload: [UInt8] = [], to addr: UInt8? = nil,
                  timeout: TimeInterval = 0.4) throws -> LinkWire.Response {
        let a = addr ?? address
        try send(cmd, payload: payload, to: a)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let r = try readPacket(from: a, until: deadline)
            if r.command == LinkWire.errorReply {
                let code = r.payload.count >= 2 ? UInt16(r.payload[0]) << 8 | UInt16(r.payload[1]) : 0
                log(String(format: "ECU ERROR 0x%04X for cmd 0x%02X", code, cmd.rawValue))
                throw LinkWire.WireError.ecuError(code)
            }
            if r.command == cmd.rawValue { return r }
            if [0x2B, 0x2A, 0x0F].contains(r.command), let rec = LinkWire.parseParameter(r.payload, valueOffset: valueOffset) {
                onUnsolicited?(rec)
            }
            if Date() > deadline { throw LinkWire.WireError.short }
        }
    }

    /// Connect check. A real G4X (fw 6.31.2) rejects the broadcast identify (0x0A on 0x7D) with
    /// error 0x0020 but answers the capabilities query on its own address 0x5B — so use that.
    func identify(timeout: TimeInterval = 1.0) throws -> LinkWire.Response {
        address = LinkWire.ecuAddress
        return try transact(.capabilities, timeout: timeout)
    }

    struct Info { var lines: [String]; var payloads: [[UInt8]]; var byName: [String: [UInt8]] = [:] }

    func info() -> Info {
        var lines: [String] = [], payloads: [[UInt8]] = [], byName: [String: [UInt8]] = [:]
        for (name, cmd) in [("Capabilities", LinkWire.Command.capabilities), ("Firmware", .firmwareVersion),
                            ("Bootcode", .bootVersion), ("Version B", .versionB), ("Comms", .commsVersion)] {
            do {
                let r = try transact(cmd, timeout: 0.6)
                lines.append("\(name): \(LinkWire.hex(r.payload))"); payloads.append(r.payload); byName[name] = r.payload
            } catch { lines.append("\(name): \(error)") }
        }
        return Info(lines: lines, payloads: payloads, byName: byName)
    }

    /// Read one cell (tables) or the value (scalars, arg 0xFFFF).
    func readCell(_ dataId: Int, arg: UInt16 = 0xFFFF, timeout: TimeInterval = 0.4) throws -> LinkWire.ParameterRecord {
        let r = try transact(.readParameter, payload: LinkWire.readParameterPayload(dataId: UInt16(dataId), arg: arg), timeout: timeout)
        guard let rec = LinkWire.parseValue(r.payload, dataId: UInt16(dataId)) else { throw LinkWire.WireError.short }
        return rec
    }

    /// Read one value (live channels).
    func read(_ dataId: Int, timeout: TimeInterval = 0.4) throws -> LinkWire.ParameterRecord {
        try readCell(dataId, timeout: timeout)
    }

    struct ParameterData { let type: UInt16; let values: [Double]; let complete: Bool }

    /// Read every value of a parameter: scalars in one request, tables one cell per request
    /// (the request's second argument is the cell index — confirmed on a real G4X).
    func readAll(_ dataId: Int, expected: Int, timeout: TimeInterval = 0.4) throws -> ParameterData {
        if expected <= 1 {
            let r = try readCell(dataId, timeout: timeout)
            return ParameterData(type: r.type, values: [r.values.first ?? .nan], complete: !r.values.isEmpty)
        }
        var vals: [Double] = [], type: UInt16 = 0
        vals.reserveCapacity(expected)
        for i in 0..<expected {
            let r = try readCell(dataId, arg: UInt16(i), timeout: timeout)
            type = r.type
            vals.append(r.values.first ?? .nan)
        }
        return ParameterData(type: type, values: vals, complete: true)
    }
}
