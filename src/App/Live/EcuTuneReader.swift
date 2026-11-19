import Foundation

/// Reads the whole tune out of an ECU with read-only commands and turns it into a tune
/// document. The ECU reports each value and its type; table shapes and wire scaling come
/// from a stock template for the same ECU model (Link ID), bundled in Resources/Templates.
final class EcuTuneReader {
    struct Report {
        var linkId = ""
        var template = ""
        var read = 0
        var total = 0
        var notRead: [Int] = []          // kept from the template — flagged in the UI
        var partial: [Int] = []          // some cells missing
        var textSkipped = 0              // text settings (names/labels) — not supported yet
        var scaleUncertain: [Int] = []   // arrived as integers but their scaling varies per tune
        var firmware = ""                // as reported by the ECU, or "" if not decoded
        var seconds = 0.0
        var summary: String {
            var s = "Read \(read) of \(total) settings in \(Int(seconds.rounded())) s (Link ID \(linkId), template “\(template)”)."
            s += firmware.isEmpty ? " Firmware version couldn't be decoded — the file shows the template's." : " ECU firmware \(firmware)."
            if !notRead.isEmpty { s += " \(notRead.count) couldn't be read and show the template's value — they're marked NOT READ." }
            if !partial.isEmpty { s += " \(partial.count) were only partly read." }
            if !scaleUncertain.isEmpty { s += " \(scaleUncertain.count) have tune-specific scaling and are marked CHECK SCALING — compare them with PCLink before relying on them." }
            if textSkipped > 0 { s += " \(textSkipped) text settings (names/labels) aren't read yet and keep the template's text." }
            return s
        }
    }

    enum ReadError: Error, CustomStringConvertible {
        case noTemplates, cancelled, noMatch
        var description: String {
            switch self {
            case .noTemplates: return "OpenLink doesn't know this ECU's layout yet. Open any tune file from this ECU model once (File → Open), or import the layouts from Link's free PCLink installer (ECU → Import ECU Layouts from PCLink Installer…), then read again."
            case .cancelled: return "Cancelled."
            case .noMatch: return "Couldn't work out which Link ECU model this is."
            }
        }
    }

    struct Template { let linkId: String; let url: URL }

    /// Where learned ECU layouts live: one stock/user tune per Link ID, kept on this Mac only.
    static let templatesFolder: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLink Tuner/ECU Layouts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// Layouts this Mac knows: learned from tunes the user opened, or imported from Link's
    /// own PCLink installer. Nothing from Link is shipped with the app.
    static func templates() -> [Template] {
        let files = (try? FileManager.default.contentsOfDirectory(at: templatesFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pclx" || $0.pathExtension == "pcl5" }
            .map { Template(linkId: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.linkId < $1.linkId }
    }

    /// Remember a tune's layout for its ECU model (Link ID), if we don't have one yet.
    @discardableResult
    static func learnLayout(from url: URL, linkId: String) -> Bool {
        guard !linkId.isEmpty, Int(linkId) != nil else { return false }
        let dst = templatesFolder.appendingPathComponent("\(linkId).\(url.pathExtension.lowercased())")
        guard !FileManager.default.fileExists(atPath: dst.path) else { return false }
        return (try? FileManager.default.copyItem(at: url, to: dst)) != nil
    }

    /// Import the stock maps from Link's free PCLink installer (needs `innoextract`).
    /// Keeps one map per ECU model. Returns the Link IDs added.
    static func importFromInstaller(_ installer: URL) throws -> [String] {
        let fm = FileManager.default
        let tools = ["/opt/homebrew/bin/innoextract", "/usr/local/bin/innoextract"]
        guard let tool = tools.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "OpenLink", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "This needs the free tool innoextract. Install it with:  brew install innoextract"])
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("openlink-installer-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-s", "-d", tmp.path, installer.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "OpenLink", code: 2, userInfo: [NSLocalizedDescriptionKey: "That doesn't look like a PCLink installer."])
        }
        var maps: [URL] = []
        if let e = fm.enumerator(at: tmp, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension.lowercased() == "pclx" { maps.append(u) }
        }
        // prefer "default"/"not tuned" maps so each model gets a clean base layout
        func score(_ u: URL) -> Int { let n = u.lastPathComponent.lowercased(); return n.contains("default") || n.contains("not tuned") ? 0 : 1 }
        maps.sort { (score($0), $0.lastPathComponent) < (score($1), $1.lastPathComponent) }
        var added: [String] = []
        for m in maps {
            guard let t = try? TuneFile(fileURL: m) else { continue }
            if learnLayout(from: m, linkId: t.memory.linkID) { added.append(t.memory.linkID) }
        }
        return added
    }

    static var lastLinkId: String? {
        get { UserDefaults.standard.string(forKey: "lastLinkId") }
        set { UserDefaults.standard.set(newValue, forKey: "lastLinkId") }
    }

    var progress: ((Double, String) -> Void)?
    var isCancelled: () -> Bool = { false }

    /// Wire integer → displayed value, rounded to the decimals the multiplier implies
    /// (Multi is stored as float32: 0.00100000004749745 × 6000 must give 6, not 6.0000003).
    static func scale(_ raw: Double, multi: Double, offset: Double) -> Double {
        let v = raw * multi + offset
        guard multi > 0 && multi < 1 else { return v }
        let l = -log10(multi)
        let d = abs(l - l.rounded()) < 1e-4 ? Int(l.rounded()) : min(9, Int(l.rounded(.up)) + 3)
        let f = pow(10, Double(d))
        return (v * f).rounded() / f
    }

    private func values(of p: TuneFile.Parameter) -> Int { p.scalar != nil ? 1 : p.rows.reduce(0) { $0 + $1.count } }

    /// Choose the template: (1) a Link ID found in the identify/version replies,
    /// (2) the template whose table sizes match what the ECU reports, (3) the last ECU used.
    private func chooseTemplate(_ ecu: LinkECU, replies: [[UInt8]], from all: [Template]) throws -> (Template, TuneFile) {
        for t in all {
            guard let id = UInt32(t.linkId) else { continue }
            let pat16: [UInt8] = [UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)]
            let pat32: [UInt8] = [UInt8(id >> 24), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)]
            for r in replies where contains(r, pat32) || (id <= 0xFFFF && contains(r, pat16)) {
                progress?(0.02, "ECU reports Link ID \(t.linkId)")
                return (t, try TuneFile(fileURL: t.url))
            }
        }
        // Probe settings that exist on some ECU models but not others, then pick the model
        // whose present/absent pattern matches what the ECU answers.
        let loaded: [(Template, TuneFile)] = all.compactMap { t in (try? TuneFile(fileURL: t.url)).map { (t, $0) } }
        guard !loaded.isEmpty else { throw ReadError.noTemplates }
        let sets = loaded.map { Set($0.1.parameters.filter { !$0.readOnly && ($0.scalar != nil || !$0.rows.isEmpty) }.map(\.dataId)) }
        let union = sets.reduce(Set<Int>()) { $0.union($1) }
        let common = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }
        let disc = union.subtracting(common).sorted()
        let maxProbes = 48
        let probes = disc.count <= maxProbes ? disc
            : stride(from: 0, to: disc.count, by: max(1, disc.count / maxProbes)).map { disc[$0] }
        var present: [Int: Bool] = [:]
        for (i, id) in probes.enumerated() {
            if isCancelled() { throw ReadError.cancelled }
            progress?(0.01 + 0.02 * Double(i) / Double(max(1, probes.count)), "Identifying ECU model… \(i + 1)/\(probes.count)")
            present[id] = (try? ecu.readAll(id, expected: 1, timeout: 0.3)) != nil
        }
        if loaded.count == 1, let only = loaded.first {
            let tables = only.1.parameters.filter { !$0.readOnly && $0.rows.count > 2 }.prefix(3)
            let ok = tables.filter { p in (try? ecu.readAll(p.dataId, expected: 1, timeout: 0.3)) != nil }.count
            if ok == tables.count { progress?(0.03, "ECU model: Link ID \(only.0.linkId)"); return only }
            throw ReadError.noTemplates
        }
        if !probes.isEmpty {
            let last = Self.lastLinkId
            let scored = loaded.indices.map { i -> (Int, Int) in
                (i, probes.filter { present[$0] == sets[i].contains($0) }.count)
            }
            .sorted { x, y in
                if x.1 != y.1 { return x.1 > y.1 }
                if (loaded[x.0].0.linkId == last) != (loaded[y.0].0.linkId == last) { return loaded[x.0].0.linkId == last }
                return sets[x.0].count > sets[y.0].count
            }
            if let best = scored.first, Double(best.1) >= 0.9 * Double(probes.count) {
                let t = loaded[best.0]
                progress?(0.03, "ECU model: Link ID \(t.0.linkId) (\(best.1)/\(probes.count) checks matched)")
                return t
            }
        }
        if let last = Self.lastLinkId, let t = all.first(where: { $0.linkId == last }) { return (t, try TuneFile(fileURL: t.url)) }
        throw ReadError.noMatch
    }

    private func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard hay.count >= needle.count, !needle.isEmpty else { return false }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<i + needle.count]) == needle { return true }
        return false
    }

    /// Best-effort decode of a version reply (u32 + major/minor/build bytes) — unconfirmed on real hardware.
    static func version(_ p: [UInt8]?) -> String? {
        // confirmed on a G4X: bytes 8.. = major (u8), minor (u16), build (u16) → "6.31.2"
        guard let p, p.count >= 13 else { return nil }
        let a = Int(p[8]), b = Int(p[9]) << 8 | Int(p[10]), c = Int(p[11]) << 8 | Int(p[12])
        guard (1...30).contains(a), b < 1000, c < 1000 else { return nil }
        return "\(a).\(b).\(c)"
    }

    var firmwareReply: [UInt8]?

    func run(_ ecu: LinkECU, replies: [[UInt8]]) throws -> (TuneFile, Report) {
        let began = Date()
        let all = Self.templates()
        guard !all.isEmpty else { throw ReadError.noTemplates }
        let (tmpl, tune) = try chooseTemplate(ecu, replies: replies, from: all)
        var rep = Report(linkId: tmpl.linkId, template: tmpl.url.lastPathComponent)
        let params = tune.parameters.filter { !$0.readOnly && ($0.scalar != nil || !$0.rows.isEmpty) }
        rep.textSkipped = tune.parameters.filter { !$0.readOnly && $0.scalar == nil && $0.rows.isEmpty }.count
        rep.total = params.count
        ecu.logFrames = false                       // keep the raw log readable: only log failures below
        defer { ecu.logFrames = true }
        for (i, p) in params.enumerated() {
            if isCancelled() { throw ReadError.cancelled }
            if i % 25 == 0 { progress?(0.03 + 0.97 * Double(i) / Double(params.count), "Reading settings… \(i) of \(params.count)") }
            let n = values(of: p)
            var data: LinkECU.ParameterData?
            for _ in 0..<2 where data == nil { data = try? ecu.readAll(p.dataId, expected: n) }
            guard let d = data else { rep.notRead.append(p.dataId); ecu.log("READ FAIL D\(p.dataId)"); continue }
            let vals = d.values.enumerated().map { idx, v -> Double in
                if v.isNaN { return (p.scalar.map { [$0] } ?? p.rows.flatMap { $0 })[safe: idx] ?? 0 }
                // the ECU sends display units: floats for numbers, plain integers for options/modes
                return v
            }
            tune.setValues(p.dataId, vals)
            rep.read += 1
            if !d.complete { rep.partial.append(p.dataId) }
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        tune.setMemory("Memo", "Read from ECU by OpenLink Tuner on \(f.string(from: Date())) — template \(tmpl.url.lastPathComponent)")
        tune.setMemory("SerialNumber", "")                 // never show the template car's serial
        if let fw = Self.version(firmwareReply) { tune.setMemory("Firmware", fw); rep.firmware = fw }
        rep.seconds = Date().timeIntervalSince(began)
        Self.lastLinkId = tmpl.linkId
        progress?(1, "Done")
        return (tune, rep)
    }
}
