// The two surfaces: the menu-bar pulse and the window.

import SwiftUI
import AppKit
import RealmLensCore

// ---------------------------------------------------------------- pulse panel

struct PulsePanel: View {
    @Environment(LensStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    private var now: Int { store.clock }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if let err = store.errorText {
                errorBlock(err)
            } else {
                watchLine
                Divider()
                attentionList
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    private var header: some View {
        let c = store.counts
        let tainted = store.nodes.filter(\.tainted).count
        return VStack(alignment: .leading, spacing: 3) {
            Text(store.spacePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent } ?? "realm")
                .font(.headline)
            HStack(spacing: 8) {
                if let v = c["VERIFIED"] { label("✓", v, .green) }
                if let u = c["UNVERIFIED"] { label("?", u, .secondary) }
                if let r = c["REFUTED"] { label("✗", r, .red) }
                if tainted > 0 { label("!", tainted, .orange) }
                let leased = store.liveLeases.count
                if leased > 0 { label("@", leased, .blue) }
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    private func label(_ g: String, _ n: Int, _ color: Color) -> some View {
        Text("\(g)\(n)").foregroundStyle(color)
    }

    private var watchLine: some View {
        Group {
            if let l = store.liveLeases.min(by: { ($0.expiresAt ?? 0) < ($1.expiresAt ?? 0) }) {
                let left = l.remaining(now: now)
                Label("\(l.resource) leased to \(l.owner ?? "?") — \(left / 60)m left",
                      systemImage: left < 120 ? "exclamationmark.triangle" : "clock")
                    .font(.caption)
                    .foregroundStyle(left < 120 ? .orange : .secondary)
            } else if store.nodes.isEmpty {
                Label("no work in the space", systemImage: "moon.zzz").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("no live leases", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var attentionList: some View {
        let rows = store.nodes
            .filter { n in
                let s = store.statusText(n)
                return s == "REFUTED" || s == "CONTESTED" || s == "TAINTED" || s == "BLOCKED"
            }
            .prefix(5)
        return VStack(alignment: .leading, spacing: 4) {
            if rows.isEmpty {
                Text("nothing needs attention").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows)) { n in
                    HStack(spacing: 6) {
                        Text(store.glyph(n)).font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
                        Text(n.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Text(n.title).font(.caption).lineLimit(1)
                    }
                }
            }
        }
    }

    private func errorBlock(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("cannot read space", systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(.red)
            Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Lens…") {
                openWindow(id: "lens")
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            if store.lastPollMillis > 0 {
                Text(String(format: "%.1fms", store.lastPollMillis))
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

// ---------------------------------------------------------------- window

/// Which surface the window is showing. Graph answers "what does the space believe";
/// Terminals answers "who is working and on what". They are separate modes rather than a
/// split because the graph wants width and the terminals want height.
enum WindowMode: String, CaseIterable, Identifiable {
    // Declaration order IS picker order. Terminals first: this is a workbench, and the
    // graph is a reference you consult rather than the place you spend the session.
    case terminals = "Terminals"
    case graph = "Graph"
    var id: String { rawValue }
}

struct LensWindow: View {
    @Environment(LensStore.self) private var store
    @State private var mode: WindowMode = .terminals
    @State private var missingDatabase: URL?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                headerBar
                if let missingDatabase {
                    HStack {
                        Label("No Realm database at \(missingDatabase.path)", systemImage: "exclamationmark.triangle")
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { self.missingDatabase = nil }
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
                Divider()
                switch mode {
                case .graph:
                    HSplitView {
                        graphPane
                        if let id = store.selection, let n = store.snapshot?.node(id) {
                            Inspector(node: n, store: store)
                                .frame(minWidth: 300, idealWidth: 340)
                        }
                    }
                case .terminals:
                    terminalsPane
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    /// Terminals on the left, orchestrator docked right at a fixed width so the rope
    /// geometry does not change as node titles grow.
    @ViewBuilder
    private var terminalsPane: some View {
        if let agents = store.agents {
            VStack(spacing: 0) {
                agentToolbar(agents)
                Divider()
                // A failed read must be VISIBLE here, not only in the menu bar. Without
                // this banner a damaged or unreadable space rendered as "frontier is clear
                // / nothing needs attention / no leases held" — which reads as EMPTY AND
                // HEALTHY while the database is actually broken. That is the exact
                // silent-divergence failure this app exists to prevent.
                if let err = store.errorText {
                    spaceErrorBanner(err)
                    Divider()
                }
                OrchestrationBar(
                    run: store.orchestration,
                    space: store.spacePath.map { URL(fileURLWithPath: $0, isDirectory: true) },
                    spaceReadable: store.snapshot != nil && store.errorText == nil
                )
                Divider()
                HStack(spacing: 0) {
                    TerminalGrid(agents: agents)
                        .environment(store)
                        .padding(8)
                    Divider()
                    OrchestratorPanel(leases: store.leases,
                                      nodes: store.nodes,
                                      now: store.clock,
                                      onSelect: { store.selection = $0; mode = .graph })
                        .frame(width: 260)
                }
                .opacity(store.errorText == nil ? 1 : 0.45)
            }
            .onAppear { agents.materialize() }
        } else {
            ContentUnavailableView("Choose a Realm space", systemImage: "folder",
                                   description: Text("Select a project where you have run realm init."))
        }
    }

    /// Says plainly that the orchestrator is showing nothing because the read failed,
    /// not because the space is quiet. Dimming the panel below reinforces it.
    private func spaceErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("✗")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 3) {
                Text("cannot read this space — the panels below are NOT showing an empty space")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.red)
                Text(message)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Choose space…") { chooseSpace() }
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    /// Adding a pane is the only place a process is created, so the consequence is stated
    /// on the control rather than discovered by quitting.
    private func agentToolbar(_ agents: AgentsStore) -> some View {
        HStack(spacing: 8) {
            Text(agents.showingGoalTerminals ? "Goal terminals" : "Workspace terminals")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("closing the window terminates every pane")
                .font(.caption2)
                .foregroundStyle(agents.anyRunning ? Color.orange : Color.secondary)
            Spacer()
            if !agents.goalHosts.isEmpty {
                Button(agents.showingGoalTerminals ? "Show workspace terminals" : "Show goal terminals") {
                    agents.toggleTerminalGroup()
                }
                .buttonStyle(.link)
            }
            if agents.showingGoalTerminals {
                Menu("Add workspace terminal") {
                    ForEach(AgentSpec.presets) { h in
                        Button(OrchestrationRun.Agent(rawValue: h.name)?.label ?? h.name) {
                            agents.add(harness: h.name)
                        }
                        .disabled(agents.hosts.filter { $0.spec.harness == h.name }.count >= 9)
                    }
                    Divider()
                    Button("Custom…") { addCustomAgent(agents) }
                }
                .fixedSize()
            } else {
                ForEach(AgentSpec.presets) { h in
                    let count = agents.hosts.filter { $0.spec.harness == h.name }.count
                    Button {
                        agents.add(harness: h.name)
                    } label: {
                        HStack(spacing: 3) {
                            if count > 0 {
                                Text("●").font(.system(size: 7)).foregroundStyle(Color.secondary)
                            }
                            Text(count > 0 ? "\(h.name) \(count)" : "+ \(h.name)")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.link)
                    .disabled(count >= 9)
                    .help("Open a \(h.name) workspace terminal")
                }
                Divider().frame(height: 12)
                Button("+ custom…") { addCustomAgent(agents) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// A harness with no preset, or a preset with extra arguments. Two fields, because a
    /// command and an identity are different things: `claude-reviewer` running `claude` is
    /// the normal case, not an exotic one.
    private func addCustomAgent(_ agents: AgentsStore) {
        let alert = NSAlert()
        alert.messageText = "Add agent pane"
        alert.informativeText = """
        Command: any CLI on your login-shell PATH. Extra arguments are allowed, e.g.
        `aider --model sonnet`.

        Identity: the REALM_AGENT this pane writes as. Leave it empty to use the command
        name. Two panes of the same CLI need different identities, or they share leases.
        """
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let box = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6

        let command = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        command.placeholderString = "command (e.g. hermes --yolo)"
        let identity = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        identity.placeholderString = "identity / REALM_AGENT (optional)"
        box.addArrangedSubview(command)
        box.addArrangedSubview(identity)
        alert.accessoryView = box
        alert.window.initialFirstResponder = command

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = identity.stringValue.isEmpty ? nil : identity.stringValue
        agents.addCustom(command: command.stringValue, identity: id)
    }

    private var sidebar: some View {
        List(selection: Bindable(store).selection) {
            Section("Trees") {
                ForEach(roots) { n in
                    row(n)
                }
            }
            Section("Unlinked") {
                ForEach(unlinked) { n in
                    row(n)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 260)
    }

    private func row(_ n: RealmNode) -> some View {
        HStack(spacing: 6) {
            Text(store.glyph(n))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color(for: store.statusText(n)))
                .frame(width: 12)
            Text(n.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Text(n.title).font(.caption).lineLimit(1)
        }
        .tag(n.id)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text(store.spacePath ?? "no space").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Picker("View", selection: $mode) {
                ForEach(WindowMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            if let snap = store.snapshot {
                Text("seq \(snap.cursor)").font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                Text("\(snap.nodes.count) nodes").font(.caption).foregroundStyle(.tertiary)
            }
            Button("Choose space…") { chooseSpace() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var graphPane: some View {
        ScrollView([.horizontal, .vertical]) {
            GraphCanvas(store: store, selection: Bindable(store).selection)
                .padding(20)
        }
        .frame(minWidth: 420)
    }

    private var roots: [RealmNode] {
        guard let snap = store.snapshot else { return [] }
        let withPrereq = Set(snap.edges.filter {
            ["requires", "depends_on"].contains($0.kind)
        }.map(\.from))
        let anyEdge = Set(snap.edges.flatMap { [$0.from, $0.to] })
        // Must have at least one edge, or it belongs in Unlinked instead.
        return snap.nodes
            .filter { !withPrereq.contains($0.id) && anyEdge.contains($0.id) }
            .sorted(by: severitySort)
    }

    private var unlinked: [RealmNode] {
        guard let snap = store.snapshot else { return [] }
        let linked = Set(snap.edges.flatMap { [$0.from, $0.to] })
        return snap.nodes.filter { !linked.contains($0.id) }.sorted(by: severitySort)
    }

    private func severitySort(_ a: RealmNode, _ b: RealmNode) -> Bool {
        rank(store.statusText(a)) < rank(store.statusText(b))
    }
    private func rank(_ s: String) -> Int {
        ["REFUTED": 0, "CONTESTED": 1, "TAINTED": 2, "BLOCKED": 3,
         "UNVERIFIED": 4, "OPEN": 5, "VERIFIED": 6, "DONE": 7][s] ?? 8
    }

    private func color(for s: String) -> Color {
        switch s {
        case "REFUTED": return .red
        case "CONTESTED": return .pink
        case "TAINTED": return .orange
        case "BLOCKED": return .yellow
        case "VERIFIED", "DONE": return .green
        default: return .secondary
        }
    }

    private func chooseSpace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // `.realm` starts with a dot, so it is hidden in the panel by default. Without this
        // the picker cannot reach the only directory it is asking the user for.
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose a .realm directory (hidden folders are shown), or pick a project folder"
        panel.prompt = "Use space"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let space = folder.lastPathComponent == ".realm" ? folder : folder.appendingPathComponent(".realm", isDirectory: true)
        let database = space.appendingPathComponent("space.db")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: database.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            missingDatabase = database
            return
        }
        missingDatabase = nil
        store.setSpace(space)
    }
}

// ---------------------------------------------------------------- inspector

struct Inspector: View {
    let node: RealmNode
    let store: LensStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(store.glyph(node)).font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(node.id).font(.system(.headline, design: .monospaced))
                        Text(store.statusText(node)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(node.title).font(.body)
                if !node.body.isEmpty {
                    Text(node.body).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    if node.kind == .fact {
                        GridRow { Text("check").foregroundStyle(.secondary); Text(node.checkCmd ?? "—").font(.system(.caption, design: .monospaced)) }
                        GridRow { Text("strength").foregroundStyle(.secondary); Text(node.checkStrength ?? "—") }
                        GridRow { Text("exit").foregroundStyle(.secondary); Text(node.checkExit.map(String.init) ?? "—") }
                        GridRow { Text("assumed").foregroundStyle(.secondary); Text(node.assumed ? "yes" : "no") }
                    }
                    if node.kind == .task {
                        GridRow { Text("state").foregroundStyle(.secondary); Text(node.taskState) }
                        GridRow { Text("priority").foregroundStyle(.secondary); Text("\(node.priority)") }
                    }
                    GridRow { Text("created by").foregroundStyle(.secondary); Text(node.createdBy) }
                }
                .font(.caption)

                if !node.blockedBy.isEmpty {
                    Divider()
                    Text("Blocked by").font(.caption).bold()
                    ForEach(node.blockedBy, id: \.self) { id in
                        Text(id).font(.system(.caption, design: .monospaced)).foregroundStyle(.yellow)
                    }
                }
                if node.tainted {
                    Text("TAINTED — depends on an assumed fact that is not verified")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(12)
        }
    }
}
