import Foundation

/// Human-readable names and PCLink categories for every DataId, mined from the
/// decrypted `ECU.cfgr` master schema (4560 parameters). Each parameter's
/// `HelpURL` topic prefix is its PCLink functional group, e.g.
/// `Boost_Control_Settings`, `FuelPump`, `Knock_Control_Settings`.
public struct Catalog {
    public struct Entry {
        public let name: String
        public let topic: String
        public let vt: String       // ValueType (units family)
        public let unit: String     // display unit, e.g. "%"
        public let dp: String       // decimal places
        public let min: String
        public let max: String
        public let xl: Int?         // DataId of X-axis label array (table columns)
        public let yl: Int?         // DataId of Y-axis label array (table rows)
        public let xp: Int?         // DataId of the X-axis source setting
        public let yp: Int?         // DataId of the Y-axis source setting
    }

    public private(set) var byId: [Int: Entry] = [:]

    private enum RawKeys {} // placeholder

    public init?(data: Data) {
        // JSON is { "<dataId>": {name,topic,vt,dp,unit}, ... }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return nil }
        for (k, v) in obj {
            guard let id = Int(k) else { continue }
            byId[id] = Entry(name: v["name"] ?? "", topic: v["topic"] ?? "",
                             vt: v["vt"] ?? "", unit: v["unit"] ?? "", dp: v["dp"] ?? "",
                             min: v["min"] ?? "", max: v["max"] ?? "",
                             xl: v["xl"].flatMap { Int($0) }, yl: v["yl"].flatMap { Int($0) },
                             xp: v["xp"].flatMap { Int($0) }, yp: v["yp"].flatMap { Int($0) })
        }
    }

    /// Load the catalog bundled in the app's Resources.
    public static func bundled() -> Catalog? {
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: "catalog", withExtension: "json") { candidates.append(u) }
        // Fallback: next to the executable (CLI / dev runs).
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("catalog.json"))
        candidates.append(exeDir.appendingPathComponent("Resources/catalog.json"))
        for url in candidates {
            if let d = try? Data(contentsOf: url), let c = Catalog(data: d) { return c }
        }
        return nil
    }

    public func name(_ id: Int) -> String { byId[id]?.name ?? "D\(id)" }
    public func topic(_ id: Int) -> String { byId[id]?.topic ?? "" }

    /// A tidy display label for a raw help-topic group, e.g.
    /// "Boost_Control_Settings" → "Boost Control".
    public static func prettyGroup(_ topic: String) -> String {
        var s = topic.replacingOccurrences(of: "_", with: " ")
                     .replacingOccurrences(of: "-", with: " ")
        for suffix in [" Settings", " Runtimes"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        s = s.trimmingCharacters(in: .whitespaces)
        // Fall back to "Other" for empty or non-alphabetic (e.g. "??") topics.
        if s.isEmpty || !s.contains(where: { $0.isLetter }) { return "Other" }
        return s
    }
}
