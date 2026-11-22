// RealmLens — the app.
//
// Reads realm spaces and runs orchestrated goals through the realm CLI.
//
// Two scenes: a MenuBarExtra for ambient presence ("is it working / is it stuck") and a
// Window for the graph ("what does the space believe"). The window is opened on demand
// and closing it must not quit the app.

import SwiftUI
import AppKit
import RealmLensCore

@main
struct RealmLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = LensStore()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            PulsePanel()
                .environment(store)
        } label: {
            // Glyph plus counts, never colour alone.
            Text(store.menuBarLabel)
                .onReceive(NotificationCenter.default.publisher(for: .realmShowLens)) { _ in
                    openWindow(id: "lens")
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .menuBarExtraStyle(.window)

        Window("Realm Lens", id: "lens") {
            LensWindow()
                .environment(store)
                .onAppear { store.windowVisible = true }
                .onDisappear {
                    // Closing the window ends the session's processes. Switching between
                    // the Graph and Terminals tabs does not go through here, so panes
                    // survive tab changes and only die with the window.
                    store.closeWindowSession()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

extension Notification.Name {
    /// Posted at launch when `--show-window` is passed. A Window scene cannot be created from
    /// the app delegate because SwiftUI has not registered it yet; openWindow() from a view
    /// context is the only supported path.
    static let realmShowLens = Notification.Name("realm.showLens")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The SwiftUI scene graph is not built yet at didFinishLaunching, so retry briefly.
        // `--show-window` is for smoke tests and for anyone who wants the graph immediately.
        guard CommandLine.arguments.contains("--show-window") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            NotificationCenter.default.post(name: .realmShowLens, object: nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A second `open` re-activates the running app instead of launching it again, so the
    /// `--show-window` argument is not delivered a second time. Without this, closing the
    /// window left the only route back as the menu bar item.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .realmShowLens, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// The only place children are guaranteed to be reaped on quit. SwiftUI does not
    /// deallocate the window's views predictably on terminate, and `deinit` on a view
    /// that holds a live PTY is not something to rely on for process hygiene.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            LensStore.shared?.closeWindowSession()
        }
    }

    /// Closing the window kills the agents. That is a deliberate decision, stated in the
    /// UI: an agent whose window is gone can keep renewing leases and writing nodes that
    /// nobody is watching. Visibility beats convenience here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            LensStore.shared?.closeWindowSession()
        }
        return .terminateNow
    }
}

// ---------------------------------------------------------------- store

/// Observable view-model. Polls the reader on a background task and publishes immutable
/// snapshots to the UI. The clock ticks separately so ages update without invalidating
/// the graph.
@MainActor
@Observable
final class LensStore {
    /// Weak global handle for terminate-time cleanup only. The UI keeps using the
    /// environment; this exists because `applicationWillTerminate` has no access to it.
    static weak var shared: LensStore?

    /// The agent roster lives beside the reader, not inside it: the reader is frozen and
    /// qualified, and spawning processes is not a read.
    var agents: AgentsStore?
    let orchestration = OrchestrationRun()

    var snapshot: SpaceSnapshot?
    var errorText: String?
    var spacePath: String?
    var windowVisible = false
    var clock: Int = Int(Date().timeIntervalSince1970)
    var lastPollMillis: Double = 0

    private var pollTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var lastCursor: Int?
    /// Bumped on every space switch. A poll in flight compares this after its await and
    /// discards its result if it no longer matches — otherwise space A's data lands under
    /// space B's header.
    private var generation: Int = 0

    init() {
        let stored = UserDefaults.standard.string(forKey: "realm.spacePath")
        if let path = stored ?? ProcessInfo.processInfo.environment["REALM_SPACE"], !path.isEmpty {
            let space = URL(fileURLWithPath: path, isDirectory: true)
            spacePath = space.path
            agents = AgentsStore(spacePath: space.path, workingDirectory: space.deletingLastPathComponent().path)
        }
        LensStore.shared = self
        start()
    }

    func closeWindowSession() {
        windowVisible = false
        orchestration.cancel()
        agents?.closeAll()
    }

    // MARK: status

    var nodes: [RealmNode] { snapshot?.nodes ?? [] }
    var leases: [RealmLease] { snapshot?.leases ?? [] }

    var liveLeases: [RealmLease] {
        let now = clock
        return leases.filter { $0.isLive(now: now) }
    }
    var staleLeases: [RealmLease] {
        let now = clock
        return leases.filter { $0.isStale(now: now) }
    }

    /// Counts by the node's OWN status, so a fact is never double-counted as TAINTED
    /// instead of UNVERIFIED. Taint and blocking are overlays, reported separately.
    var counts: [String: Int] {
        var c: [String: Int] = [:]
        for n in nodes {
            let s = rawStatus(n)
            if n.kind == .task || n.kind == .fact { c[s, default: 0] += 1 }
        }
        return c
    }

    /// The node's own status, ignoring derived overlays.
    func rawStatus(_ n: RealmNode) -> String {
        switch n.kind {
        case .fact: return n.factStatus.isEmpty ? "UNVERIFIED" : n.factStatus
        case .task: return n.taskState.isEmpty ? "OPEN" : n.taskState
        case .decision: return "ACTIVE"
        case .artifact: return "PRESENT"
        case .attempt: return n.exitCode == 0 ? "OK" : "FAILED"
        }
    }

    /// Worst status present, drives the menu bar symbol.
    var worstStatus: String {
        let c = counts
        for s in ["REFUTED", "CONTESTED", "BLOCKED", "TAINTED", "UNVERIFIED", "OPEN"] where (c[s] ?? 0) > 0 {
            return s
        }
        return "VERIFIED"
    }

    var menuBarLabel: String {
        if errorText != nil { return "◌ realm" }
        let c = counts
        let tainted = nodes.filter(\.tainted).count
        let leased = liveLeases.count
        var parts: [String] = []
        if let v = c["VERIFIED"], v > 0 { parts.append("✓\(v)") }
        // UNVERIFIED is drawn from the raw fact status, not statusText: statusText
        // returns TAINTED/BLOCKED for the same node, which swallowed the count entirely.
        let unverified = nodes.filter { $0.kind == .fact && $0.factStatus == "UNVERIFIED" }.count
        if unverified > 0 { parts.append("?\(unverified)") }
        if let r = c["REFUTED"], r > 0 { parts.append("✗\(r)") }
        if tainted > 0 { parts.append("!\(tainted)") }
        if leased > 0 { parts.append("@\(leased)") }
        return parts.isEmpty ? "◌ realm" : "realm " + parts.joined(separator: " ")
    }

    func statusText(_ n: RealmNode) -> String {
        if n.tainted { return "TAINTED" }
        if !n.blockedBy.isEmpty { return "BLOCKED" }
        switch n.kind {
        case .fact: return n.factStatus.isEmpty ? "UNVERIFIED" : n.factStatus
        case .task: return n.taskState.isEmpty ? "OPEN" : n.taskState
        case .decision: return "ACTIVE"
        case .artifact: return "PRESENT"
        case .attempt: return n.exitCode == 0 ? "OK" : "FAILED"
        }
    }

    func glyph(_ n: RealmNode) -> String {
        switch statusText(n) {
        case "VERIFIED", "DONE": return "✓"
        case "REFUTED": return "✗"
        case "CONTESTED": return "!"
        case "TAINTED": return "!"
        case "BLOCKED": return "B"
        default: return "·"
        }
    }

    // MARK: polling

    func start() {
        pollTask?.cancel()
        clockTask?.cancel()
        pollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(2), tolerance: .milliseconds(400))
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let self { self.clock = Int(Date().timeIntervalSince1970) }
            }
        }
    }

    func setSpace(_ url: URL) {
        generation &+= 1          // invalidate any in-flight poll
        if spacePath != url.path { orchestration.spaceChanged() }
        spacePath = url.path
        UserDefaults.standard.set(url.path, forKey: "realm.spacePath")
        lastCursor = nil
        snapshot = nil
        errorText = nil
        // Selection is namespaced by space: T001 may exist in both with different meaning.
        selection = nil
        // Panes are retargeted explicitly: their environment is fixed at spawn time, so
        // an agent would otherwise keep writing to the previous space while the window
        // shows the new one.
        let projectDir = url.deletingLastPathComponent().path
        if let agents {
            agents.retarget(spacePath: url.path, workingDirectory: projectDir)
        } else {
            agents = AgentsStore(spacePath: url.path, workingDirectory: projectDir)
        }
    }

    /// Currently inspected node id. Cleared on space switch.
    var selection: String?

    private func pollOnce() async {
        guard let path = self.spacePath else { return }
        let myGen = generation
        let url = URL(fileURLWithPath: path)
        let result: Result<SpaceSnapshot, Error> = await Task.detached(priority: .utility) {
            do { return .success(try RealmReader.load(spaceDirectory: url, eventTail: 120)) }
            catch { return .failure(error) }
        }.value

        await MainActor.run {
            // The space may have changed while we were reading. Discard BOTH outcomes:
            // a stale error under a new space's header is as wrong as stale data.
            guard self.generation == myGen else { return }
            switch result {
            case .success(let snap):
                self.snapshot = snap
                self.errorText = nil
                self.lastPollMillis = snap.readMillis
                self.lastCursor = snap.cursor
            case .failure(let e):
                self.snapshot = nil
                if let se = e as? SpaceError {
                    self.errorText = se.description
                } else {
                    self.errorText = "\(e)"
                }
            }
        }
    }

    /// New events since the last poll, for the "changed" line.
    func recentlyChanged() -> (count: Int, partial: Bool) {
        guard let snap = snapshot else { return (0, false) }
        let r = snap.changed(since: lastCursor.map { $0 - 1 })
        return (r.events.count, r.partial)
    }
}
