import Foundation

/// One axis of a table: its breakpoint values plus what input drives it.
public struct TableAxis {
    public let values: [Double]      // all stored breakpoints
    public let active: Int           // breakpoints actually in use
    public let source: String        // e.g. "Engine Speed"
    public let unit: String          // e.g. "RPM"
    public let resolved: Bool        // the input driving this axis is configured

    public var activeValues: [Double] { Array(values.prefix(active)) }
    public var title: String { unit.isEmpty ? source : "\(source) (\(unit))" }
}

public enum TuneAxes {
    /// Unit to show for a catalog entry: its own unit, else a default for its value type.
    public static func unit(_ e: Catalog.Entry?) -> String {
        guard let e else { return "" }
        if !e.unit.isEmpty { return e.unit }
        switch e.vt {
        case "Temperature": return "°C"
        case "Pressure": return "kPa"
        case "Distance": return "m"
        case "Speed": return "km/h"
        case "Voltage": return "V"
        case "Time": return "ms"
        case "Angle": return "°"
        default: return ""
        }
    }

    /// Strip internal suffixes from a runtime name ("… RTV" → "…").
    public static func cleanName(_ s: String) -> String {
        var n = s
        for suf in [" RTV", " RTS"] where n.hasSuffix(suf) { n = String(n.dropLast(suf.count)) }
        return n
    }

    /// Link tables keep a fixed number of breakpoints; unused ones trail off
    /// (repeat or reverse direction). Count the leading run that keeps going
    /// one way. Falls back to the full length if that run is too short.
    public static func activeCount(_ v: [Double]) -> Int {
        guard v.count > 2 else { return v.count }
        var dir = 0.0
        for i in 1..<v.count {
            let d = v[i] - v[i - 1]
            if dir == 0 {
                if d == 0 { return v.count }        // flat from the start: unconfigured, show all
                dir = d > 0 ? 1 : -1
            } else if d * dir <= 0 {
                return i >= 2 ? i : v.count
            }
        }
        return v.count
    }

    /// The X (columns) and Y (rows) axes for a table, if the catalog links them.
    public static func axes(for tableId: Int, in tune: TuneFile, catalog: Catalog?) -> (x: TableAxis?, y: TableAxis?) {
        guard let e = catalog?.byId[tableId] else { return (nil, nil) }
        func make(_ labelsId: Int?, _ sourceParam: Int?, fallback: String) -> TableAxis? {
            guard let labelsId, let lp = tune.parameter(labelsId), let vals = lp.rows.first else { return nil }
            var source = fallback, unit = "", resolved = false
            if let sp = sourceParam, let srcVal = tune.parameter(sp)?.scalar, srcVal > 0 {
                let srcId = Int(srcVal)
                if let se = catalog?.byId[srcId] {
                    source = cleanName(se.name); unit = TuneAxes.unit(se); resolved = true
                }
            }
            return TableAxis(values: vals, active: activeCount(vals), source: source, unit: unit, resolved: resolved)
        }
        return (make(e.xl, e.xp, fallback: "X axis"), make(e.yl, e.yp, fallback: "Y axis"))
    }
}
