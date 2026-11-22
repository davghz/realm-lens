// Headless probe for the PTY layer. Compiles the real TerminalPane.swift (no GUI, no
// RealmLensCore) and asserts the three lifecycle claims that matter:
//
//   1. a child actually runs and its REALM_AGENT is visible to it
//   2. shutdown() terminates the child (and anything it spawned in its session)
//   3. shutdown() is idempotent and safe after the child already exited
//
// Compile with TerminalPane.swift and PromptWatch.swift, linking SwiftTerm.
// This is a smoke harness, not a test suite: the app target has no XCTest bundle.

import AppKit

@MainActor
func runProbe() -> Int32 {
    var failures = 0
    func check(_ cond: Bool, _ label: String, _ detail: String = "") {
        print(cond ? "  PASS  \(label)" : "  FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        if !cond { failures += 1 }
    }

    // ---- 1. child runs, env is correct
    print("1. spawn + REALM_AGENT")
    let dir = NSTemporaryDirectory() + "realm-pty-probe"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let outFile = dir + "/env.txt"
    try? FileManager.default.removeItem(atPath: outFile)

    let spec = AgentSpec(name: "reviewer", command: "/bin/sh",
                         arguments: ["-c", "echo \"$REALM_AGENT:$REALM_TERMINAL\" > \(outFile); sleep 60"],
                         workingDirectory: dir)
    let host = TerminalHost(spec: spec)
    check(host.pid == 0, "pid is 0 before start")
    host.startIfNeeded()

    var waited = 0.0
    while waited < 5.0 && !FileManager.default.fileExists(atPath: outFile) {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        waited += 0.05
    }
    let envText = (try? String(contentsOfFile: outFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    check(envText == "reviewer:realm-lens", "child sees REALM_AGENT and REALM_TERMINAL", "got \(envText.debugDescription)")
    check(host.pid > 0, "pid assigned after start", "pid=\(host.pid)")
    check(host.alive, "host reports alive while child runs")

    // startIfNeeded must not spawn a second child.
    let firstPid = host.pid
    host.startIfNeeded()
    check(host.pid == firstPid, "startIfNeeded is idempotent", "\(firstPid) -> \(host.pid)")

    // ---- 2. shutdown kills it
    print("2. shutdown terminates")
    let pid = host.pid
    host.shutdown()
    var reaped = false
    for _ in 0..<100 {
        // kill(pid, 0) == 0 means it still exists; ESRCH means gone.
        if kill(pid, 0) != 0 { reaped = true; break }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check(reaped, "child pid \(pid) is gone after shutdown")
    check(!host.alive, "host reports not alive")

    // ---- 3. idempotent + safe
    print("3. idempotent shutdown")
    host.shutdown()
    check(true, "second shutdown does not trap")

    // A child that exits on its own must not be killed twice or reported as running.
    let quick = AgentSpec(name: "quick", command: "/bin/sh",
                          arguments: ["-c", "exit 7"], workingDirectory: dir)
    let h2 = TerminalHost(spec: quick)
    h2.startIfNeeded()
    var done = false
    for _ in 0..<100 {
        if !h2.alive { done = true; break }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check(done, "self-exiting child is observed as stopped")
    check(h2.exitCode == 7, "exit code captured", "got \(String(describing: h2.exitCode))")
    h2.shutdown()
    check(true, "shutdown after natural exit does not trap")

    print(failures == 0 ? "\nALL PROBES PASS" : "\n\(failures) PROBE(S) FAILED")
    return failures == 0 ? 0 : 1
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let code = MainActor.assumeIsolated { runProbe() }
exit(code)
