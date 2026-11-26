import Foundation

/// A virtual engine for testing the copilot's log analysis without a car.
///
/// The tune's fuel table is treated as the ECU's guess of volumetric efficiency. The "real" engine
/// needs a different amount (`error(rpm, mgp)`), so measured lambda drifts away from target exactly
/// as it would on a car with a wrong fuel table. The simulation also has:
///  - a lambda sensor with RPM-dependent transport delay, lag and noise
///  - closed-loop lambda trim at light load, which hides part of the error
///  - acceleration enrichment on throttle steps (rich spikes), overrun fuel cut (lean spikes)
///  - a cold start with warm-up enrichment
///  - knock in a known region when ignition timing there is above a limit
struct EngineSim {
    struct Options {
        var rate = 20.0                       // samples per second
        var closedLoop = true
        var logTargetChannel = true
        var knockRegion: (rpm: ClosedRange<Double>, mgp: ClosedRange<Double>)? = (4000...5000, 45...75)
        var seed: UInt64 = 42
        var sensorNoise = 0.004
    }

    let fuelID: Int, fx: TableAxis, fy: TableAxis
    let ignID: Int?, ix: TableAxis?, iy: TableAxis?
    let target: (x: TableAxis?, y: TableAxis?, p: TuneFile.Parameter)?
    let original: TuneFile.Parameter
    var options = Options()

    init?(tune: TuneFile, catalog: Catalog?) {
        let t = LogAnalysis.tables(tune, catalog)
        guard let f = t.fuel.first, let p = tune.parameter(f.id) else { return nil }
        fuelID = f.id; fx = f.x; fy = f.y; original = p
        ignID = t.ign.first?.id; ix = t.ign.first?.x; iy = t.ign.first?.y
        target = t.target
    }

    /// How far the real engine's fuel need is from the original table: smooth, about ±10 %.
    static func error(rpm: Double, mgp: Double) -> Double {
        1 + 0.07 * sin(rpm / 1300) * cos(mgp / 45) + 0.03 * (rpm - 3500) / 3500 - 0.02 * max(0, mgp) / 70
    }

    /// True fuel requirement at a cell of the fuel table, in table units.
    func truth(row r: Int, col c: Int) -> Double {
        original.rows[r][c] * EngineSim.error(rpm: rpmAt(c), mgp: mgpAt(r))
    }
    func rpmAt(_ c: Int) -> Double { axisValue(fx, c, kind: "rpm") }
    func mgpAt(_ r: Int) -> Double { axisValue(fy, r, kind: "mgp") }
    private func axisValue(_ a: TableAxis, _ i: Int, kind: String) -> Double {
        let s = (a.source + a.unit).lowercased()
        let v = a.values[i]
        if kind == "mgp" && (s.contains("map") || s.contains("absolute")) && !s.contains("gauge") { return v - 101.3 }
        return v
    }
    /// Converts engine state to the value used on a table axis.
    private func axisInput(_ a: TableAxis, rpm: Double, mgp: Double, tps: Double) -> Double {
        let s = (a.source + a.unit).lowercased()
        if s.contains("gauge") || s.contains("mgp") { return mgp }
        if s.contains("speed") || s.contains("rpm") { return rpm }
        if s.contains("map") || s.contains("absolute") || s.contains("kpa") { return mgp + 101.3 }
        if s.contains("throttle") || s.contains("tp") { return tps }
        return rpm
    }

    // A deterministic random generator so runs repeat exactly.
    struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
        mutating func gauss() -> Double { let u = max(next(), 1e-12), v = next(); return sqrt(-2 * log(u)) * cos(2 * .pi * v) } }

    /// The drive: idle, a grid of steady holds across RPM and load, WOT pulls, decels. Returns (rpm, mgp, tps) targets per sample.
    func cycle(maxBoost: Double) -> [(rpm: Double, mgp: Double, tps: Double)] {
        var out: [(Double, Double, Double)] = []
        let dt = 1 / options.rate
        var rpm = 900.0, mgp = -65.0
        func hold(_ r: Double, _ m: Double, _ seconds: Double, ramp: Double = 1.0) {
            let steps = Int(seconds / dt)
            let r0 = rpm, m0 = mgp
            for k in 0..<steps {
                let a = min(1, Double(k) * dt / ramp)
                rpm = r0 + (r - r0) * a; mgp = m0 + (m - m0) * a
                out.append((rpm, mgp, tpsFor(mgp)))
            }
        }
        hold(900, -65, 140, ramp: 0.1)                       // cold start and warm-up at idle
        let rpms = fx.activeValues.map { axisValue(fx, fx.activeValues.firstIndex(of: $0)!, kind: "rpm") }.filter { $0 >= 900 && $0 <= 6800 }
        let loads = fy.activeValues.indices.map { mgpAt($0) }.filter { $0 >= -75 && $0 <= maxBoost }
        for (i, r) in rpms.enumerated() {
            let order = i % 2 == 0 ? loads : loads.reversed()
            for m in order {
                // Sit between breakpoints too, so interpolation is exercised.
                hold(r, m, 2.5)
                hold(r + 0.3 * ((rpms.indices.contains(i + 1) ? rpms[i + 1] : r) - r), m, 1.5)
            }
            hold(r, -70, 1.0, ramp: 0.2)                      // overrun between rows
        }
        for _ in 0..<3 {                                      // WOT pulls with boost
            hold(2500, 0, 2)
            let steps = Int(3.5 / dt)
            for k in 0..<steps {
                rpm = 2500 + 4200 * Double(k) / Double(steps)
                mgp = min(maxBoost, -10 + Double(k) * dt * 45)
                out.append((rpm, mgp, 100))
            }
            hold(2000, -70, 3, ramp: 1.5)                     // decel, fuel cut
        }
        return out
    }
    private func tpsFor(_ mgp: Double) -> Double { max(0, min(100, (mgp + 80) / 1.5)) }

    /// Runs the engine on `tune` and returns a PCLink-style log.
    func run(tune: TuneFile, catalog: Catalog?) -> LogTable {
        var rng = RNG(s: options.seed)
        let table = tune.parameter(fuelID)!
        let ign = ignID.flatMap { tune.parameter($0) }
        let maxBoost = min(70, fy.activeValues.indices.map { mgpAt($0) }.max() ?? 0)
        let drive = cycle(maxBoost: maxBoost)
        let dt = 1 / options.rate
        let n = drive.count
        var cols: [String] = ["Engine Speed (RPM)", "MAP (kPa)", "MGP (kPa)", "Barometric Pressure (kPa)", "TP (Main) (%)",
                              "Lambda 1", "CLL Fuel Corr (%)", "ECT (°C)", "IAT (°C)", "Knock Count Cyl 1", "Knock Retard (°)",
                              "Inj Duty Cycle (%)", "Ignition Angle (°)"]
        if options.logTargetChannel { cols.insert("Lambda 1 Target", at: 6) }
        var data = Array(repeating: [Double?](), count: cols.count)
        var actual = [Double](repeating: 1, count: n)
        var trim = 0.0, ae = 0.0, knockCount = 0.0, retard = 0.0, sensor = 1.0
        var lastTps = drive.first?.tps ?? 0
        var ect = 40.0
        for i in 0..<n {
            let (rpm, mgp, tps) = drive[i]
            let t = Double(i) * dt
            ect = min(88, ect + dt * 0.4)
            // Acceleration enrichment on throttle steps.
            let dTps = (tps - lastTps) / dt; lastTps = tps
            if dTps > 20 { ae = min(0.25, ae + 0.15) }
            ae *= exp(-dt / 0.35)
            let warm = ect < 65 ? 1 + (65 - ect) / 100 : 1
            let tgt = target.flatMap { tt in LogAnalysis.interpolate(tt.p, x: tt.x, y: tt.y,
                       xv: tt.x.map { axisInput($0, rpm: rpm, mgp: mgp, tps: tps) }, yv: tt.y.map { axisInput($0, rpm: rpm, mgp: mgp, tps: tps) }) } ?? (mgp > 0 ? 0.82 : 1.0)
            let xv = axisInput(fx, rpm: rpm, mgp: mgp, tps: tps), yv = axisInput(fy, rpm: rpm, mgp: mgp, tps: tps)
            let tableVE = LogAnalysis.interpolate(table, x: fx, y: fy, xv: xv, yv: yv) ?? 1
            let origVE = LogAnalysis.interpolate(original, x: fx, y: fy, xv: xv, yv: yv) ?? 1
            let trueVE = origVE * EngineSim.error(rpm: rpm, mgp: mgp)
            let overrun = tps < 1 && rpm > 1500
            var lam = overrun ? 2.0 : tgt * trueVE / max(1e-6, tableVE * (1 + trim / 100) * (1 + ae) * warm)
            lam = max(0.6, min(2.0, lam))
            actual[i] = lam
            // Sensor: transport delay + first-order lag + noise.
            let delay = 0.04 + 320 / max(rpm, 500)
            let src = max(0, i - Int((delay / dt).rounded()))
            sensor += (actual[src] - sensor) * min(1, dt / 0.05)
            let measured = min(1.6, sensor + rng.gauss() * options.sensorNoise)
            // Closed loop at light load once warm.
            let clActive = options.closedLoop && ect > 70 && mgp < -10 && rpm < 4000 && !overrun && ae < 0.02
            if clActive { trim = max(-15, min(15, trim + (measured / tgt - 1) * 100 * dt * 1.5)) }
            else { trim *= exp(-dt / 0.5) }
            // Knock in the knock region if timing is above the limit there.
            var ignAngle: Double = 0
            if let ign, let ix, let iy {
                ignAngle = LogAnalysis.interpolate(ign, x: ix, y: iy, xv: axisInput(ix, rpm: rpm, mgp: mgp, tps: tps), yv: axisInput(iy, rpm: rpm, mgp: mgp, tps: tps)) ?? 0
            }
            if let k = options.knockRegion, k.rpm.contains(rpm), k.mgp.contains(mgp), rng.next() < 0.15 { knockCount += 1; retard = min(6, retard + 2) }
            retard = max(0, retard - dt * 3)
            let duty = min(100, rpm / 7000 * (mgp + 101.3) / 171 * 75 * tableVE / max(origVE, 1e-6))
            var row: [Double?] = [rpm, mgp + 101.3, mgp, 101.3, tps, measured]
            if options.logTargetChannel { row.append(tgt) }
            row += [clActive || abs(trim) > 0.05 ? trim : 0, ect, 25 + max(0, mgp) * 0.3, knockCount, retard, duty, ignAngle - retard]
            for c in 0..<cols.count { data[c].append(row[c]) }
            _ = t
        }
        return LogTable(columns: cols, time: (0..<n).map { Double($0) * dt }, data: data)
    }

    /// RMS and worst % difference between the tune's fuel table and the truth, over the given cells.
    func error(of tune: TuneFile, cells: Set<[Int]>) -> (rms: Double, worst: Double) {
        let p = tune.parameter(fuelID)!
        var sum = 0.0, worst = 0.0
        for k in cells {
            let e = (p.rows[k[0]][k[1]] / truth(row: k[0], col: k[1]) - 1) * 100
            sum += e * e; worst = max(worst, abs(e))
        }
        return (cells.isEmpty ? 0 : sqrt(sum / Double(cells.count)), worst)
    }

    static func csv(_ log: LogTable, separator: String = ",", timeHeader: String = "Time (s)", timeScale: Double = 1) -> String {
        var s = ([timeHeader] + log.columns).joined(separator: separator) + "\n"
        for i in log.time.indices {
            s += ([LogAnalysis.f(log.time[i] * timeScale)] + log.data.map { $0[i].map(LogAnalysis.f) ?? "" }).joined(separator: separator) + "\n"
        }
        return s
    }
}
