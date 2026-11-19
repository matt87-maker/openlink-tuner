import Foundation

/// Differences between two tunes, parameter by parameter (matched on DataId).
public enum TuneDiff {
    public enum Kind: String { case scalar, table, onlyInA, onlyInB }

    public struct Item: Identifiable {
        public var id: Int { dataId }
        public let dataId: Int
        public let kind: Kind
        public let changedCells: Int
        public let totalCells: Int
        public let maxAbsDelta: Double
        public let a: Double?      // scalar value in A
        public let b: Double?      // scalar value in B
    }

    static func same(_ x: Double, _ y: Double) -> Bool { abs(x - y) < 1e-9 }

    /// Compare A against B. Read-only (runtime) parameters are skipped unless asked.
    public static func compare(_ a: TuneFile, _ b: TuneFile, includeReadOnly: Bool = false) -> [Item] {
        var out: [Item] = []
        for pa in a.parameters where includeReadOnly || !pa.readOnly {
            guard let pb = b.parameter(pa.dataId) else {
                out.append(Item(dataId: pa.dataId, kind: .onlyInA, changedCells: 0, totalCells: 0,
                                maxAbsDelta: 0, a: pa.scalar, b: nil))
                continue
            }
            if let sa = pa.scalar {
                let sb = pb.scalar
                if sb == nil || !same(sa, sb!) {
                    out.append(Item(dataId: pa.dataId, kind: .scalar, changedCells: 1, totalCells: 1,
                                    maxAbsDelta: sb.map { abs(sa - $0) } ?? 0, a: sa, b: sb))
                }
            } else if !pa.rows.isEmpty {
                var changed = 0, total = 0, maxd = 0.0
                for (r, row) in pa.rows.enumerated() {
                    for (c, v) in row.enumerated() {
                        total += 1
                        if r < pb.rows.count, c < pb.rows[r].count {
                            let w = pb.rows[r][c]
                            if !same(v, w) { changed += 1; maxd = max(maxd, abs(v - w)) }
                        } else { changed += 1 }
                    }
                }
                if changed > 0 {
                    out.append(Item(dataId: pa.dataId, kind: .table, changedCells: changed, totalCells: total,
                                    maxAbsDelta: maxd, a: nil, b: nil))
                }
            }
        }
        for pb in b.parameters where (includeReadOnly || !pb.readOnly) && a.parameter(pb.dataId) == nil {
            out.append(Item(dataId: pb.dataId, kind: .onlyInB, changedCells: 0, totalCells: 0,
                            maxAbsDelta: 0, a: nil, b: pb.scalar))
        }
        return out
    }

    /// True if one cell differs between the two tunes' copies of a table.
    public static func cellDiffers(_ pa: TuneFile.Parameter, _ pb: TuneFile.Parameter?, _ r: Int, _ c: Int) -> Bool {
        guard let pb, r < pb.rows.count, c < pb.rows[r].count,
              r < pa.rows.count, c < pa.rows[r].count else { return pb != nil }
        return !same(pa.rows[r][c], pb.rows[r][c])
    }
}
