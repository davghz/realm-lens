// TerminalPane — one real CLI inside the app, hosted in a real PTY.
//
// Lifetime is explicit and deliberately NOT owned by SwiftUI. A `TerminalHost` owns its
// `LocalProcessTerminalView` and its child process; the representative view is a thin
// shim that returns the host's NSView. SwiftUI is free to rebuild the shim as often as
// it likes without spawning a second `opencode`, and closing a pane or quitting the app
// goes through `shutdown()` exactly once.
//
// Why a login-interactive shell rather than exec'ing the CLI directly: agent CLIs are
// usually installed by npm/brew into a PATH that is assembled in `.zshrc`, which a
// non-interactive process does not read. `zsh -lic 'exec ...'` gets that PATH and then
// replaces itself with the CLI, so there is still exactly one process to signal.

import SwiftUI
import AppKit
import SwiftTerm

// ---------------------------------------------------------------- spec

/// Which agent CLI a pane runs. A preset is the *harness*, not the identity: two panes
/// can run `claude` under different REALM_AGENT names so they hold leases separately.
struct Harness: Identifiable, Equatable, Codable {
    var id: String { name }
    var name: String            // "claude", "codex", "opencode", "hermes", "agy"
    var command: String         // executable resolved on the login-shell PATH
    var arguments: [String]     // auto-approve flags for this CLI
}

/// What to run in a pane.
///
/// `name` is the REALM_AGENT identity and is intentionally NOT the command. The first
/// version forced them equal, which made it impossible to run two `claude` panes (a
/// reviewer and an implementer) because one identity would have owned both panes' leases.
struct AgentSpec: Identifiable, Equatable, Codable {
    var name: String            // REALM_AGENT, e.g. "claude-reviewer"
    var command: String         // harness executable
    var arguments: [String]
    var workingDirectory: String
    /// The harness this pane was created from, for the header and for the menu.
    var harness: String = ""

    var id: String { name }

    /// The command line shown in the pane header, so what is running is never a mystery.
    var displayCommand: String {
        ([command] + arguments).joined(separator: " ")
    }

    /// Header text: the identity, plus the harness when the two differ.
    var title: String {
        harness.isEmpty || harness == name ? name : "\(name) · \(harness)"
    }

    /// Harnesses this build knows how to pre-authorize. Ordered by what is actually
    /// installed here; anything else can still be added with a custom command.
    static let presets: [Harness] = [
        Harness(name: "opencode", command: "opencode", arguments: ["--auto"]),
        Harness(name: "codex", command: "codex",
                arguments: ["--dangerously-bypass-approvals-and-sandbox"]),
        Harness(name: "claude", command: "claude",
                arguments: ["--dangerously-skip-permissions"]),
        Harness(name: "hermes", command: "hermes", arguments: ["--yolo"]),
        // `gemini` is retired here: Google's CLI is now Antigravity, whose binary is `agy`.
        // The Homebrew `gemini-cli` package was uninstalled, so keeping the preset would
        // offer a chip that cannot launch.
        Harness(name: "agy", command: "agy",
                arguments: ["--dangerously-skip-permissions"]),
    ]

    static func preset(_ name: String) -> Harness? {
        presets.first { $0.name == name }
    }

    /// Flags that pre-authorize a harness, per CLI. Unknown harnesses get none, because
    /// a wrong flag turns "start" into "crash" and an unknown CLI is better asked than
    /// guessed at.
    ///
    /// These are each CLI's own documented switch:
    ///   claude   --dangerously-skip-permissions
    ///   codex    --dangerously-bypass-approvals-and-sandbox
    ///   opencode --auto
    ///   hermes   --yolo
    ///   agy      --dangerously-skip-permissions  (Google Antigravity)
    ///
    /// Goal terminals with full access also confirm known workspace-trust and bypass
    /// menus after the CLI renders them. Other prompts remain interactive in the pane.
    static func autoApproveArguments(for harness: String) -> [String] {
        preset(harness)?.arguments ?? []
    }

    /// Harness defaults: a fresh pane for each installed CLI, under its own name.
    static let defaultRoster: [AgentSpec] = ["opencode", "codex", "claude"].map { h in
        AgentSpec(name: h, command: h,
                  arguments: autoApproveArguments(for: h),
                  workingDirectory: "", harness: h)
    }
}

// ---------------------------------------------------------------- host

/// Owns one PTY child. `ObservableObject` so the pane header can show liveness without
/// the terminal view itself participating in SwiftUI updates.
final class TerminalHost: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let spec: AgentSpec
    /// The space this pane's agent must write to. Passed as REALM_SPACE so the child
    /// cannot resolve a different one by accident.
    let spacePath: String
    let view: ObservableTerminalView
    let goalRole: GoalRole?
    let realmIdentity: String
    @Published private(set) var assignment: GoalTerminalRequest?
    @Published private(set) var awaitingStartup = true
    private var inputTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private let fullAccess: Bool
    private var receivedOutput = false
    private var launchDate = Date.distantPast

    /// Set once `shutdown()` has run; guards against a second terminate and against
    /// `processTerminated` being reported as an unexpected crash after a deliberate stop.
    private var shuttingDown = false
    private var started = false
    /// True only while this pane is believed to own its `shellPid`. Cleared the moment
    /// the child is observed to have exited, so a later shutdown cannot signal a pid the
    /// OS may have reused. SwiftTerm never clears `shellPid` itself.
    private var childAlive = false
    /// The child's process-group id, captured at spawn. Kept separately from `shellPid`
    /// because the group can outlive the leader (helpers) and because `shellPid` is not
    /// cleared on exit. Only ever set from a pid we just created.
    private var ownedPgid: pid_t?

    @Published private(set) var alive = false
    @Published private(set) var exitCode: Int32?
    /// Set when the child died from a signal rather than exiting normally.
    @Published private(set) var exitSignal: Int32?
    @Published private(set) var lastTitle: String = ""
    /// Set when the pane looks stopped waiting for a human (update / trust / permission).
    @Published private(set) var prompt: PanePrompt = .none

    private let watch = PromptWatch()

    init(spec: AgentSpec, spacePath: String = "", role: GoalRole? = nil,
         identity: String? = nil, assignment: GoalTerminalRequest? = nil, fullAccess: Bool = false) {
        self.spec = spec
        self.spacePath = spacePath
        self.goalRole = role
        self.fullAccess = fullAccess
        self.realmIdentity = identity ?? spec.name
        self.assignment = assignment
        self.view = ObservableTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        // Prompt detection runs on the terminal's data queue. Publishing hops to main
        // because the pane header is SwiftUI.
        view.onOutput = { [weak self] slice in
            guard let self else { return }
            if !self.receivedOutput { DispatchQueue.main.async { self.receivedOutput = true } }
            self.watch.ingest(slice)
            let seen = self.watch.prompt
            if seen != self.prompt {
                DispatchQueue.main.async { self.prompt = seen }
            }
        }
        // Inherit the app's appearance rather than hardcoding a theme: the app already
        // adapts to light/dark and a fixed palette would fight it.
        view.nativeForegroundColor = .textColor
        view.nativeBackgroundColor = .textBackgroundColor
    }

    var pid: pid_t { view.process.shellPid }

    /// Idempotent. Starts the child exactly once, even if the view is attached twice.
    func startIfNeeded() {
        guard !started, !shuttingDown else { return }
        started = true
        alive = true
        childAlive = true

        // ProcessInfo's environment carries PATH, HOME, TERM_PROGRAM etc. SwiftTerm's own
        // helper omits PATH entirely, which would leave the CLI unresolvable.
        var env = ProcessInfo.processInfo.environment
        env["REALM_AGENT"] = realmIdentity
        env.removeValue(forKey: "REALM_LENS_BRIDGE")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // Tell the CLI it is inside Realm Lens, so a future version can adapt (and so
        // anyone debugging can see where a stray process came from).
        env["REALM_TERMINAL"] = "realm-lens"
        if !spacePath.isEmpty {
            env["REALM_SPACE"] = spacePath
        }
        let environment = env.map { "\($0.key)=\($0.value)" }

        // Build the shell command. Single-quote the command and each argument so a
        // working directory or argument containing spaces cannot split into extra words.
        var arguments = spec.arguments
        if goalRole != nil && spec.harness == "opencode" { arguments.append("--standalone") }
        if let request = assignment {
            switch spec.harness {
            case "opencode": arguments += ["--prompt", request.prompt]
            case "agy": arguments += ["--prompt-interactive", request.prompt]
            case "codex", "claude": arguments.append(request.prompt)
            default: break
            }
        }
        let quoted = ([spec.command] + arguments)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let script = "exec \(quoted)"

        // A pane name like "reviewer" selects restricted zsh when used as argv[0].
        launchDate = Date()
        view.startProcess(executable: "/bin/zsh",
                          args: ["-lic", script],
                          environment: environment,
                          currentDirectory: spec.workingDirectory)

        // Capture the group id NOW, from the pid we just created. SwiftTerm spawns with
        // POSIX_SPAWN_SETSID, so the child is its own session and process-group leader:
        // pgid == pid. Captured here because `shellPid` is never cleared by SwiftTerm and
        // cannot distinguish a live group from a recycled number later.
        if view.process.shellPid > 0 {
            ownedPgid = view.process.shellPid
        }
        if goalRole != nil { watchStartup() }
        if let assignment { watchQuota(for: assignment) }
        if let assignment, spec.harness == "hermes" { sendAssignment(assignment) }
    }

    private var screen: GoalTerminalScreen {
        let term = view.getTerminal()
        let rows = (0..<term.rows).compactMap { term.getLine(row: $0)?.translateToString(trimRight: true) }
        return GoalTerminalScreen(lines: rows, harness: spec.harness)
    }

    private func watchStartup() {
        startupTask = Task { @MainActor [weak self] in
            var lastChoice: GoalStartupChoice?
            var lastKey = Date.distantPast
            while let self, !Task.isCancelled, self.alive {
                let screen = self.screen
                if let choice = screen.startupChoice {
                    // A CLI can paint a choice before it installs its keyboard
                    // listener. Re-read the selected row before every retry.
                    if self.fullAccess && (lastChoice != choice || Date().timeIntervalSince(lastKey) >= 1.25) {
                        self.view.send(data: choice.keys[...])
                        lastChoice = choice
                        lastKey = Date()
                    }
                } else if screen.readyForAssignment {
                    // Some TUIs repaint a ready prompt entirely with cursor motion, with
                    // no newline for the stream detector to retire its old dialog.
                    if self.watch.prompt == .trust || self.watch.prompt == .permission { self.watch.reset() }
                    if self.prompt == .trust || self.prompt == .permission { self.prompt = .none }
                    self.awaitingStartup = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func watchQuota(for request: GoalTerminalRequest) {
        guard ["claude", "agy"].contains(spec.harness) else { return }
        quotaTask?.cancel()
        quotaTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.alive, FileManager.default.fileExists(atPath: request.directory) {
                if let message = self.screen.quotaMessage {
                    request.fail(message)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Deliver the handoff to this running vendor TUI via its own PTY input.
    func sendAssignment(_ request: GoalTerminalRequest) {
        assignment = request
        guard alive else { request.fail("\(spec.harness) terminal exited before its assignment"); return }
        watchQuota(for: request)
        inputTask?.cancel()
        inputTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.alive && FileManager.default.fileExists(atPath: request.directory) {
                let screen = self.screen
                if let message = screen.quotaMessage {
                    request.fail(message)
                    return
                }
                let ready = self.receivedOutput && screen.startupChoice == nil && (!self.awaitingStartup || screen.readyForAssignment)
                if (self.prompt == .trust || self.prompt == .permission), screen.readyForAssignment {
                    self.watch.reset()
                    self.prompt = .none
                }
                if ready, self.prompt == .none, Date().timeIntervalSince(self.launchDate) > 1.5 {
                    let text = request.prompt.components(separatedBy: .controlCharacters).joined(separator: " ")
                    self.view.send(data: Array(("\u{1b}[200~" + text + "\u{1b}[201~").utf8)[...])
                    try? await Task.sleep(for: .milliseconds(250))
                    let current = self.screen
                    if !Task.isCancelled && self.alive && current.startupChoice == nil && current.quotaMessage == nil
                        && FileManager.default.fileExists(atPath: request.directory) {
                        self.view.send(data: [13][...])
                        self.startupTask?.cancel()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Terminates the child and its process group, then reaps the leader.
    ///
    /// Three concerns, kept separate because conflating them produced three bugs:
    ///
    ///   1. GROUP LIFETIME — helpers the CLI forked must die. The leader being reaped says
    ///      nothing about them.
    ///   2. PID IDENTITY — a pid is meaningful only while we own it. SwiftTerm never zeroes
    ///      `shellPid` (`childStopped()` leaves it set), and its `terminate()` sends
    ///      `kill(+shellPid, SIGTERM)` unconditionally. Called after a reap, that can hit
    ///      an unrelated process that reused the number.
    ///   3. I/O TEARDOWN — the PTY descriptors must be released, and SwiftTerm offers no
    ///      close-without-kill API, so teardown has to be ordered around identity.
    ///
    /// The ordering below is the whole fix: `terminate()` is called while the leader is
    /// still UNREAPED, so the pid provably cannot have been reused yet. Reaping happens
    /// after. Nothing signals `shellPid` once the child is known dead.
    func shutdown(reportAbandonedAssignment: Bool = true) {
        guard !shuttingDown else { return }
        shuttingDown = true
        inputTask?.cancel()
        startupTask?.cancel()
        quotaTask?.cancel()
        if reportAbandonedAssignment, let assignment {
            assignment.fail("\(spec.harness) terminal closed before submitting \(assignment.task)")
        }

        let pid = view.process.shellPid
        // `childAlive` is cleared by processTerminated, which fires on natural exit.
        if childAlive, pid > 0 {
            // 1. Ask the whole group to stop. Negated pid reaches forked helpers because
            //    the child is a session leader (SwiftTerm spawns with POSIX_SPAWN_SETSID).
            kill(-pid, SIGTERM)
            // 2. Release the I/O NOW, while the pid is still ours. This is the only call
            //    SwiftTerm gives us for it, and it signals as a side effect — safe here
            //    only because the leader has not been reaped and so cannot be recycled.
            view.process.terminate()
            // 3. Reap, so no zombie is left behind.
            reap(pid)
            // 4. Whatever remains in the group now is a helper that ignored SIGTERM.
            escalateGroup(pid)
        } else {
            // The child was observed dead, and its group was ALREADY cleaned up when that
            // was noticed (see processTerminated). Anything still here is a leftover that
            // must not be signalled: `shellPid` is a released number and `ownedPgid` is
            // cleared at exit. No terminate() either — it signals the freed pid.
            // LocalProcess.deinit closes the DispatchIO without signalling.
        }

        childAlive = false
        alive = false
        ownedPgid = nil
    }

    /// Kills helpers that survived SIGTERM, after the leader has been reaped.
    ///
    /// Must run AFTER `reap`: a zombie leader is still a member of its process group, so
    /// `kill(-pgid, 0)` succeeds for as long as the leader is unreaped. Reaping first
    /// makes group emptiness mean what it says — only helpers remain.
    ///
    /// Does not claim to verify emptiness, which is not portable. A signal to an empty
    /// group is ESRCH and harmless.
    private func escalateGroup(_ pgid: pid_t) {
        for _ in 0..<10 {
            if kill(-pgid, 0) != 0 && errno == ESRCH { return }
            usleep(50_000)
        }
        kill(-pgid, SIGKILL)
    }

    /// Reaps the leader with a bounded wait. Returns the raw wait status, or nil when the
    /// child was already reaped elsewhere. Never used as a proxy for group emptiness.
    @discardableResult
    private func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        for _ in 0..<40 {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { return status }
            if r < 0 && errno == ECHILD { return nil }   // already reaped by SwiftTerm
            usleep(50_000)
        }
        return nil
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        lastTitle = title
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Clean up the group HERE, while the pgid is still provably ours, rather than
        // deferring to shutdown() which may run hours later after the pid has wrapped.
        // If a helper is still in the group the id cannot be recycled, so this is safe;
        // if the group is already empty this is ESRCH and harmless.
        watch.reset()
        prompt = .none
        if let pgid = ownedPgid, pgid > 0 {
            kill(-pgid, SIGTERM)
            escalateGroup(pgid)
            ownedPgid = nil
        }
        // Ownership ends here. From this point `shellPid` is only a historical number and
        // must never be signalled again.
        self.childAlive = false
        self.alive = false
        if !shuttingDown { assignment?.fail("\(spec.harness) terminal exited before submitting its reply") }
        // SwiftTerm forwards the RAW waitpid status word, not a POSIX exit code: `exit 7`
        // arrives as 1792 (7 << 8). Shift it down when the low byte shows a normal exit,
        // and fall back to the raw value for signal deaths so nothing is silently zeroed.
        if let raw = exitCode {
            let signal = raw & 0x7f
            self.exitCode = signal == 0 ? (raw >> 8) : raw
            self.exitSignal = signal == 0 ? nil : signal
        }
    }
}

// ---------------------------------------------------------------- view

/// SwiftUI wrapper. Returns the host's existing NSView; never starts or stops the child
/// itself. `dismantleNSView` is deliberately a no-op: a SwiftUI rebuild is not a reason
/// to kill an agent. Removal is an explicit call to `TerminalHost.shutdown()`.
struct TerminalPane: NSViewRepresentable {
    let host: TerminalHost

    /// SwiftUI identifies a representable by its POSITION unless told otherwise. `restart`
    /// and `retarget` replace the TerminalHost in place at the same index, so without an
    /// explicit identity SwiftUI reuses the old NSView: the header would show the new host
    /// while the pane kept displaying a dead terminal. Returning a per-host value forces a
    /// fresh NSView whenever the host object changes, and reuses it otherwise.
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        host.startIfNeeded()
        return host.view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Defence in depth for the same hazard: if SwiftUI ever does hand us a view that
        // belongs to a different host, correct it rather than silently showing the wrong
        // terminal. `host.view` is the authoritative NSView for this pane.
        if nsView !== host.view {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            // Replacing a representable's NSView mid-flight is not supported, so the
            // meaningful action is to make the mismatch visible in development builds
            // rather than pretend it cannot happen.
            assertionFailure("TerminalPane received an NSView from a different host")
        }
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) {
        // Intentionally empty. See the type comment: lifetime belongs to TerminalHost.
    }
}

/// A pane keeps its live native terminal in both the focused and thumbnail layouts.
struct PaneCard: View {
    @Environment(LensStore.self) private var lens
    @ObservedObject var host: TerminalHost
    let isFocused: Bool
    let onFocus: () -> Void
    let onClose: () -> Void
    let onRestart: () -> Void
    var minimized: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // A real terminal view even when minimized. The snapshot optimization was
            // reverted: a view outside the hierarchy does not keep its buffer current, so
            // thumbnails showed stale or blank text while looking authoritative. N live
            // terminal views is what every multiplexer does, and it is always correct.
            //
            // .id(host) is load-bearing: it gives the representable a new identity when
            // restart/retarget swaps the host, so SwiftUI builds a fresh NSView instead of
            // reusing the dead one.
            GeometryReader { bounds in
                // Small previews can clip a vendor's menu choices. Give the CLI a
                // complete screen during startup, then restore the normal text size.
                let fit = minimized && host.goalRole != nil && host.awaitingStartup
                let scale = fit ? max(0.1, min(1, bounds.size.width / 560, bounds.size.height / 320)) : 1
                TerminalPane(host: host).id(ObjectIdentifier(host))
                    .frame(width: bounds.size.width / scale, height: bounds.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
            }
                .background(SwiftUI.Color(nsColor: .textBackgroundColor))
                .contentShape(Rectangle())
                .onTapGesture(perform: onFocus)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(strokeColour, lineWidth: strokeWidth)
        )
        // The rope anchor is the pane's TOP-TRAILING corner. Top-LEADING was the obvious
        // choice and it was wrong: the rope then set off from the left edge and travelled
        // diagonally ACROSS the pane's own terminal text to reach the dock. Anchored on the
        // right edge, the rope leaves into the gutter immediately and never crosses a pane.
        .anchorPreference(key: PaneAnchorKey.self, value: .bounds) { anchor in
            [host.spec.name: anchor]
        }
    }

    /// Blocked panes get an orange border even when unfocused: a stalled agent is more
    /// important to notice than which pane has keyboard focus.
    private var strokeColour: SwiftUI.Color {
        if host.prompt != .none { return .orange }
        return isFocused ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary.opacity(0.25)
    }

    private var strokeWidth: CGFloat {
        if host.prompt != .none { return 2 }
        return isFocused ? 1.5 : 1
    }

    private var header: some View {
        HStack(spacing: minimized ? 4 : 6) {
            // Glyph AND spelled state: colour is never the only signal.
            Text(host.alive ? "●" : "○")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(host.alive ? Color.green : Color.secondary)
            // Identity is the one thing that must survive truncation: a thumbnail whose
            // header reads "cod… run…" cannot be identified. layoutPriority keeps it whole
            // and lets the secondary words shorten instead.
            Text(host.goalRole == nil ? (minimized ? host.spec.name : host.spec.title) : host.spec.name)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .layoutPriority(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(host.spec.displayCommand)
            if let role = host.goalRole, !minimized || host.assignment != nil {
                Text(assignmentLabel ?? (role == .worker ? "Waiting for handoff" : "Planning"))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            if host.alive, let blocked = host.prompt.label {
                // A pane stopped at a prompt must LOOK stopped. Showing "running" here was
                // the bug: the process is alive, so the header said running while nothing
                // was happening, and the lease it held made the orchestrator agree.
                Text(minimized ? host.prompt.glyph : "\(host.prompt.glyph) \(blocked)")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(SwiftUI.Color.orange)
                    .lineLimit(1)
                    .layoutPriority(2)
                    .help("This pane is waiting for input: \(blocked). Nothing is happening until it is answered.")
            } else {
                if !minimized {
                    // In a thumbnail the leading dot already says alive/stopped; a second
                    // dot here read as "● hermes ●" and carried no information.
                    let liveLabel = host.goalRole == nil ? "running" : "CLI open"
                    Text(host.alive ? liveLabel : exitText)
                        .font(.system(.caption2))
                        .foregroundStyle(host.alive ? Color.secondary : Color.orange)
                        .lineLimit(1)
                        .layoutPriority(0)
                }
            }
            Spacer(minLength: 4)
            if let pid = Optional(host.pid), pid > 0, host.alive, !minimized {
                Text("pid \(pid)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if !host.alive, host.goalRole == nil {
                Button("Restart", action: onRestart)
                    .buttonStyle(.link)
                    .font(.caption2)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close this pane and terminate \(host.spec.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var assignmentLabel: String? {
        guard let task = host.assignment?.task else { return nil }
        return lens.snapshot?.node(task)?.taskState == "DONE" ? "\(task) done" : task
    }

    private var exitText: String {
        if let s = host.exitSignal { return "killed (signal \(s))" }
        if let c = host.exitCode { return "exited \(c)" }
        return "stopped"
    }
}

// ---------------------------------------------------------------- anchors

/// Collects each pane's top-leading corner in a shared coordinate space. The grid reads
/// these to place ropes exactly at the pane corners instead of guessing from layout math.
/// Collects each card's BOUNDS in a shared coordinate space.
///
/// A single corner was not enough: a rope must leave from the card's vertical centre, and
/// re-deriving card heights from layout arithmetic drifted from the real frame as soon as
/// the hero lane and the scroll view were introduced.
struct PaneAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}
