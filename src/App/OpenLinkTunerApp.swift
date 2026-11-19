import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct OpenLinkTunerApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var live = LiveEngine()
    @StateObject private var phone = PhoneServer()
    @StateObject private var ecu = EcuManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(live)
                .environmentObject(phone)
                .environmentObject(ecu)
                .frame(minWidth: 1120, minHeight: 700)
                .onAppear {
                    AppDelegate.shared = model
                    live.app = model
                    phone.app = model
                    phone.live = live
                    live.onFrame = { [weak phone] f in phone?.send(frame: f) }
                    live.onStateChange = { [weak phone] in phone?.broadcastState(); phone?.broadcastLogs() }
                    phone.start()
                    ecu.app = model
                    ecu.live = live
                    live.transportFactory = { [weak ecu] in
                        guard let ecu else { throw EcuTuneReader.ReadError.cancelled }
                        return try ecu.makeTransport()
                    }
                    ecu.start()
                    model.loadLaunchArg()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Tune…") { model.openPanel() }.keyboardShortcut("o")
                Button("Compare With…") { model.openComparePanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.tune == nil)
                if model.compare != nil {
                    Button("Close Comparison") { model.closeCompare() }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }.keyboardShortcut("s").disabled(model.tune == nil)
                Button("Save As…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.tune == nil)
                Divider()
                Menu("Export") {
                    Button("For AI (Markdown)…") { model.exportMarkdown() }.keyboardShortcut("e")
                    Button("JSON…") { model.exportJSON() }
                    Button("Decrypted XML…") { model.exportXML() }
                    Divider()
                    Button("Comparison Report…") { model.exportComparison() }.disabled(model.compare == nil)
                }
                .disabled(model.tune == nil)
                Button("Copy Whole Tune for AI") { model.copyTuneForAI() }.disabled(model.tune == nil)
            }
            CommandMenu("ECU") {
                Button("Read Tune from ECU") { ecu.readTune(into: .open) }
                    .keyboardShortcut("r").disabled(!ecu.connected || ecu.reading)
                Button("Compare Open Tune with ECU") { ecu.readTune(into: .compare) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(!ecu.connected || ecu.reading || model.tune == nil)
                Divider()
                Button("Import ECU Layouts from PCLink Installer…") { ecu.importLayouts() }
                Divider()
                Toggle("Read Tune Automatically When No Tune Is Open", isOn: $ecu.autoRead)
                Toggle("Start Live Data When ECU Connects", isOn: $ecu.autoLive)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
                Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
            }
        }
    }
}

/// Lets Finder "Open With" / `open file.pclx` load a tune directly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppModel?
    func application(_ sender: NSApplication, open urls: [URL]) {
        if let u = urls.first { AppDelegate.shared?.load(u) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// A node in the category tree shown in the sidebar.
struct TreeGroup: Identifiable {
    let id: String
    let name: String
    var params: [TuneFile.Parameter]
}

struct CellRef: Hashable { var r: Int; var c: Int }

enum EditTarget: Hashable { case scalar, cell(Int, Int) }

struct EditRecord { let id: Int; let target: EditTarget; let old: Double; let new: Double }

enum SidebarFilter: String, CaseIterable, Identifiable {
    case all = "All", modified = "Modified", diffs = "Differences"
    var id: String { rawValue }
}

final class AppModel: ObservableObject {
    @Published var tune: TuneFile?
    @Published var fileName = ""
    @Published var error: String?
    @Published var search = ""
    @Published var dirty = false
    @Published var selectedId: Int? { didSet { if selectedId != nil { showLive = false } } }
    @Published var hideReadOnly = true
    @Published var filter: SidebarFilter = .all
    @Published var compare: TuneFile?
    @Published var compareName = ""
    @Published var diffs: [Int: TuneDiff.Item] = [:]
    @Published var modifiedIds: Set<Int> = []
    @Published var toast: String?
    @Published var revision = 0
    @Published var showLive = false
    @Published var unreadIds: Set<Int> = []          // settings the ECU read couldn't fetch
    @Published var scaleCheckIds: Set<Int> = []      // read as integers with tune-specific scaling
    @Published var ecuReadSummary: String?

    var fileURL: URL?
    private var baseline: [Int: TuneFile.Parameter] = [:]
    private var undoStack: [[EditRecord]] = []
    private var redoStack: [[EditRecord]] = []
    private(set) var mainTables: [Int] = []
    private var savedSinceLoad = false   // file on disk no longer matches the load-time baseline

    let catalog = Catalog.bundled()

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: files

    private func tunePanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pclx") ?? .data,
                                     UTType(filenameExtension: "pcl5") ?? .data]
        panel.allowsOtherFileTypes = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func openPanel() { if let u = tunePanel() { load(u) } }

    func load(_ url: URL) {
        do {
            let t = try TuneFile(fileURL: url)
            install(t, name: url.lastPathComponent, url: url)
            // remember this ECU model's layout (kept on this Mac) so its tune can be read over USB later
            if EcuTuneReader.learnLayout(from: url, linkId: t.memory.linkID) {
                flash("Learned the layout for Link ID \(t.memory.linkID) — its tune can now be read from the ECU")
            }
        } catch {
            self.error = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Show a tune read from the ECU. It isn't a file yet: Save asks where to keep it.
    func openFromECU(_ t: TuneFile, name: String, report: EcuTuneReader.Report) {
        install(t, name: name, url: nil)
        unreadIds = Set(report.notRead)
        scaleCheckIds = Set(report.scaleUncertain)
        ecuReadSummary = report.summary
        flash("Tune read from the ECU — Save to keep a .pclx backup")
    }

    private func install(_ t: TuneFile, name: String, url: URL?) {
        tune = t
        fileName = name
        fileURL = url
        dirty = false
        error = nil
        selectedId = nil
        unreadIds = []
        scaleCheckIds = []
        ecuReadSummary = nil
        baseline = Dictionary(uniqueKeysWithValues: t.parameters.map { ($0.dataId, $0) })
        modifiedIds = []
        savedSinceLoad = false
        undoStack = []; redoStack = []
        if !t.memory.linkID.isEmpty { EcuTuneReader.lastLinkId = t.memory.linkID }
        computeMainTables()
        recomputeDiffs()
        revision += 1
    }

    /// True when the open tune exists only in memory (read from the ECU, never saved).
    var isUnsavedECURead: Bool { tune != nil && fileURL == nil }

    func loadLaunchArg() {
        let files = CommandLine.arguments.dropFirst().filter { $0.hasSuffix(".pclx") || $0.hasSuffix(".pcl5") }
        if let a = files.first { load(URL(fileURLWithPath: a)) }
        if files.count > 1 { loadCompare(URL(fileURLWithPath: files[files.index(after: files.startIndex)])) }
    }

    func openComparePanel() { if let u = tunePanel() { loadCompare(u) } }

    func loadCompare(_ url: URL) {
        do { setCompare(try TuneFile(fileURL: url), name: url.lastPathComponent) }
        catch { self.error = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    func setCompare(_ t: TuneFile, name: String) {
        compare = t
        compareName = name
        recomputeDiffs()
        flash("Comparing with \(compareName): \(diffs.count) differences")
    }

    func closeCompare() {
        compare = nil; compareName = ""; diffs = [:]
        if filter == .diffs { filter = .all }
    }

    func recomputeDiffs() {
        guard let t = tune, let c = compare else { diffs = [:]; return }
        diffs = Dictionary(uniqueKeysWithValues: TuneDiff.compare(t, c).map { ($0.dataId, $0) })
    }

    func save() {
        guard let t = tune else { return }
        guard let url = fileURL else { return saveAs() }
        do { try t.save(to: url); markSaved(); flash("Saved \(url.lastPathComponent)") }
        catch { self.error = error.localizedDescription }
    }

    func saveAs() {
        guard let t = tune, let url = savePanel(suggested: fileName.isEmpty ? "tune.pclx" : fileName, ext: "pclx") else { return }
        do { try t.save(to: url); fileURL = url; fileName = url.lastPathComponent; markSaved(); flash("Saved \(url.lastPathComponent)") }
        catch { self.error = error.localizedDescription }
    }

    /// After saving, the saved file becomes the new "original" for Revert / edited markers.
    private func markSaved() {
        guard let t = tune else { return }
        baseline = Dictionary(uniqueKeysWithValues: t.parameters.map { ($0.dataId, $0) })
        modifiedIds = []
        savedSinceLoad = false
        dirty = false
        revision += 1
    }

    private func savePanel(suggested: String, ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: exports

    private var baseName: String { (fileName as NSString).deletingPathExtension }

    private func writeExport(_ data: Data, suggested: String, ext: String) {
        guard let url = savePanel(suggested: suggested, ext: ext) else { return }
        do {
            try data.write(to: url)
            flash("Exported \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { self.error = error.localizedDescription }
    }

    func exportMarkdown() {
        guard let t = tune else { return }
        writeExport(Data(TuneExport.markdown(t, catalog: catalog, title: baseName).utf8),
                    suggested: "\(baseName) (for AI).md", ext: "md")
    }
    func exportJSON() {
        guard let t = tune else { return }
        writeExport(TuneExport.json(t, catalog: catalog, title: baseName), suggested: "\(baseName).json", ext: "json")
    }
    func exportXML() {
        guard let t = tune else { return }
        writeExport(dirty ? t.xmlData() : t.originalPlaintext, suggested: "\(baseName) (decrypted).xml", ext: "xml")
    }
    func exportComparison() {
        guard let a = tune, let b = compare else { return }
        let md = TuneExport.comparisonMarkdown(a: a, b: b, nameA: fileName, nameB: compareName,
                                               catalog: catalog, items: Array(diffs.values))
        writeExport(Data(md.utf8), suggested: "\(baseName) vs \((compareName as NSString).deletingPathExtension).md", ext: "md")
    }
    func copyTuneForAI() {
        guard let t = tune else { return }
        copy(TuneExport.markdown(t, catalog: catalog, title: baseName))
        flash("Whole tune copied as Markdown — paste it into your AI chat")
    }
    func copyParamForAI(_ id: Int) {
        guard let t = tune, let p = t.parameter(id) else { return }
        var s = "From Link ECU tune \"\(baseName)\" (Link ID \(t.memory.linkID), fw \(t.memory.firmware)):\n\n"
        s += TuneExport.parameterMarkdown(p, tune: t, catalog: catalog)
        copy(s)
        flash("\(name(id)) copied for AI")
    }
    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func flash(_ msg: String) {
        toast = msg
        let current = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.toast == current { self?.toast = nil }
        }
    }

    // MARK: metadata

    func name(_ id: Int) -> String { catalog?.name(id) ?? "D\(id)" }
    func displayName(_ p: TuneFile.Parameter) -> String { name(p.dataId) }
    func category(_ id: Int) -> String { Catalog.prettyGroup(catalog?.topic(id) ?? "") }
    func unit(_ id: Int) -> String { TuneAxes.unit(catalog?.byId[id]) }
    func decimals(_ id: Int) -> Int? { catalog?.byId[id].flatMap { Int($0.dp) } }
    func limits(_ id: Int) -> (min: Double?, max: Double?) {
        let e = catalog?.byId[id]
        return (e.flatMap { Double($0.min) }, e.flatMap { Double($0.max) })
    }
    func axes(_ id: Int) -> (x: TableAxis?, y: TableAxis?) {
        guard let t = tune else { return (nil, nil) }
        return TuneAxes.axes(for: id, in: t, catalog: catalog)
    }
    func original(_ id: Int) -> TuneFile.Parameter? { baseline[id] }
    func compared(_ id: Int) -> TuneFile.Parameter? { compare?.parameter(id) }
    func step(_ id: Int) -> Double {
        if let d = decimals(id) { return pow(10, -Double(min(d, 3))) }
        return 1
    }

    private func computeMainTables() {
        guard let t = tune else { mainTables = []; return }
        func generic(_ n: String) -> Bool {
            n.range(of: #"^(G4 Table|GP Table|NV Table|Cal table) *\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        func rank(_ n: String) -> Int {
            let l = n.lowercased()
            if l.contains("fuel table") || l.contains("fueltable") { return 0 }
            if l.hasPrefix("ign") || l.contains("ignition table") { return 1 }
            if l.contains("lambda") { return 2 }
            return 3
        }
        mainTables = t.parameters.filter { p in
            guard !p.readOnly, p.rows.count >= 2, let e = catalog?.byId[p.dataId], e.xl != nil, e.yl != nil else { return false }
            let ax = TuneAxes.axes(for: p.dataId, in: t, catalog: catalog)
            let resolved = (ax.x?.resolved == true ? 1 : 0) + (ax.y?.resolved == true ? 1 : 0)
            return resolved == 2 || (resolved == 1 && !generic(name(p.dataId)))
        }
        .map(\.dataId)
        .sorted { a, b in
            let ra = rank(name(a)), rb = rank(name(b))
            return ra != rb ? ra < rb : name(a).localizedStandardCompare(name(b)) == .orderedAscending
        }
    }

    // MARK: editing

    private func rounded(_ v: Double, _ dp: Int?) -> Double {
        guard let dp, dp >= 0, dp < 8 else { return v }
        let f = pow(10, Double(dp)); return (v * f).rounded() / f
    }

    private func clamp(_ id: Int, _ v: Double) -> (Double, Bool) {
        let l = limits(id)
        if let mx = l.max, v > mx { return (mx, true) }
        if let mn = l.min, v < mn { return (mn, true) }
        return (v, false)
    }

    /// Apply a batch of changes to one parameter as a single undoable step.
    @discardableResult
    func apply(_ id: Int, _ changes: [(EditTarget, Double)], label: String? = nil) -> Int {
        guard let t = tune, let p = t.parameter(id) else { return 0 }
        if p.readOnly { flash("\(name(id)) is read-only"); return 0 }
        let dp = decimals(id)
        var recs: [EditRecord] = []
        var clamped = false
        for (target, v0) in changes {
            let (cv, didClamp) = clamp(id, v0)
            clamped = clamped || didClamp
            let v = rounded(cv, dp)
            switch target {
            case .scalar:
                let old = p.scalar ?? 0
                if old != v, t.setScalar(id, value: v, decimals: dp) { recs.append(EditRecord(id: id, target: target, old: old, new: v)) }
            case .cell(let r, let c):
                guard r < p.rows.count, c < p.rows[r].count else { continue }
                let old = p.rows[r][c]
                if old != v, t.setCell(id, row: r, col: c, value: v, decimals: dp) { recs.append(EditRecord(id: id, target: target, old: old, new: v)) }
            }
        }
        if clamped, let l = Optional(limits(id)) {
            flash("Clamped to the allowed range \(l.min.map { TuneExport.num($0) } ?? "–")…\(l.max.map { TuneExport.num($0) } ?? "–")")
        } else if let label, !recs.isEmpty { flash(label) }
        if !recs.isEmpty {
            undoStack.append(recs); redoStack = []
            didEdit([id])
        }
        return recs.count
    }

    private func write(_ recs: [EditRecord], useNew: Bool) {
        guard let t = tune else { return }
        for rec in (useNew ? recs : recs.reversed()) {
            let v = useNew ? rec.new : rec.old
            switch rec.target {
            case .scalar: t.setScalar(rec.id, value: v, decimals: decimals(rec.id))
            case .cell(let r, let c): t.setCell(rec.id, row: r, col: c, value: v, decimals: decimals(rec.id))
            }
        }
        didEdit(Set(recs.map(\.id)))
    }

    func undo() {
        guard let g = undoStack.popLast() else { return }
        write(g, useNew: false); redoStack.append(g)
        if let id = g.first?.id { selectedId = id }
        flash("Undo: \(g.count) value\(g.count == 1 ? "" : "s")")
    }
    func redo() {
        guard let g = redoStack.popLast() else { return }
        write(g, useNew: true); undoStack.append(g)
        if let id = g.first?.id { selectedId = id }
        flash("Redo: \(g.count) value\(g.count == 1 ? "" : "s")")
    }

    private func didEdit(_ ids: Set<Int>) {
        guard let t = tune else { return }
        for id in ids {
            guard let now = t.parameter(id), let was = baseline[id] else { continue }
            if now.scalar != was.scalar || now.rows != was.rows { modifiedIds.insert(id) } else { modifiedIds.remove(id) }
        }
        dirty = !modifiedIds.isEmpty || savedSinceLoad
        recomputeDiffs()
        revision += 1
    }

    func isCellModified(_ id: Int, _ r: Int, _ c: Int) -> Bool {
        guard modifiedIds.contains(id), let was = baseline[id], let now = tune?.parameter(id),
              r < was.rows.count, c < was.rows[r].count else { return false }
        return was.rows[r][c] != now.rows[r][c]
    }

    func revert(_ id: Int) {
        guard let was = baseline[id] else { return }
        if let v = was.scalar { apply(id, [(.scalar, v)], label: "Reverted \(name(id))"); return }
        var ch: [(EditTarget, Double)] = []
        for (r, row) in was.rows.enumerated() { for (c, v) in row.enumerated() { ch.append((.cell(r, c), v)) } }
        apply(id, ch, label: "Reverted \(name(id))")
    }

    func takeFromCompare(_ id: Int, cells: [CellRef]? = nil) {
        guard let b = compared(id) else { return }
        if let v = b.scalar { apply(id, [(.scalar, v)], label: "Copied value from \(compareName)"); return }
        var ch: [(EditTarget, Double)] = []
        for (r, row) in b.rows.enumerated() {
            for (c, v) in row.enumerated() where cells == nil || cells!.contains(CellRef(r: r, c: c)) {
                ch.append((.cell(r, c), v))
            }
        }
        apply(id, ch, label: "Copied \(ch.count) cells from \(compareName)")
    }

    // MARK: sidebar

    private func matches(_ p: TuneFile.Parameter, _ q: String) -> Bool {
        if q.isEmpty { return true }
        if let id = Int(q) { return p.dataId == id }
        if q.lowercased().hasPrefix("d"), let id = Int(q.dropFirst()) { return p.dataId == id }
        return name(p.dataId).localizedCaseInsensitiveContains(q)
    }

    private func passesFilter(_ p: TuneFile.Parameter) -> Bool {
        if hideReadOnly && p.readOnly && filter != .diffs { return false }
        switch filter {
        case .all: return true
        case .modified: return modifiedIds.contains(p.dataId)
        case .diffs: return diffs[p.dataId] != nil
        }
    }

    var groups: [TreeGroup] {
        guard let params = tune?.parameters else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces)
        var buckets: [String: [TuneFile.Parameter]] = [:]
        for p in params where passesFilter(p) && matches(p, q) {
            buckets[category(p.dataId), default: []].append(p)
        }
        return buckets.map { label, ps in
            TreeGroup(id: label, name: label,
                      params: ps.sorted { name($0.dataId).localizedStandardCompare(name($1.dataId)) == .orderedAscending })
        }
        .sorted { a, b in
            if a.name == "Other" { return false }
            if b.name == "Other" { return true }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
