import Foundation

// MARK: - CSV logs

struct LogTable {
    let columns: [String]          // without the time column
    let time: [Double]
    let data: [[Double?]]          // [column][row]

    init(csv: String) {
        var lines = csv.split(whereSeparator: \.isNewline).map(String.init)
        let header = lines.isEmpty ? [] : LogTable.split(lines.removeFirst())
        columns = Array(header.dropFirst())
        var t: [Double] = []
        var cols = Array(repeating: [Double?](), count: max(0, header.count - 1))
        for (i, l) in lines.enumerated() {
            let f = LogTable.split(l)
            guard !f.isEmpty else { continue }
            t.append(Double(f[0]) ?? Double(i))
            for c in 0..<cols.count { cols[c].append(c + 1 < f.count ? Double(f[c + 1]) : nil) }
        }
        time = t; data = cols
    }

    static func split(_ line: String) -> [String] {
        var out: [String] = [], cur = "", q = false
        for ch in line {
            if ch == "\"" { q.toggle() } else if ch == "," && !q { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }
}
