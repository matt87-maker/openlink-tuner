import Foundation

// MARK: - CSV logs

/// A data log as columns of numbers. Reads this app's recordings and logs exported from PCLink or
/// other tools: comma, semicolon or tab separated, with or without lines of metadata above the
/// header, time in seconds or milliseconds.
struct LogTable {
    let columns: [String]          // without the time column
    let time: [Double]             // seconds
    let data: [[Double?]]          // [column][row]

    init(columns: [String], time: [Double], data: [[Double?]]) {
        self.columns = columns; self.time = time; self.data = data
    }

    init(csv: String) {
        var lines = csv.split(whereSeparator: \.isNewline).map(String.init)
        let sep = LogTable.separator(lines.prefix(40))
        // The header is the last non-numeric line before the first row of numbers.
        var headerIndex = 0
        for (i, l) in lines.prefix(200).enumerated() {
            let f = LogTable.split(l, sep)
            if f.count >= 2, LogTable.number(f[0]) != nil, f.dropFirst().contains(where: { LogTable.number($0) != nil }) {
                headerIndex = max(0, i - 1); break
            }
        }
        if headerIndex > 0 { lines.removeFirst(headerIndex) }
        let header = lines.isEmpty ? [] : LogTable.split(lines.removeFirst(), sep)
        columns = Array(header.dropFirst())
        let first = (header.first ?? "").lowercased()
        let scale = first.contains("(ms)") || first.contains("[ms]") || first.hasSuffix(" ms") || first == "ms" ? 0.001 : 1
        var t: [Double] = []
        var cols = Array(repeating: [Double?](), count: max(0, header.count - 1))
        for (i, l) in lines.enumerated() {
            let f = LogTable.split(l, sep)
            guard !f.isEmpty, !(f.count == 1 && f[0].isEmpty) else { continue }
            guard let tv = LogTable.number(f[0]) ?? (f.count > 1 ? Double(i) : nil) else { continue }
            t.append(tv * scale)
            for c in 0..<cols.count { cols[c].append(c + 1 < f.count ? LogTable.number(f[c + 1]) : nil) }
        }
        time = t; data = cols
    }

    static func number(_ s: String) -> Double? {
        if let v = Double(s) { return v }
        let t = s.trimmingCharacters(in: .whitespaces)
        if let v = Double(t) { return v }
        if t.contains(","), !t.contains("."), let v = Double(t.replacingOccurrences(of: ",", with: ".")) { return v }
        return nil
    }

    static func separator<S: Sequence>(_ lines: S) -> Character where S.Element == String {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        for l in lines { for ch in l where counts[ch] != nil { counts[ch]! += 1 } }
        return counts.max { $0.value < $1.value }.flatMap { $0.value > 0 ? $0.key : nil } ?? ","
    }

    static func split(_ line: String, _ sep: Character) -> [String] {
        var out: [String] = [], cur = "", q = false
        for ch in line {
            if ch == "\"" { q.toggle() } else if ch == sep && !q { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// Back-compat for callers that split this app's own comma-separated lines.
    static func split(_ line: String) -> [String] { split(line, ",") }
}
