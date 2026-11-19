import Foundation

/// Minimal FTDI access through libftdi1 (Homebrew: `brew install libftdi`), loaded with dlopen
/// so the app still runs without it. Link cables use FTDI VID 0x0403 with custom PIDs
/// 0x7068–0x706F, which Apple's built-in FTDI serial driver doesn't claim.
final class FTDI {
    enum FTDIError: Error, CustomStringConvertible {
        case libraryMissing, noDevice, call(String, Int32, String)
        var description: String {
            switch self {
            case .libraryMissing: return "The USB driver library (libftdi) is missing. Re-download OpenLink Tuner, or run: brew install libftdi"
            case .noDevice: return "No Link USB cable found (FTDI 0403:7068–706F). Is the ECU powered and the cable plugged in?"
            case .call(let f, let rc, let msg): return "\(f) failed (\(rc)): \(msg)"
            }
        }
    }

    static let vendor: Int32 = 0x0403
    static let products: [Int32] = Array(0x7068...0x706F)

    private typealias FNew = @convention(c) () -> OpaquePointer?
    private typealias FFree = @convention(c) (OpaquePointer?) -> Void
    private typealias FOpen = @convention(c) (OpaquePointer?, Int32, Int32) -> Int32
    private typealias FCtx = @convention(c) (OpaquePointer?) -> Int32
    private typealias FInt = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias FLine = @convention(c) (OpaquePointer?, Int32, Int32, Int32) -> Int32
    private typealias FLat = @convention(c) (OpaquePointer?, UInt8) -> Int32
    private typealias FIO = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias FErr = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    private let lib: UnsafeMutableRawPointer
    private let fNew: FNew, fFree: FFree, fOpen: FOpen, fClose: FCtx, fBaud: FInt, fLine: FLine
    private let fLatency: FLat, fWrite: FIO, fRead: FIO, fPurge: FCtx, fErr: FErr
    private var ctx: OpaquePointer?
    private(set) var productId: Int32 = 0
    private(set) var chipType: Int32 = -1
    private(set) var baud: Int32 = 0

    init() throws {
        // bundled copy first (shipped inside the app), then Homebrew / system copies
        var paths: [String] = []
        if let fw = Bundle.main.privateFrameworksPath { paths.append(fw + "/libftdi1.2.dylib") }
        paths += ["/opt/homebrew/lib/libftdi1.2.dylib", "/usr/local/lib/libftdi1.2.dylib", "libftdi1.2.dylib", "libftdi1.dylib"]
        guard let h = paths.lazy.compactMap({ dlopen($0, RTLD_NOW) }).first else { throw FTDIError.libraryMissing }
        lib = h
        func sym<T>(_ n: String, _: T.Type) throws -> T {
            guard let p = dlsym(h, n) else { throw FTDIError.libraryMissing }
            return unsafeBitCast(p, to: T.self)
        }
        fNew = try sym("ftdi_new", FNew.self); fFree = try sym("ftdi_free", FFree.self)
        fOpen = try sym("ftdi_usb_open", FOpen.self); fClose = try sym("ftdi_usb_close", FCtx.self)
        fBaud = try sym("ftdi_set_baudrate", FInt.self); fLine = try sym("ftdi_set_line_property", FLine.self)
        fLatency = try sym("ftdi_set_latency_timer", FLat.self)
        fWrite = try sym("ftdi_write_data", FIO.self); fRead = try sym("ftdi_read_data", FIO.self)
        if let f = try? sym("ftdi_tcioflush", FCtx.self) { fPurge = f } else { fPurge = try sym("ftdi_usb_purge_buffers", FCtx.self) }
        fErr = try sym("ftdi_get_error_string", FErr.self)
    }

    deinit { close(); dlclose(lib) }

    static var libraryAvailable: Bool { (try? FTDI()) != nil }

    private func err() -> String { fErr(ctx).map { String(cString: $0) } ?? "unknown" }
    private func check(_ name: String, _ rc: Int32) throws { if rc < 0 { throw FTDIError.call(name, rc, err()) } }

    /// Open the first Link cable found and configure it like PCLink does:
    /// 8N1, purge, baud chosen by chip type (FT232H → 4 687 500, FT-X → 1 171 875).
    func open(baudOverride: Int32? = nil) throws {
        close()
        guard let c = fNew() else { throw FTDIError.call("ftdi_new", -1, "out of memory") }
        ctx = c
        var opened = false
        for pid in Self.products where fOpen(c, Self.vendor, pid) == 0 { productId = pid; opened = true; break }
        guard opened else { fFree(c); ctx = nil; throw FTDIError.noDevice }
        // libftdi 1.5 struct ftdi_context: usb_ctx*, usb_dev*, int usb_read_timeout, int usb_write_timeout, enum type
        let raw = UnsafeMutableRawPointer(c)
        raw.storeBytes(of: Int32(100), toByteOffset: 16, as: Int32.self)   // read timeout 100 ms
        raw.storeBytes(of: Int32(300), toByteOffset: 20, as: Int32.self)   // write timeout 300 ms (as PCLink)
        chipType = raw.load(fromByteOffset: 24, as: Int32.self)            // 6 = FT232H, 7 = FT-X (230X)
        baud = baudOverride ?? (chipType == 7 ? 1_171_875 : 4_687_500)
        try check("ftdi_set_baudrate", fBaud(c, baud))
        try check("ftdi_set_line_property", fLine(c, 8, 0, 0))             // 8 bits, 1 stop, no parity
        _ = fLatency(c, 2)
        purge()
    }

    func close() {
        guard let c = ctx else { return }
        _ = fClose(c); fFree(c); ctx = nil
    }

    var isOpen: Bool { ctx != nil }

    func purge() { if let c = ctx { _ = fPurge(c) } }

    /// Last line of defence: only well-formed frames carrying a read-only command may reach
    /// the cable. Anything else (any write/store/reset/firmware command) is refused here,
    /// independently of LinkWire's own allowlist.
    static func isReadOnlyFrame(_ f: [UInt8]) -> Bool {
        guard f.count >= 8, f[0] == 0x5A, LinkWire.crc16(f) == 0 else { return false }
        let cmd = UInt16(f[2]) << 8 | UInt16(f[3])
        return LinkWire.allowed.contains { $0.rawValue == cmd }
    }

    func write(_ bytes: [UInt8]) throws {
        guard Self.isReadOnlyFrame(bytes) else {
            throw FTDIError.call("write", -1, "refused: not a read-only frame (\(LinkWire.hex(Array(bytes.prefix(8)))))")
        }
        var b = bytes
        let n = b.withUnsafeMutableBufferPointer { fWrite(ctx, $0.baseAddress, Int32($0.count)) }
        if n != Int32(bytes.count) { throw FTDIError.call("ftdi_write_data", n, err()) }
    }

    /// Read exactly `count` bytes or throw after `timeout` seconds.
    func read(_ count: Int, timeout: TimeInterval) throws -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: max(count, 64))
        let deadline = Date().addingTimeInterval(timeout)
        while out.count < count {
            let want = Int32(count - out.count)
            let n = buf.withUnsafeMutableBufferPointer { fRead(ctx, $0.baseAddress, want) }
            if n < 0 { throw FTDIError.call("ftdi_read_data", n, err()) }
            if n > 0 { out += buf[0..<Int(n)] }
            if out.count < count && Date() > deadline { throw FTDIError.call("read", -1, "timed out after \(out.count)/\(count) bytes") }
        }
        return out
    }
}
