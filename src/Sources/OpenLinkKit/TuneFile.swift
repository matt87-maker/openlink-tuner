import Foundation

/// A parsed, **editable** Link tune (`.pclx` / `.pcl5`). Backed by an in-memory
/// XML DOM (`XMLDocument`) so edited values can be written straight back and
/// re-encrypted. The decrypted payload is a `LinkStorage` XML document: a
/// `<Memory>` block and a `<Map>` of `D<id>` parameters keyed by `DataId`.
/// Engineering value = raw * `Multi` + `Offset`.
public final class TuneFile {
    public struct Memory {
        public var firmware = "", bootcode = "", hwRevision = ""
        public var ecuMinSpec = "", linkID = "", serialNumber = "", memo = ""
    }
    public struct Parameter: Identifiable {
        public var id: Int { dataId }
        public let dataId: Int
        public let type: Int
        public let multi: Double
        public let offset: Double
        public let readOnly: Bool
        public let rowCount: Int
        public let colCount: Int
        public var scalar: Double?      // scalar raw value (nil for tables)
        public var rows: [[Double]]     // table raw values (empty for scalars)

        public var isTable: Bool { !rows.isEmpty || rowCount > 1 || colCount > 1 }
        public func scaled(_ raw: Double) -> Double { raw * multi + offset }
        public func unscaled(_ eng: Double) -> Double { multi == 0 ? eng : (eng - offset) / multi }
        public var scaledScalar: Double? { scalar.map(scaled) }
    }

    public private(set) var memory = Memory()
    public private(set) var parameters: [Parameter] = []
    public private(set) var isDirty = false

    /// The decrypted XML exactly as it came out of the file (for raw export).
    public let originalPlaintext: Data
    private let document: XMLDocument
    private var elementById: [Int: XMLElement] = [:]
    private var indexById: [Int: Int] = [:]   // dataId -> index in `parameters`

    public convenience init(fileURL: URL) throws {
        try self.init(encrypted: try Data(contentsOf: fileURL))
    }

    public convenience init(encrypted raw: Data) throws {
        try self.init(plaintext: try TuneCrypt.decrypt(raw))
    }

    /// Build from already-decrypted LinkStorage XML.
    public init(plaintext plain: Data) throws {
        originalPlaintext = plain
        document = try XMLDocument(data: plain, options: [.nodePreserveWhitespace])
        parse()
    }

    private func parse() {
        guard let root = document.rootElement() else { return }
        if let mem = root.elements(forName: "Memory").first {
            func v(_ n: String) -> String { mem.elements(forName: n).first?.attribute(forName: "Value")?.stringValue ?? "" }
            memory = Memory(firmware: v("Firmware"), bootcode: v("Bootcode"), hwRevision: v("HWRevision"),
                            ecuMinSpec: v("ECUMinSpec"), linkID: v("LinkID"),
                            serialNumber: v("SerialNumber"), memo: v("Memo"))
        }
        guard let map = root.elements(forName: "Map").first else { return }
        for el in map.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            guard el.name?.first == "D",
                  let a = el.attribute(forName: "DataId")?.stringValue, let id = Int(a) else { continue }
            func num(_ n: String, _ d: Double) -> Double { Double(el.attribute(forName: n)?.stringValue ?? "") ?? d }
            let rowEls = el.children?.compactMap { $0 as? XMLElement }.filter { ($0.name ?? "").hasPrefix("Row") } ?? []
            var rows: [[Double]] = []
            for r in rowEls {
                let csv = r.attribute(forName: "Value")?.stringValue ?? ""
                rows.append(csv.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 })
            }
            let p = Parameter(
                dataId: id,
                type: Int(el.attribute(forName: "Type")?.stringValue ?? "0") ?? 0,
                multi: num("Multi", 1), offset: num("Offset", 0),
                readOnly: (el.attribute(forName: "ReadOnly")?.stringValue ?? "false") == "true",
                rowCount: Int(num("RowCount", 1)), colCount: Int(num("ColCount", 1)),
                scalar: el.attribute(forName: "Value").flatMap { Double($0.stringValue ?? "") },
                rows: rows)
            elementById[id] = el
            indexById[id] = parameters.count
            parameters.append(p)
        }
    }

    public func parameter(_ dataId: Int) -> Parameter? { indexById[dataId].map { parameters[$0] } }

    /// Format a raw value for storage, matching the look of existing values.
    private func fmtRaw(_ v: Double, decimals: Int?) -> String {
        if let d = decimals, d >= 0 { return String(format: "%.\(d)f", v) }
        if v == v.rounded() { return String(format: "%.1f", v) }  // keep "x.0" look
        return String(v)
    }

    /// Set a scalar parameter's stored value (what the PCLink grid shows).
    @discardableResult
    public func setScalar(_ dataId: Int, value: Double, decimals: Int? = nil) -> Bool {
        guard let idx = indexById[dataId], let el = elementById[dataId], el.attribute(forName: "Value") != nil else { return false }
        el.attribute(forName: "Value")?.stringValue = fmtRaw(value, decimals: decimals)
        parameters[idx].scalar = value
        isDirty = true
        return true
    }

    /// Set one table cell's stored value.
    @discardableResult
    public func setCell(_ dataId: Int, row: Int, col: Int, value: Double, decimals: Int? = nil) -> Bool {
        guard let idx = indexById[dataId], let el = elementById[dataId],
              row < parameters[idx].rows.count, col < parameters[idx].rows[row].count else { return false }
        parameters[idx].rows[row][col] = value
        let rowEls = el.children?.compactMap { $0 as? XMLElement }.filter { ($0.name ?? "").hasPrefix("Row") } ?? []
        guard row < rowEls.count else { return false }
        let csv = parameters[idx].rows[row].map { fmtRaw($0, decimals: decimals) }.joined(separator: ",")
        rowEls[row].attribute(forName: "Value")?.stringValue = csv
        isDirty = true
        return true
    }

    /// Replace all of a parameter's values (scalar: first value; table: row-major).
    /// Used when filling a template with values read from an ECU.
    @discardableResult
    public func setValues(_ dataId: Int, _ values: [Double]) -> Bool {
        guard let idx = indexById[dataId], let el = elementById[dataId], !values.isEmpty else { return false }
        // ECU values are float32 (4.95 arrives as 4.9500003). Round non-integers to 6 significant
        // digits — below float32 precision — the way PCLink's saved files show them. Integers untouched.
        func clean(_ v: Double) -> Double {
            guard v.isFinite, v != 0, v != v.rounded() else { return v }
            let f = pow(10, Double(5 - Int(floor(log10(abs(v))))))
            return (v * f).rounded() / f
        }
        if parameters[idx].scalar != nil {
            let v = clean(values[0])
            el.attribute(forName: "Value")?.stringValue = fmtRaw(v, decimals: nil)
            parameters[idx].scalar = v
        } else {
            let rowEls = el.children?.compactMap { $0 as? XMLElement }.filter { ($0.name ?? "").hasPrefix("Row") } ?? []
            var k = 0
            for (r, rowEl) in rowEls.enumerated() where r < parameters[idx].rows.count {
                for c in 0..<parameters[idx].rows[r].count where k < values.count {
                    parameters[idx].rows[r][c] = clean(values[k]); k += 1
                }
                rowEl.attribute(forName: "Value")?.stringValue =
                    parameters[idx].rows[r].map { fmtRaw($0, decimals: nil) }.joined(separator: ",")
            }
        }
        isDirty = true
        return true
    }

    /// Set a <Memory> field such as "Memo" or "SerialNumber".
    public func setMemory(_ field: String, _ value: String) {
        guard let mem = document.rootElement()?.elements(forName: "Memory").first,
              let el = mem.elements(forName: field).first else { return }
        el.attribute(forName: "Value")?.stringValue = value
        switch field {
        case "Memo": memory.memo = value
        case "SerialNumber": memory.serialNumber = value
        case "Firmware": memory.firmware = value
        default: break
        }
    }

    /// The current XML (for inspection / export).
    public func xmlData() -> Data {
        document.xmlData(options: [.nodeCompactEmptyElement])
    }

    /// Re-encrypt the current DOM into a tune file's bytes.
    public func encryptedData() -> Data {
        TuneCrypt.encrypt(xmlData())
    }

    public func save(to url: URL) throws {
        try encryptedData().write(to: url)
        isDirty = false
    }
}
