import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var phone: PhoneServer
    @EnvironmentObject var ecu: EcuManager

    @StateObject private var copilot = CopilotStore()
    @StateObject private var worksheet = AppModel()
    @SceneStorage("lessonID") private var lessonID = Course.lessons[0].id
    @AppStorage("courseCompleted.v1") private var passed = ""

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    destination("Tune workspace", "slider.horizontal.3", !model.showLearn && !model.showLive && !model.showCopilot) {
                        model.showLearn = false
                        model.showLive = false
                        model.showCopilot = false
                        model.selectedId = nil
                    }
                    destination("Copilot", "sparkles", model.showCopilot && !model.showLearn) {
                        model.showLearn = false
                        model.showLive = false
                        model.showCopilot = true
                    }
                    destination("Live data & logs", "waveform.path.ecg", model.showLive && !model.showLearn && !model.showCopilot) {
                        model.showLearn = false
                        model.showCopilot = false
                        model.showLive = true
                    }
                    destination("Learn", "book", model.showLearn) { model.showLearn = true }
                }
                .padding(10)
                Divider()
                if model.showLearn { CourseOutline(selection: $lessonID, passed: passed) }
                else { Sidebar() }
            }
            .navigationSplitViewColumnWidth(min: 252, ideal: 288, max: 420)
        } detail: {
            Group {
                if model.showLearn { CourseReader(selection: $lessonID, passed: $passed, worksheet: worksheet) }
                else if model.showCopilot { CopilotView(store: copilot) }
                else if model.showLive { LiveView() }
                else if model.tune == nil { Welcome() }
                else if let id = model.selectedId, model.tune?.parameter(id) != nil { ParameterPage(id: id).id(id) }
                else { Overview() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.fileName.isEmpty ? "OpenLink Tuner" : model.fileName)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) { EcuStatusButton() }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canUndo).help("Undo (⌘Z)")
                Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!model.canRedo).help("Redo (⇧⌘Z)")
                Button { model.openPanel() } label: { Label("Open", systemImage: "folder") }.help("Open tune (⌘O)")
                Button { model.compare == nil ? model.openComparePanel() : model.closeCompare() } label: {
                    Label(model.compare == nil ? "Compare" : "Stop comparing",
                          systemImage: model.compare == nil ? "square.split.2x1" : "xmark.square")
                }
                .disabled(model.tune == nil).help(model.compare == nil ? "Compare with another tune (⇧⌘O)" : "Close the comparison")
                Menu {
                    Button("For AI (Markdown)…") { model.exportMarkdown() }
                    Button("Copy whole tune for AI") { model.copyTuneForAI() }
                    Button("JSON…") { model.exportJSON() }
                    Button("Decrypted XML…") { model.exportXML() }
                    if model.compare != nil { Divider(); Button("Comparison report…") { model.exportComparison() } }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(model.tune == nil).help("Export decrypted / AI-readable")
                Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .disabled(model.tune == nil || !(model.dirty || model.isUnsavedECURead)).help("Save (⌘S)")
            }
        }
        .overlay { if ecu.reading { ReadingPanel() } }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .onChange(of: model.fileName) { _, _ in phone.broadcastState() }
        .alert("Problem", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func destination(_ title: String, _ icon: String, _ active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: active ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(active ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var subtitle: String {
        var s: [String] = []
        if model.dirty { s.append("edited — \(model.modifiedIds.count) parameter\(model.modifiedIds.count == 1 ? "" : "s") changed") }
        if model.compare != nil { s.append("comparing with \(model.compareName)") }
        return s.joined(separator: " · ")
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @State private var browsing = false
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let tune = model.tune {
            VStack(spacing: 0) {
                ecuHeader(tune)
                Button(browsing ? "Hide parameter browser" : "Browse all parameters") { browsing.toggle() }
                    .padding(.vertical, 6)
                if browsing || !model.search.isEmpty || model.filter != .all {
                filterBar
                List(selection: $model.selectedId) {
                    if model.filter == .all && model.search.isEmpty && !model.mainTables.isEmpty {
                        Section("Main tables") {
                            ForEach(model.mainTables, id: \.self) { id in
                                if let p = tune.parameter(id) { ParamRow(p: p, icon: "star.fill", iconColor: .yellow).tag(id) }
                            }
                        }
                    }
                    let groups = model.groups
                    if groups.isEmpty {
                        Text(emptyText).foregroundStyle(.secondary).font(.callout)
                    }
                    ForEach(groups) { g in
                        GroupSection(group: g, expanded: !model.search.isEmpty || model.filter != .all)
                    }
                }
                .listStyle(.sidebar)
                } else {
                    List(selection: $model.selectedId) {
                        Section("Main tables") {
                            ForEach(model.mainTables.prefix(8), id: \.self) { id in
                                if let p = tune.parameter(id) { ParamRow(p: p).tag(id) }
                            }
                        }
                    }.listStyle(.sidebar)
                }
            }
            .searchable(text: $model.search, placement: .sidebar, prompt: "Search parameters")
        } else {
            Spacer()
        }
    }

    private var emptyText: String {
        switch model.filter {
        case .modified: return "Nothing edited yet."
        case .diffs: return model.compare == nil ? "Open a tune to compare with (⇧⌘O)." : "No differences."
        case .all: return "No matches."
        }
    }

    private func ecuHeader(_ t: TuneFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Link ID \(t.memory.linkID)").font(.headline)
                Text("fw \(t.memory.firmware) · serial \(t.memory.serialNumber)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var filterBar: some View {
        VStack(spacing: 6) {
            Picker("", selection: $model.filter) {
                Text("All").tag(SidebarFilter.all)
                Text("Modified \(model.modifiedIds.count)").tag(SidebarFilter.modified)
                Text("Diffs \(model.diffs.count)").tag(SidebarFilter.diffs)
            }
            .pickerStyle(.segmented).labelsHidden()
            Toggle("Hide runtime (read-only) values", isOn: $model.hideReadOnly)
                .toggleStyle(.checkbox).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        .controlSize(.small)
    }
}

struct GroupSection: View {
    @EnvironmentObject var model: AppModel
    let group: TreeGroup
    @State private var isOpen: Bool
    init(group: TreeGroup, expanded: Bool) { self.group = group; _isOpen = State(initialValue: expanded) }

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            if isOpen { ForEach(group.params) { p in ParamRow(p: p).tag(p.dataId) } }
        } label: {
            HStack {
                Label(group.name, systemImage: "folder")
                Spacer()
                let mods = group.params.filter { model.modifiedIds.contains($0.dataId) }.count
                let difs = group.params.filter { model.diffs[$0.dataId] != nil }.count
                if mods > 0 { Badge(text: "\(mods)", color: .orange) }
                if difs > 0 && model.compare != nil { Badge(text: "\(difs)", color: .purple) }
                Text("\(group.params.count)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .onChange(of: model.search.isEmpty && model.filter == .all) { _, collapsed in isOpen = !collapsed }
    }
}

struct Badge: View {
    let text: String; let color: Color
    var body: some View {
        Text(text).font(.caption2.bold()).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color, in: Capsule())
    }
}

struct ParamRow: View {
    @EnvironmentObject var model: AppModel
    let p: TuneFile.Parameter
    var icon: String? = nil
    var iconColor: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon ?? (p.isTable ? "tablecells" : "slider.horizontal.3"))
                .foregroundStyle(iconColor ?? (p.isTable ? .orange : .secondary))
                .frame(width: 16)
            Text(model.displayName(p)).lineLimit(2).help(model.displayName(p))
                .foregroundStyle(p.readOnly ? .secondary : .primary)
            Spacer(minLength: 4)
            if model.modifiedIds.contains(p.dataId) { Circle().fill(.orange).frame(width: 7, height: 7).help("Edited") }
            if model.compare != nil, model.diffs[p.dataId] != nil { Circle().fill(.purple).frame(width: 7, height: 7).help("Differs from compared tune") }
            if model.unreadIds.contains(p.dataId) { Image(systemName: "questionmark.circle").foregroundStyle(.gray).help("Couldn't be read from the ECU") }
            if model.scaleCheckIds.contains(p.dataId) { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Scaling is tune-specific — check against PCLink") }
            if let s = p.scalar {
                Text(TuneExport.num(s, dp: model.decimals(p.dataId)))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            } else if p.isTable {
                Text("\(p.rowCount)×\(p.colCount)").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Pages

struct Welcome: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ecu: EcuManager
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 54)).foregroundStyle(.tint)
            Text("Tune workspace").font(.largeTitle.bold())
            Text(ecu.connected ? "ECU connected — read its tune, or open a tune file."
                               : "Open a tune file to explore its settings and tables. You can work offline.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Tune…") { model.openPanel() }.controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("Read Tune from ECU") { ecu.readTune(into: .open) }
                    .controlSize(.large).disabled(!ecu.connected || ecu.reading)
                Button("Start learning") { model.showLearn = true }.controlSize(.large)
            }
            Label(ecu.connected ? "Link cable connected" : "No ECU cable detected",
                  systemImage: ecu.connected ? "cable.connector" : "cable.connector.slash")
                .font(.callout).foregroundStyle(ecu.connected ? Color.green : Color.secondary)
        }
    }
}

/// Toolbar button showing the cable state, with the ECU actions.
struct EcuStatusButton: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ecu: EcuManager
    var body: some View {
        Menu {
            Button("Read Tune from ECU") { ecu.readTune(into: .open) }.disabled(!ecu.connected || ecu.reading)
            Button("Compare Open Tune with ECU") { ecu.readTune(into: .compare) }
                .disabled(!ecu.connected || ecu.reading || model.tune == nil)
            Divider()
            Button("Import ECU layouts from PCLink installer…") { ecu.importLayouts() }
            Divider()
            Toggle("Read tune automatically when no tune is open", isOn: $ecu.autoRead)
            Toggle("Start live data when ECU connects", isOn: $ecu.autoLive)
        } label: {
            Label(ecu.connected ? "ECU" : "No ECU",
                  systemImage: ecu.connected ? "cable.connector" : "cable.connector.slash")
                .foregroundStyle(ecu.connected ? Color.green : Color.secondary)
        }
        .help(ecu.connected ? "ECU connected" : "No Link ECU cable detected")
    }
}

/// Progress while the tune is read off the ECU.
struct ReadingPanel: View {
    @EnvironmentObject var ecu: EcuManager
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Label("Reading tune from the ECU", systemImage: "arrow.down.doc").font(.title3.bold())
                ProgressView(value: ecu.progress)
                Text(ecu.step).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Text("Read-only — nothing is written to the ECU.").font(.caption).foregroundStyle(.tertiary)
                HStack { Spacer(); Button("Cancel") { ecu.cancel() }.keyboardShortcut(.cancelAction) }
            }
            .padding(20)
            .frame(width: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 20)
        }
    }
}

struct Overview: View {
    @EnvironmentObject var model: AppModel
    private let cols = [GridItem(.adaptive(minimum: 210), spacing: 10)]

    var body: some View {
        if let t = model.tune {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text((model.fileName as NSString).deletingPathExtension).font(.largeTitle.bold())
                    if let sum = model.ecuReadSummary {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "arrow.down.doc.fill").font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.isUnsavedECURead ? "Read from your ECU — not saved yet" : "Read from your ECU").font(.headline)
                                Text(sum).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.isUnsavedECURead { Button("Save as .pclx…") { model.saveAs() } }
                        }
                        .padding(12)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    HStack(spacing: 10) {
                        Stat(title: "ECU", value: "Link ID \(t.memory.linkID)", sub: "firmware \(t.memory.firmware)")
                        Stat(title: "Settings", value: "\(t.parameters.filter { !$0.readOnly }.count)",
                             sub: "\(t.parameters.filter { $0.isTable && !$0.readOnly }.count) tables")
                        Stat(title: "Edited", value: "\(model.modifiedIds.count)", sub: model.dirty ? "unsaved" : "saved", tint: model.modifiedIds.isEmpty ? nil : .orange)
                        Stat(title: "Differences", value: model.compare == nil ? "—" : "\(model.diffs.count)",
                             sub: model.compare == nil ? "no comparison" : model.compareName, tint: model.compare == nil ? nil : .purple)
                    }

                    if !model.mainTables.isEmpty {
                        Text("Main tables").font(.title3.bold())
                        LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
                            ForEach(model.mainTables, id: \.self) { id in
                                Button { model.selectedId = id } label: { TableCard(id: id) }.buttonStyle(.plain)
                            }
                        }
                    }

                    compareSection

                    Text("Export").font(.title3.bold())
                    HStack {
                        Button { model.exportMarkdown() } label: { Label("Export for AI (Markdown)", systemImage: "doc.text") }
                        Button { model.copyTuneForAI() } label: { Label("Copy for AI", systemImage: "doc.on.clipboard") }
                        Button { model.exportJSON() } label: { Label("JSON", systemImage: "curlybraces") }
                        Button { model.exportXML() } label: { Label("Decrypted XML", systemImage: "chevron.left.forwardslash.chevron.right") }
                    }
                    Text("The AI export lists every setting by name with its units and every table with its RPM / load axes, so you can paste it into ChatGPT, Claude, etc. and ask about your tune.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder private var compareSection: some View {
        Text("Compare").font(.title3.bold())
        if model.compare == nil {
            HStack {
                Text("Open a second tune to see every setting and table cell that differs.").foregroundStyle(.secondary)
                Button("Compare With…") { model.openComparePanel() }
            }
        } else {
            let items = model.diffs.values.sorted {
                (model.category($0.dataId), model.name($0.dataId)) < (model.category($1.dataId), model.name($1.dataId))
            }
            HStack {
                Text("\(items.count) parameters differ from **\(model.compareName)**")
                Spacer()
                Button("Show only differences") { model.filter = .diffs }
                Button("Report…") { model.exportComparison() }
                Button("Close") { model.closeCompare() }
            }
            VStack(spacing: 0) {
                ForEach(items.prefix(60)) { it in
                    Button { model.selectedId = it.dataId } label: {
                        HStack {
                            Text(model.name(it.dataId)).lineLimit(1)
                            Text(model.category(it.dataId)).foregroundStyle(.secondary).font(.caption)
                            Spacer()
                            Text(diffText(it)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if items.count > 60 {
                    Text("…and \(items.count - 60) more — use the Diffs filter in the sidebar").font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func diffText(_ it: TuneDiff.Item) -> String {
        let dp = model.decimals(it.dataId)
        switch it.kind {
        case .scalar: return "\(it.a.map { TuneExport.num($0, dp: dp) } ?? "—") → \(it.b.map { TuneExport.num($0, dp: dp) } ?? "—")"
        case .table: return "\(it.changedCells)/\(it.totalCells) cells, max Δ \(TuneExport.num(it.maxAbsDelta, dp: dp))"
        case .onlyInA: return "only in this tune"
        case .onlyInB: return "only in compared"
        }
    }
}

struct Stat: View {
    let title: String, value: String, sub: String
    var tint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).foregroundStyle(tint ?? .primary)
            Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TableCard: View {
    @EnvironmentObject var model: AppModel
    let id: Int
    var body: some View {
        let ax = model.axes(id)
        HStack(spacing: 10) {
            Image(systemName: "tablecells.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name(id)).font(.headline).lineLimit(1)
                Text("\(ax.y.map { short($0.source) } ?? "?") × \(ax.x.map { short($0.source) } ?? "?")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.modifiedIds.contains(id) { Circle().fill(.orange).frame(width: 7, height: 7) }
            if model.diffs[id] != nil && model.compare != nil { Circle().fill(.purple).frame(width: 7, height: 7) }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
    private func short(_ s: String) -> String { s.replacingOccurrences(of: "Engine Speed", with: "RPM") }
}

// MARK: - Parameter page

struct ParameterPage: View {
    @EnvironmentObject var model: AppModel
    let id: Int

    var body: some View {
        if let p = model.tune?.parameter(id) {
            VStack(alignment: .leading, spacing: 12) {
                header(p)
                if p.scalar != nil {
                    ScrollView { ScalarEditor(id: id).frame(maxWidth: 560, alignment: .leading) }
                } else if !p.rows.isEmpty {
                    TableEditor(id: id)
                } else {
                    Text("This parameter has no editable value.").foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func header(_ p: TuneFile.Parameter) -> some View {
        let ax = model.axes(id)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name(id)).font(.title.bold())
                HStack(spacing: 8) {
                    Text(model.category(id))
                    if !model.unit(id).isEmpty { Text("· \(model.unit(id))") }
                    if p.isTable, let x = ax.x { Text("· X: \(x.title)") }
                    if p.isTable, let y = ax.y { Text("· Y: \(y.title)") }
                    Text("· D\(id)").font(.system(.body, design: .monospaced))
                }
                .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if p.readOnly { Badge(text: "READ-ONLY", color: .gray) }
                    if model.modifiedIds.contains(id) { Badge(text: "EDITED", color: .orange) }
                    if model.compare != nil && model.diffs[id] != nil { Badge(text: "DIFFERS", color: .purple) }
                    if model.unreadIds.contains(id) { Badge(text: "NOT READ FROM ECU — template value", color: .gray) }
                    if model.scaleCheckIds.contains(id) { Badge(text: "CHECK SCALING", color: .orange) }
                }
            }
            Spacer()
            HStack {
                if model.modifiedIds.contains(id) {
                    Button { model.revert(id) } label: { Label("Revert", systemImage: "arrow.counterclockwise") }
                }
                Button { model.copyParamForAI(id) } label: { Label("Copy for AI", systemImage: "doc.on.clipboard") }
            }
            .controlSize(.small)
        }
    }
}

struct ScalarEditor: View {
    @EnvironmentObject var model: AppModel
    let id: Int
    @State private var text = ""

    var body: some View {
        let p = model.tune?.parameter(id)
        let dp = model.decimals(id)
        let lim = model.limits(id)
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("value", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .font(.title2.monospaced())
                            .frame(width: 170)
                            .onSubmit(commit)
                            .disabled(p?.readOnly == true)
                        Stepper("", onIncrement: { bump(1) }, onDecrement: { bump(-1) })
                            .labelsHidden().disabled(p?.readOnly == true)
                        Text(model.unit(id)).foregroundStyle(.secondary)
                        Button("Set", action: commit).keyboardShortcut(.defaultAction).disabled(p?.readOnly == true)
                    }
                    if lim.min != nil || lim.max != nil {
                        Text("Allowed range: \(lim.min.map { TuneExport.num($0) } ?? "–") … \(lim.max.map { TuneExport.num($0) } ?? "–")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            } label: { Text("Value") }

            if model.modifiedIds.contains(id), let o = model.original(id)?.scalar {
                HStack {
                    Text("Original value: **\(TuneExport.num(o, dp: dp))**")
                    Button("Revert") { model.revert(id) }
                }
            }
            if let b = model.compared(id)?.scalar {
                HStack {
                    Text("In \(model.compareName): **\(TuneExport.num(b, dp: dp))**")
                    if b != p?.scalar {
                        Image(systemName: "circle.fill").foregroundStyle(.purple).font(.caption2)
                        Button("Use this value") { model.takeFromCompare(id) }
                    }
                }
            }
            Text("Option and mode settings are stored as numeric codes (0, 1, 2…), the same as PCLink stores them.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .onAppear(perform: sync)
        .onChange(of: model.revision) { _, _ in sync() }
    }

    private func sync() {
        if let v = model.tune?.parameter(id)?.scalar { text = TuneExport.num(v, dp: model.decimals(id)) }
    }
    private func commit() {
        if let v = Double(text.trimmingCharacters(in: .whitespaces)) { model.apply(id, [(.scalar, v)]) }
        sync()
    }
    private func bump(_ dir: Double) {
        let cur = model.tune?.parameter(id)?.scalar ?? 0
        model.apply(id, [(.scalar, cur + dir * model.step(id))])
    }
}
