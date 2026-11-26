import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Conversation state (lives as long as the window, so switching pages keeps the chat)

@MainActor
final class CopilotStore: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let role: String                 // "user" or "assistant"
        var text = ""                    // what the model wrote (assistant) or the question (user)
        var display = ""                 // markdown shown in the chat
        var plans: [CopilotPlan] = []
        var status: String?
        var error: String?
        var attachments: [String] = []
        var done = true
    }

    @Published var messages: [Message] = []
    @Published var draft = ""
    @Published var pending: [URL] = []             // attached, not sent yet
    @Published private(set) var logs: [URL] = []   // every log in this chat
    @Published private(set) var busy = false
    @Published private(set) var tick = 0           // bumps while a reply streams, for auto-scroll
    private var task: Task<Void, Never>?
    private var parsed: [URL: LogTable] = [:]

    static var defaultProvider: CopilotProvider {
        if CopilotKeychain.apiKey() != nil { return .openAI }
        let auth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenLink Tuner/ChatGPT Account/chatgpt-auth.json")
        return FileManager.default.fileExists(atPath: auth.path) ? .chatGPTPlan : .openAI
    }
    private var provider: CopilotProvider {
        CopilotProvider(rawValue: UserDefaults.standard.string(forKey: "copilot.provider") ?? "") ?? Self.defaultProvider
    }
    private var modelName: String { UserDefaults.standard.string(forKey: "copilot.model") ?? CopilotClient.defaultModel }

    // MARK: actions

    func attach(_ urls: [URL]) {
        for u in urls where u.pathExtension.lowercased() == "csv" && !pending.contains(u) && !logs.contains(u) { pending.append(u) }
    }

    func newChat() {
        stop()
        messages = []; logs = []; pending = []; draft = ""; parsed = [:]
    }

    func stop() { task?.cancel(); task = nil }

    func send(_ text: String? = nil, app: AppModel, live: LiveEngine) {
        let typed = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !typed.isEmpty || !pending.isEmpty else { return }
        var question = Message(role: "user", text: typed.isEmpty ? "Look at the attached log and tell me how the tune is running." : typed)
        question.attachments = pending.map(\.lastPathComponent)
        logs += pending; pending = []
        if text == nil || typed == draft.trimmingCharacters(in: .whitespacesAndNewlines) { draft = "" }
        messages.append(question)
        respond(app: app, live: live)
    }

    func regenerate(app: AppModel, live: LiveEngine) {
        guard !busy, messages.last?.role == "assistant" else { return }
        messages.removeLast()
        respond(app: app, live: live)
    }

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i]); tick += 1
    }

    private func respond(app: AppModel, live: LiveEngine) {
        var reply = Message(role: "assistant")
        reply.status = "Thinking…"; reply.done = false
        let id = reply.id
        let history = modelHistory(app: app)
        messages.append(reply)
        busy = true
        let provider = provider, modelName = modelName, logURLs = logs
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.update(id) { $0.done = true; $0.status = nil } }
            do {
                let tables = try await self.load(logURLs)
                let analysis = tables.isEmpty ? nil : LogAnalysis(logs: tables, tune: app.tune, catalog: app.catalog)
                let liveText = live.connected ? live.copilotTelemetry.summary(at: Date()) : nil
                let blocked = app.unreadIds.union(app.scaleCheckIds)
                var extra = Set<Int>()
                for round in 0..<3 {
                    let context = TuneContext.build(tune: app.tune, catalog: app.catalog, fileName: app.fileName, focusID: app.selectedId,
                                                    mainTables: app.mainTables, extraTables: extra, blocked: blocked,
                                                    logs: analysis, live: liveText)
                    let raw = try await CopilotClient.reply(provider: provider, model: modelName,
                                                            instructions: CopilotPrompt.instructions + "\n\n" + context,
                                                            messages: history) { [weak self] partial in
                        self?.update(id) { $0.display = CopilotReply.visible(partial); if !$0.display.isEmpty { $0.status = nil } }
                    }
                    try Task.checkCancellation()
                    let result = CopilotReply.parse(raw)
                    let wanted = Set(result.need).subtracting(extra).filter { app.tune?.parameter($0) != nil }
                    if !wanted.isEmpty, result.changes.isEmpty, round < 2 {
                        extra.formUnion(wanted)
                        let names = wanted.sorted().prefix(3).map { app.name($0) }.joined(separator: ", ")
                        self.update(id) { $0.display = ""; $0.status = "Reading \(names)…" }
                        continue
                    }
                    var plans: [CopilotPlan] = []
                    if let tune = app.tune {
                        let planner = CopilotPlanner(tune: tune, catalog: app.catalog, blocked: blocked, analysis: analysis)
                        plans = result.changes.map(planner.plan)
                    } else if !result.changes.isEmpty {
                        self.update(id) { $0.error = "Open a tune to review these changes." }
                    }
                    self.update(id) { $0.text = raw; $0.display = result.display; $0.plans = plans }
                    break
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
                self.update(id) { m in
                    if cancelled { if m.display.isEmpty { m.display = "_Stopped._" } }
                    else { m.error = error.localizedDescription }
                }
            }
        }
    }

    /// The conversation as the model sees it, with a note of which proposals the user applied.
    private func modelHistory(app: AppModel) -> [[String: String]] {
        messages.suffix(30).compactMap { m in
            guard m.done, m.error == nil else { return nil }
            var content = m.role == "assistant" ? (m.text.isEmpty ? m.display : m.text) : m.text
            if !m.attachments.isEmpty { content += "\n[Attached: " + m.attachments.joined(separator: ", ") + "]" }
            let applied = m.plans.filter { state($0, app: app) == .applied }.map { "\($0.name) (\($0.edits.count) values)" }
            if !applied.isEmpty { content += "\n[The user applied: " + applied.joined(separator: "; ") + "]" }
            return content.isEmpty ? nil : ["role": m.role, "content": content]
        }
    }

    private func load(_ urls: [URL]) async throws -> [(name: String, table: LogTable)] {
        var out: [(name: String, table: LogTable)] = []
        for url in urls {
            if let t = parsed[url] { out.append((url.lastPathComponent, t)); continue }
            let table = try await Task.detached(priority: .userInitiated) { () throws -> LogTable in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= 60_000_000 else { throw CopilotError("\(url.lastPathComponent) is too large (over 60 MB).") }
                let text = try String(contentsOf: url, encoding: .utf8)
                let t = LogTable(csv: text)
                guard !t.time.isEmpty, !t.columns.isEmpty else { throw CopilotError("No samples found in \(url.lastPathComponent).") }
                return t
            }.value
            parsed[url] = table
            out.append((url.lastPathComponent, table))
        }
        return out
    }

    // MARK: applying proposals

    enum PlanState { case pending, applied, edited }

    func state(_ plan: CopilotPlan, app: AppModel) -> PlanState {
        guard let p = app.tune?.parameter(plan.parameterID), plan.problem == nil else { return .pending }
        func current(_ e: PlannedEdit) -> Double? {
            if plan.isScalar { return p.scalar }
            guard p.rows.indices.contains(e.row), p.rows[e.row].indices.contains(e.col) else { return nil }
            return p.rows[e.row][e.col]
        }
        if plan.edits.allSatisfy({ current($0) == $0.new }) { return .applied }
        if plan.edits.allSatisfy({ current($0) == $0.old }) { return .pending }
        return .edited
    }

    func apply(_ plan: CopilotPlan, app: AppModel, revert: Bool = false) {
        let changes: [(EditTarget, Double)] = plan.edits.map {
            (plan.isScalar ? .scalar : .cell($0.row, $0.col), revert ? $0.old : $0.new)
        }
        let what = plan.isScalar ? plan.name : "\(plan.name), \(plan.edits.count) cells"
        app.apply(plan.parameterID, changes, label: (revert ? "Reverted " : "Applied ") + what + " · ⌘Z to undo")
    }
}

// MARK: - Page

struct CopilotView: View {
    @ObservedObject var store: CopilotStore
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveEngine
    @AppStorage("copilot.provider") private var providerRaw = CopilotStore.defaultProvider.rawValue
    @AppStorage("copilot.model") private var modelName = CopilotClient.defaultModel
    @State private var showSettings = false
    @State private var dropping = false

    private var provider: CopilotProvider { CopilotProvider(rawValue: providerRaw) ?? .openAI }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if store.messages.isEmpty { welcome } else { conversation }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .background(Color.accentColor.opacity(0.06)).padding(12)
                    .overlay(Label("Drop CSV logs to attach", systemImage: "paperclip").font(.title3.weight(.medium)))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.attach(urls); return true
        } isTargeted: { dropping = $0 }
        .sheet(isPresented: $showSettings) { CopilotSettingsView() }
    }

    // MARK: top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Answer with", selection: $providerRaw) {
                    ForEach(CopilotProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                if provider == .openAI {
                    Picker("Model", selection: $modelName) {
                        ForEach(Array(Set(CopilotClient.suggestedModels + [modelName])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                Divider()
                Button("Copilot Settings…") { showSettings = true }
            } label: {
                HStack(spacing: 5) {
                    Text("Copilot").font(.system(size: 17, weight: .semibold))
                    Text(provider == .openAI ? modelName : "ChatGPT").font(.system(size: 17)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.0001)))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            Spacer()
            contextChip
            Button { store.newChat() } label: { Image(systemName: "square.and.pencil").font(.system(size: 16)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("New chat").disabled(store.messages.isEmpty && store.pending.isEmpty)
            Button { showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 16)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Copilot settings")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var contextChip: some View {
        HStack(spacing: 6) {
            Image(systemName: model.tune == nil ? "doc.badge.ellipsis" : "doc.text")
            Text(model.tune == nil ? "No tune open" : model.fileName).lineLimit(1)
            if !store.logs.isEmpty { Text("· \(store.logs.count) log\(store.logs.count == 1 ? "" : "s")") }
            if live.connected {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Live")
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help("Copilot sees the open tune, the logs attached to this chat and live ECU data when connected.")
    }

    // MARK: empty state

    private struct Suggestion: Identifiable {
        let title, detail, icon, prompt: String
        var needsLog = false
        var id: String { title }
    }
    private let suggestions = [
        Suggestion(title: "Check my tune", detail: "like a pro before a dyno day", icon: "checklist",
                   prompt: "Go through my tune like a professional tuner would before a dyno day. What's wrong or risky, and what would you change first?"),
        Suggestion(title: "Fix fuel from my log", detail: "correct the fuel table from lambda", icon: "drop",
                   prompt: "Use my log to correct the fuel table. Show me the lean and rich areas and propose the changes.", needsLog: true),
        Suggestion(title: "Explain my ignition table", detail: "is the timing sensible?", icon: "bolt",
                   prompt: "Explain my ignition table. Is the timing sensible for this setup, and where would you be careful?"),
        Suggestion(title: "Set up launch control", detail: "two-step for drag starts", icon: "flag.checkered",
                   prompt: "Help me set up launch control (two-step) on this ECU. Tell me what to set and propose the changes."),
    ]

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            Text("What are we tuning today?")
                .font(.system(size: 30, weight: .semibold))
            if model.tune == nil {
                VStack(spacing: 10) {
                    Text("Open a tune or read it from the ECU so Copilot can see it and change it. You can still ask general tuning questions.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
                    HStack {
                        Button("Open Tune…") { model.openPanel() }.buttonStyle(.borderedProminent)
                        Button("Try the practice tune") {
                            do { try model.openPractice(); store.attach(LabAsset.logs.compactMap { try? LabAsset.url($0, "csv") }) }
                            catch { model.error = error.localizedDescription }
                        }
                    }
                    .controlSize(.large)
                }
            }
            CopilotComposer(store: store, recentLogs: recentLogs, send: { send() })
                .frame(maxWidth: 740)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(suggestions) { s in
                    Button { use(s) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.icon).font(.system(size: 15)).foregroundStyle(.orange).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.system(size: 13, weight: .semibold))
                                Text(s.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 740)
            Spacer(minLength: 20)
            footnote
        }
        .padding(.horizontal, 24)
    }

    private func use(_ s: Suggestion) {
        if s.needsLog && store.logs.isEmpty && store.pending.isEmpty {
            store.attach(CopilotComposer.chooseLogs())
            guard !store.pending.isEmpty else { return }
        }
        store.send(s.prompt, app: model, live: live)
    }

    // MARK: conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(store.messages) { m in
                            CopilotMessageView(message: m, store: store, isLast: m.id == store.messages.last?.id).id(m.id)
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: store.tick) { _, _ in if store.busy { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            CopilotComposer(store: store, recentLogs: recentLogs, send: { send() })
                .frame(maxWidth: 760).padding(.horizontal, 24)
            footnote.padding(.vertical, 8)
        }
    }

    private var footnote: some View {
        Text("Copilot can make mistakes. Changes only edit the open tune file — review them, and check on the car before you trust them.")
            .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
    }

    private var recentLogs: [URL] {
        live.logs.list().prefix(8).map { live.logs.folder.appendingPathComponent($0.id) }
    }

    private func send() { store.send(app: model, live: live) }
}

// MARK: - Composer

struct CopilotComposer: View {
    @ObservedObject var store: CopilotStore
    let recentLogs: [URL]
    let send: () -> Void
    @FocusState private var focused: Bool

    private var canSend: Bool { !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.pending.isEmpty }

    static func chooseLogs() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = true
        panel.message = "Choose data logs (CSV) for Copilot to analyse"
        return panel.runModal() == .OK ? panel.urls : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.pending, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "chart.xyaxis.line").foregroundStyle(.orange)
                                Text(url.lastPathComponent).lineLimit(1)
                                Button { store.pending.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Menu {
                    Button("Choose CSV Logs…") { store.attach(Self.chooseLogs()) }
                    if !recentLogs.isEmpty {
                        Section("Recent recordings") {
                            ForEach(recentLogs, id: \.self) { url in Button(url.lastPathComponent) { store.attach([url]) } }
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                        .frame(width: 32, height: 32).contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Attach data logs")

                TextField("Ask anything about your tune", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...10)
                    .focused($focused)
                    .onSubmit { if canSend && !store.busy { send() } }
                    .padding(.vertical, 7)

                Button {
                    if store.busy { store.stop() } else if canSend { send() }
                } label: {
                    Image(systemName: store.busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: store.busy ? 11 : 14, weight: .bold))
                        .foregroundStyle(Color(nsColor: .textBackgroundColor))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(store.busy || canSend ? Color.primary : Color.primary.opacity(0.25)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help(store.busy ? "Stop" : "Send (Return)")
            }
        }
        .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
        .onAppear { focused = true }
    }
}

// MARK: - Messages

struct CopilotMessageView: View {
    let message: CopilotStore.Message
    @ObservedObject var store: CopilotStore
    let isLast: Bool
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveEngine
    @State private var copied = false

    var body: some View {
        if message.role == "user" { user } else { assistant }
    }

    private var user: some View {
        HStack {
            Spacer(minLength: 90)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.attachments, id: \.self) { name in
                            Label(name, systemImage: "chart.xyaxis.line").font(.system(size: 12)).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
                        }
                    }
                }
                Text(message.text)
                    .font(.system(size: 15)).lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.07)))
            }
        }
    }

    private var assistant: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().strokeBorder(Color.primary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 14) {
                if !message.display.isEmpty { CopilotMarkdown(text: message.display) }
                if let status = message.status {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                if let error = message.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                        if isLast { Button("Try again") { store.regenerate(app: model, live: live) } }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.08)))
                }
                ForEach(message.plans) { plan in PlanCard(plan: plan, store: store) }
                if message.done && !message.display.isEmpty {
                    HStack(spacing: 14) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.display, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.help("Copy")
                        if isLast && !store.busy {
                            Button { store.regenerate(app: model, live: live) } label: { Image(systemName: "arrow.clockwise") }.help("Regenerate")
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Proposed change card

struct PlanCard: View {
    let plan: CopilotPlan
    @ObservedObject var store: CopilotStore
    @EnvironmentObject var model: AppModel

    var body: some View {
        let state = store.state(plan, app: model)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: plan.isScalar ? "slider.horizontal.3" : "tablecells").foregroundStyle(.orange)
                Text(plan.name).font(.system(size: 14, weight: .semibold))
                Text(verbatim: "D\(plan.parameterID)").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if plan.problem == nil {
                    switch state {
                    case .applied: Label("Applied", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
                    case .edited: Label("Edited since", systemImage: "pencil.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    case .pending: EmptyView()
                    }
                }
            }
            Text(plan.region.isEmpty ? plan.summary : plan.summary + " · " + plan.region)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(plan.problem == nil ? .primary : .secondary)
            if !plan.why.isEmpty { Text(plan.why).font(.system(size: 13)).foregroundStyle(.secondary) }
            if let note = plan.note { Label(note, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange) }
            if plan.problem == nil && !plan.isScalar && plan.rows * plan.cols > 1 { DeltaMap(plan: plan) }
            HStack(spacing: 8) {
                if plan.problem == nil {
                    switch state {
                    case .pending:
                        Button("Apply") { store.apply(plan, app: model) }.buttonStyle(.borderedProminent)
                    case .applied:
                        Button("Undo") { store.apply(plan, app: model, revert: true) }
                    case .edited:
                        Button("Apply anyway") { store.apply(plan, app: model) }
                    }
                }
                if model.tune?.parameter(plan.parameterID) != nil {
                    Button(plan.isScalar ? "Show setting" : "Open table") { model.selectedId = plan.parameterID }
                }
                Spacer()
            }
            .controlSize(.regular)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// Small heat map of the change: orange cells go up, blue cells go down.
struct DeltaMap: View {
    let plan: CopilotPlan

    var body: some View {
        let changes = Dictionary(plan.edits.map { ([$0.row, $0.col], $0.old != 0 ? ($0.new / $0.old - 1) : ($0.new - $0.old)) }, uniquingKeysWith: { a, _ in a })
        let peak = max(changes.values.map(abs).max() ?? 1, 1e-9)
        let cell = max(5.0, min(14.0, 420.0 / Double(max(plan.cols, 1))))
        HStack(alignment: .bottom, spacing: 10) {
            Canvas { ctx, _ in
                for r in 0..<plan.rows {
                    for c in 0..<plan.cols {
                        let rect = CGRect(x: Double(c) * (cell + 1), y: Double(r) * (cell * 0.75 + 1), width: cell, height: cell * 0.75)
                        let color: Color
                        if let d = changes[[r, c]] {
                            let k = 0.35 + 0.65 * abs(d) / peak
                            color = d >= 0 ? Color.orange.opacity(k) : Color.blue.opacity(k)
                        } else { color = Color.primary.opacity(0.07) }
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
                    }
                }
            }
            .frame(width: Double(plan.cols) * (cell + 1), height: Double(plan.rows) * (cell * 0.75 + 1))
            VStack(alignment: .leading, spacing: 3) {
                Label("more", systemImage: "square.fill").foregroundStyle(.orange)
                Label("less", systemImage: "square.fill").foregroundStyle(.blue)
            }
            .font(.system(size: 10)).labelStyle(.titleAndIcon)
        }
        .help("Where the change lands in the table (rows top to bottom as in the table editor)")
    }
}

// MARK: - Markdown

/// Renders the subset of markdown chat models write: headings, lists, tables, code, bold/italic/code spans.
struct CopilotMarkdown: View {
    let text: String

    private enum Block { case heading(Int, String), paragraph(String), item(String, String, Int), code(String), table([[String]]), rule }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let s):
                    inline(s).font(.system(size: level == 1 ? 20 : level == 2 ? 17 : 15, weight: .semibold)).padding(.top, 4)
                case .paragraph(let s):
                    inline(s).font(.system(size: 15)).lineSpacing(4)
                case .item(let marker, let s, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).font(.system(size: 15)).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                        inline(s).font(.system(size: 15)).lineSpacing(4)
                    }
                    .padding(.leading, CGFloat(indent) * 18)
                case .code(let s):
                    Text(s).font(.system(size: 12.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                case .table(let rows):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        inline(cell).font(.system(size: 13, weight: r == 0 ? .semibold : .regular).monospacedDigit())
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                    }
                                }
                                .background(r == 0 ? Color.primary.opacity(0.05) : Color.clear)
                                if r < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(s)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = [], code: [String]? = nil, table: [[String]] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !table.isEmpty { out.append(.table(table)); table = [] }
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if t.hasPrefix("```") { out.append(.code(code!.joined(separator: "\n"))); code = nil } else { code!.append(line) }
                continue
            }
            if t.hasPrefix("```") { flush(); code = []; continue }
            if t.hasPrefix("|") {
                if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
                var cells = t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }   // separator row
                table.append(cells)
                continue
            }
            if !table.isEmpty { out.append(.table(table)); table = [] }
            if t.isEmpty { flush(); continue }
            if t == "---" || t == "***" { flush(); out.append(.rule); continue }
            if let h = t.firstIndex(where: { $0 != "#" }), t.hasPrefix("#"), t[h] == " " {
                flush(); out.append(.heading(t.distance(from: t.startIndex, to: h), String(t[h...]).trimmingCharacters(in: .whitespaces))); continue
            }
            let indent = (line.prefix { $0 == " " }.count) / 2
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                flush(); out.append(.item("•", String(t.dropFirst(2)), indent)); continue
            }
            if let dot = t.firstIndex(where: { $0 == "." || $0 == ")" }), dot > t.startIndex,
               t[..<dot].allSatisfy(\.isNumber), t.index(after: dot) < t.endIndex, t[t.index(after: dot)] == " " {
                flush(); out.append(.item(String(t[...dot]), String(t[t.index(dot, offsetBy: 2)...]), indent)); continue
            }
            para.append(t)
        }
        if let code { out.append(.code(code.joined(separator: "\n"))) }
        flush()
        return out
    }
}

// MARK: - Settings

struct CopilotSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("copilot.provider") private var providerRaw = CopilotStore.defaultProvider.rawValue
    @AppStorage("copilot.model") private var modelName = CopilotClient.defaultModel
    @State private var key = ""
    @State private var hasKey = CopilotKeychain.apiKey() != nil
    @State private var planStatus = ""
    @State private var planBusy = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Answer with", selection: $providerRaw) {
                        ForEach(CopilotProvider.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text(providerRaw == CopilotProvider.openAI.rawValue
                         ? "Fastest. Replies stream in as they're written. Billed per use on your OpenAI API account."
                         : "Uses your ChatGPT plan. Needs Node.js 22+ and the sign-in helper (run src/scripts/install-chatgpt-plan.sh once).")
                }
                if providerRaw == CopilotProvider.openAI.rawValue {
                    Section("OpenAI API") {
                        HStack {
                            SecureField(hasKey ? "Key saved — paste a new one to replace it" : "Paste your API key (sk-…)", text: $key)
                            Button("Save") { CopilotKeychain.setAPIKey(key); key = ""; hasKey = CopilotKeychain.apiKey() != nil }
                                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        HStack {
                            Label(hasKey ? "Key stored in your Keychain" : "No key saved", systemImage: hasKey ? "checkmark.seal.fill" : "key")
                                .foregroundStyle(hasKey ? .green : .secondary)
                            Spacer()
                            if hasKey { Button("Remove") { CopilotKeychain.setAPIKey(""); hasKey = CopilotKeychain.apiKey() != nil } }
                            Link("Get a key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        }
                        HStack {
                            TextField("Model", text: $modelName)
                            Menu("Pick") { ForEach(CopilotClient.suggestedModels, id: \.self) { m in Button(m) { modelName = m } } }.fixedSize()
                        }
                    }
                } else {
                    Section("ChatGPT account") {
                        HStack {
                            Text(planStatus.isEmpty ? "Checking…" : planStatus).foregroundStyle(.secondary)
                            Spacer()
                            if planBusy { ProgressView().controlSize(.small) }
                            Button("Sign in with ChatGPT") { plan("signin") }
                            Button("Disconnect") { plan("disconnect") }
                        }
                        .disabled(planBusy)
                    }
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(16)
        }
        .frame(width: 540, height: 400)
        .onAppear { if providerRaw == CopilotProvider.chatGPTPlan.rawValue { plan("status") } }
        .onChange(of: providerRaw) { _, v in if v == CopilotProvider.chatGPTPlan.rawValue { plan("status") } }
    }

    private func plan(_ action: String) {
        planBusy = true
        Task { @MainActor in
            defer { planBusy = false }
            do {
                let s = try await ChatGPTPlan.call(action)
                planStatus = s.sharing == true ? "Connected · " + (s.label ?? "")
                    : s.connected == true ? "Signed in — allow plan usage to continue" : "Not signed in"
            } catch { planStatus = error.localizedDescription }
        }
    }
}
