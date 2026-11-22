// AgentsStore — which agents are running, in which pane, against which space.
//
// Decisions recorded here rather than asked:
//
//   * Panes SPAWN their agent. Attaching to an already-running CLI is not possible in
//     general (agent CLIs have no attach protocol), so "attach" would be a lie that
//     silently does nothing.
//   * Closing the window terminates the children. Orphaned agent processes that keep
//     writing to a space after the user thinks they are gone are worse than a closed
//     tab: their leases would keep being renewed from a window nobody can see. The
//     window header says so before anything is running.
//   * The roster is persisted, the processes are not. On relaunch the same panes come
//     back but each child is freshly spawned.

import SwiftUI
import AppKit
import RealmLensCore

@MainActor
@Observable
final class AgentsStore {
    /// Live panes, in grid order.
    private(set) var hosts: [TerminalHost] = []
    private(set) var goalHosts: [TerminalHost] = []
    private(set) var showingGoalTerminals = false
    private var goalBridge: String?
    var displayedHosts: [TerminalHost] { showingGoalTerminals ? goalHosts : hosts }
    private var workspaceFocus: String?
    private var goalFocus: String?
    /// The enlarged pane in each group survives switching between them.
    var focused: String? {
        get { showingGoalTerminals ? goalFocus : workspaceFocus }
        set {
            if showingGoalTerminals { goalFocus = newValue } else { workspaceFocus = newValue }
        }
    }
    /// Space every pane is pointed at, via REALM_SPACE. Empty means "inherit cwd search".
    var spacePath: String
    /// Project directory panes start in.
    var workingDirectory: String

    /// True while at least one child is alive. Drives the "closing kills them" warning.
    var anyRunning: Bool { (hosts + goalHosts).contains { $0.alive } }

    private static let rosterKey = "realm.agents.roster"
    private static let specsKey = "realm.agents.specs"
    private static let cwdKey = "realm.agents.cwd"

    init(spacePath: String, workingDirectory: String) {
        self.spacePath = spacePath
        self.workingDirectory = workingDirectory
        // Specs are persisted, not just names: a pane called `claude-reviewer` must come
        // back running `claude`, and a name alone cannot express that.
        self.pendingSpecs = AgentsStore.loadSpecs(workingDirectory: workingDirectory)
        self.workspaceFocus = pendingSpecs.first?.name
    }

    private var pendingSpecs: [AgentSpec]

    private static func loadSpecs(workingDirectory: String) -> [AgentSpec] {
        // A DECODED EMPTY ARRAY MEANS "INTENTIONALLY EMPTY", not "no data yet".
        //
        // This guard used to require !saved.isEmpty, so closing the last pane persisted
        // [] and the next launch fell through to the legacy roster, then to
        // defaultRoster — silently spawning three agents the user had just closed. Absence
        // of stored data is the only thing that may trigger a default.
        if let data = UserDefaults.standard.data(forKey: specsKey),
           let saved = try? JSONDecoder().decode([AgentSpec].self, from: data) {
            // The working directory is a property of the app, not of the saved pane.
            return saved.map { spec in
                var s = spec
                s.workingDirectory = workingDirectory
                return s
            }
        }
        // Migrate a pre-spec roster (an array of names). Each name becomes a preset pane
        // WITH its auto-approve flags: migrating to a bare command would start the CLI
        // un-pre-authorized, and it would exit at its first permission question looking
        // like a crash.
        // Only consult the legacy name array when the specs key is ABSENT. If it exists
        // (even as []), the user has expressed a roster and migration must not override it.
        guard UserDefaults.standard.data(forKey: specsKey) == nil else { return [] }
        // No !names.isEmpty here: an explicitly emptied legacy roster must not resurrect
        // the defaults. Absence of the key is the only signal for "start fresh".
        if let names = UserDefaults.standard.stringArray(forKey: rosterKey) {
            return names.map { name in
                let preset = AgentSpec.preset(name)
                return AgentSpec(name: name,
                                 command: preset?.command ?? name,
                                 arguments: preset?.arguments
                                     ?? AgentSpec.autoApproveArguments(for: name),
                                 workingDirectory: workingDirectory,
                                 harness: name)
            }
        }
        return AgentSpec.defaultRoster.map { spec in
            var s = spec
            s.workingDirectory = workingDirectory
            return s
        }
    }

    // MARK: roster

    /// Spawns any pending panes. Called when the terminals view appears.
    func materialize() {
        guard hosts.isEmpty, !pendingSpecs.isEmpty else { return }
        for spec in pendingSpecs {
            let host = makeHost(spec)
            hosts.append(host)
            // Spawn here, not only in the pane view's makeNSView. A collapsed strip has no
            // terminal view at all, so relying on view creation meant a restored roster
            // came back with panes that had never started a process.
            host.startIfNeeded()
        }
        pendingSpecs = []
        // Write the migrated specs back NOW. Without this the migration re-runs every
        // launch and the stored roster never reflects what is actually running.
        if UserDefaults.standard.data(forKey: Self.specsKey) == nil { persist() }
    }

    private func makeHost(_ spec: AgentSpec) -> TerminalHost {
        // REALM_SPACE is passed explicitly. Without it the child resolves the space by
        // walking up from its cwd, which silently picks the WRONG space whenever the one
        // being read is not an ancestor of the project directory — the agents then work
        // in a different space from the one on screen, and nothing reports the mismatch.
        TerminalHost(spec: spec, spacePath: spacePath)
    }

    /// Adds a pane for a harness under a unique identity.
    ///
    /// The default identity is the harness name, so the first `claude` pane is just
    /// `claude`. A second one becomes `claude-2`, which is what makes two panes of the
    /// same CLI able to hold leases independently instead of silently sharing ownership.
    @discardableResult
    func add(harness harnessName: String, identity requested: String? = nil) -> String? {
        let harness = AgentSpec.preset(harnessName)
        let base = (requested?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? harnessName
        guard let identity = uniqueIdentity(base) else { return nil }

        let spec = AgentSpec(name: identity,
                             command: harness?.command ?? harnessName,
                             arguments: harness?.arguments
                                 ?? AgentSpec.autoApproveArguments(for: harnessName),
                             workingDirectory: workingDirectory,
                             harness: harnessName)
        return openWorkspacePane(spec)
    }

    /// A pane for a command this build has no preset for. No auto-approve flags are added,
    /// because guessing another CLI's flag would turn a launch into a crash.
    @discardableResult
    func addCustom(command: String, identity requested: String?) -> String? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return nil }
        // First word is the executable; the rest are arguments, so "+ custom" can express
        // `aider --model x` without a preset existing.
        let parts = cmd.split(separator: " ").map(String.init)
        let executable = parts.first ?? cmd
        let base = (requested?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? executable
        guard let identity = uniqueIdentity(base) else { return nil }
        let spec = AgentSpec(name: identity, command: executable,
                             arguments: Array(parts.dropFirst()),
                             workingDirectory: workingDirectory, harness: executable)
        return openWorkspacePane(spec)
    }

    private func openWorkspacePane(_ spec: AgentSpec) -> String {
        let host = makeHost(spec)
        hosts.append(host)
        showingGoalTerminals = false
        workspaceFocus = spec.name
        host.startIfNeeded()
        persist()
        return spec.name
    }

    /// A name no live pane is using. REALM_AGENT is the lease identity, so duplicates are
    /// not a cosmetic problem: two panes sharing one name share ownership of every lease.
    private func uniqueIdentity(_ base: String) -> String? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let taken = Set(hosts.map(\.spec.name)).union(pendingSpecs.map(\.name))
        if !taken.contains(trimmed) { return trimmed }
        for n in 2...99 {
            let candidate = "\(trimmed)-\(n)"
            if !taken.contains(candidate) { return candidate }
        }
        return nil
    }

    func remove(_ name: String) {
        if showingGoalTerminals {
            guard let i = goalHosts.firstIndex(where: { $0.spec.name == name }) else { return }
            goalHosts.remove(at: i).shutdown()
            if goalFocus == name { goalFocus = goalHosts.first?.spec.name }
            if goalHosts.isEmpty { showingGoalTerminals = false }
            return
        }
        guard let idx = hosts.firstIndex(where: { $0.spec.name == name }) else { return }
        let host = hosts.remove(at: idx)
        host.shutdown()
        if workspaceFocus == name {
            workspaceFocus = hosts.first?.spec.name
        }
        persist()
    }

    func restart(_ name: String) {
        guard let host = hosts.first(where: { $0.spec.name == name }) else { return }
        host.shutdown()
        // A LocalProcessTerminalView cannot be restarted after its IO is closed, so a
        // restart replaces the host in place, preserving grid order.
        guard let idx = hosts.firstIndex(where: { $0.spec.name == name }) else { return }
        let fresh = makeHost(host.spec)
        hosts[idx] = fresh
        fresh.startIfNeeded()
        workspaceFocus = name
    }

    /// Terminates every child. Idempotent; safe from `applicationWillTerminate`.
    private func shutdownAll() {
        for h in hosts { h.shutdown() }
        for h in goalHosts { h.shutdown(reportAbandonedAssignment: false) }
    }

    /// Terminates every child AND forgets the panes, so the next `materialize()` spawns
    /// fresh ones. Used when the window closes: the roster survives in UserDefaults, the
    /// processes do not.
    func closeAll() {
        shutdownAll()
        hosts = []
        goalHosts = []
        goalBridge = nil
        goalFocus = nil
        showingGoalTerminals = false
        pendingSpecs = AgentsStore.loadSpecs(workingDirectory: workingDirectory)
        workspaceFocus = pendingSpecs.first?.name
    }

    /// Retarget every pane at a new space. Existing children keep their environment, so
    /// they must be restarted; a pane writing to the previous space while the window shows
    /// the new one is exactly the invisible-divergence failure this app exists to prevent.
    func retarget(spacePath: String, workingDirectory: String) {
        let changed = spacePath != self.spacePath || workingDirectory != self.workingDirectory
        self.spacePath = spacePath
        self.workingDirectory = workingDirectory
        guard changed else { return }
        for h in goalHosts { h.shutdown(reportAbandonedAssignment: false) }
        goalHosts = []
        goalBridge = nil
        goalFocus = nil
        showingGoalTerminals = false

        // PENDING specs must be retargeted too. Retargeting before the terminals view ever
        // appeared is the normal case (the window opens on the graph), and the pending
        // specs carry the OLD working directory. Without this, materialize() would spawn
        // panes pointed at space B but started in directory A.
        pendingSpecs = pendingSpecs.map { spec in
            var s = spec
            s.workingDirectory = workingDirectory
            return s
        }
        // Persist what actually represents the roster. Persisting hosts only would write []
        // while the panes are still pending, erasing the roster on the next launch.
        if hosts.isEmpty {
            persistPending()
        } else {
            persist()
        }

        guard !hosts.isEmpty else { return }
        let specs = hosts.map(\.spec)
        for h in hosts { h.shutdown() }
        hosts = specs.map { spec in
            var s = spec
            s.workingDirectory = workingDirectory
            return makeHost(s)
        }
        for h in hosts { h.startIfNeeded() }
    }

    /// Persist the pending roster. Used when a space switch happens before the panes exist.
    private func persistPending() {
        if let data = try? JSONEncoder().encode(pendingSpecs) {
            UserDefaults.standard.set(data, forKey: AgentsStore.specsKey)
        }
        UserDefaults.standard.set(pendingSpecs.map(\.name), forKey: AgentsStore.rosterKey)
        UserDefaults.standard.set(workingDirectory, forKey: AgentsStore.cwdKey)
    }

    private func persist() {
        // Persist full specs so identities, harnesses and arguments all survive a restart.
        let specs = hosts.map(\.spec)
        if let data = try? JSONEncoder().encode(specs) {
            UserDefaults.standard.set(data, forKey: AgentsStore.specsKey)
        }
        // Keep the legacy name array in sync for anything still reading it.
        UserDefaults.standard.set(specs.map(\.name), forKey: AgentsStore.rosterKey)
        UserDefaults.standard.set(workingDirectory, forKey: AgentsStore.cwdKey)
    }

    // MARK: leases

    func toggleTerminalGroup() {
        guard !goalHosts.isEmpty else { return }
        showingGoalTerminals.toggle()
    }

    func deliver(_ request: GoalTerminalRequest, planner: String, workers: [String], fullAccess: Bool) {
        if request.role == .orchestrator {
            guard request.agent == planner, request.bridge != goalBridge else {
                request.fail("Unexpected orchestrator request"); return
            }
            for host in goalHosts { host.shutdown(reportAbandonedAssignment: false) }
            goalHosts = []
            goalBridge = request.bridge
            let runID = String(request.run.dropFirst("run-".count))
            let team: [(String, GoalRole)] = [(planner, .orchestrator)] + workers.map { ($0, .worker) }
            for (agent, role) in team {
                guard let preset = AgentSpec.preset(agent),
                      let label = OrchestrationRun.Agent(rawValue: agent)?.label else { continue }
                let spec = AgentSpec(name: "\(label) · \(role.label)", command: preset.command,
                                     arguments: fullAccess ? preset.arguments : [], workingDirectory: workingDirectory, harness: agent)
                let isPlanner = role == .orchestrator
                let host = TerminalHost(spec: spec, spacePath: spacePath, role: role,
                                        identity: isPlanner ? request.identity : "\(agent)/\(runID)",
                                        assignment: isPlanner ? request : nil, fullAccess: fullAccess)
                goalHosts.append(host)
                host.startIfNeeded()
            }
            showingGoalTerminals = true
            goalFocus = goalHosts.first?.spec.name
        } else {
            guard goalBridge == request.bridge,
                  let host = goalHosts.first(where: { $0.goalRole == .worker && $0.realmIdentity == request.identity }) else {
                request.fail("The \(request.agent) worker pane was closed"); return
            }
            host.sendAssignment(request)
        }
    }

    func finishGoal(bridge: String, canceled: Bool) {
        guard bridge == goalBridge, canceled else { return }
        for host in goalHosts { host.shutdown(reportAbandonedAssignment: false) }
    }

    /// Which agent holds a live lease, from the space snapshot. This is the only thing
    /// the ropes need: they are a view of the space, not of the process table.
    func leaseMap(from leases: [RealmLease], now: Int) -> [String: (resource: String, remaining: Int, live: Bool)] {
        var out: [String: (String, Int, Bool)] = [:]
        for l in leases {
            guard let owner = l.owner else { continue }
            let key = displayedHosts.first { $0.realmIdentity == owner }?.spec.name ?? owner
            let exp = l.expiresAt ?? 0
            let remaining = max(0, exp - now)
            // Keep the worst case per owner so an agent with one expiring lease is not
            // shown as comfortably active because of another long one.
            if let existing = out[key], existing.1 <= remaining { continue }
            out[key] = (l.resource, remaining, exp > now)
        }
        return out
    }
}
