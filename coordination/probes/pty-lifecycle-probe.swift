import SwiftUI
import AppKit
import SwiftTerm

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var failures = 0
func check(_ ok: Bool, _ l: String, _ d: String = "") {
    print(ok ? "  PASS  \(l)" : "  FAIL  \(l)\(d.isEmpty ? "" : " — \(d)")")
    if !ok { failures += 1 }
}
func state(_ p: pid_t) -> String {
    let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/bin/ps")
    pr.arguments = ["-o", "stat=", "-p", "\(p)"]
    let o = Pipe(); pr.standardOutput = o; pr.standardError = FileHandle.nullDevice
    try? pr.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); pr.waitUntilExit()
    return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func alive(_ p: pid_t) -> Bool { let s = state(p); return !s.isEmpty && s != "Z" }
func pump(_ n: Int) { for _ in 0..<n { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) } }
/// Launches a detached process and returns its pid. stdout is /dev/null so a backgrounded
/// child never inherits a pipe that would block a later read.
func detach(_ script: String) -> pid_t {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "( \(script) ) >/dev/null 2>&1 & echo $!"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return pid_t(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

print("A. leader exits first; stubborn helper must still die")
let pf = "/tmp/lc2/helper.pid"
try? FileManager.default.removeItem(atPath: pf)
let sA = """
trap '' TERM
( trap '' TERM; sleep 300 ) &
echo $! > \(pf)
exit 0
"""
let hA = TerminalHost(spec: AgentSpec(name: "lf", command: "/bin/sh",
                        arguments: ["-c", sA], workingDirectory: "/tmp/lc2"), spacePath: "")
hA.startIfNeeded(); pump(50)
check(!hA.alive, "leader observed as exited")
let helperA = (try? String(contentsOfFile: pf, encoding: .utf8))
    .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
if let helperA, helperA > 0 {
    var gone = false
    for _ in 0..<60 { if !alive(helperA) { gone = true; break }; pump(2) }
    check(gone, "helper killed after leader's natural exit", state(helperA))
    if !gone { _ = detach("kill -9 \(helperA)") }
} else { check(false, "helper pid captured") }
hA.shutdown()

print("B. shutdown of a live pane tears down its group")
let bf = "/tmp/lc2/b.pid"
try? FileManager.default.removeItem(atPath: bf)
let hB = TerminalHost(spec: AgentSpec(name: "live", command: "/bin/sh",
                        arguments: ["-c", "( trap '' TERM; sleep 300 ) & echo $! > \(bf); wait"],
                        workingDirectory: "/tmp/lc2"), spacePath: "")
hB.startIfNeeded(); pump(30)
check(hB.alive, "pane alive before shutdown")
let bHelper = (try? String(contentsOfFile: bf, encoding: .utf8))
    .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
let t0 = Date(); hB.shutdown()
if let bHelper, bHelper > 0 {
    var gone = false
    for _ in 0..<80 { if !alive(bHelper) { gone = true; break }; pump(2) }
    check(gone, "stubborn helper died on shutdown", state(bHelper))
    if !gone { _ = detach("kill -9 \(bHelper)") }
} else { check(false, "helper pid captured") }
print(String(format: "      shutdown took %.2fs", Date().timeIntervalSince(t0)))
check(!hB.alive, "pane reports stopped")
hB.shutdown(); check(true, "second shutdown is a no-op")

print("C. a dead pane's shutdown signals no stranger")
let bpid = detach("exec sleep 300")
check(alive(bpid), "bystander up (pid \(bpid))", state(bpid))
let hC = TerminalHost(spec: AgentSpec(name: "q", command: "/bin/sh",
                        arguments: ["-c", "exit 4"], workingDirectory: "/tmp/lc2"), spacePath: "")
hC.startIfNeeded(); pump(40)
check(!hC.alive && hC.exitCode == 4, "quick child exited 4")
hC.shutdown(); pump(10)
check(alive(bpid), "bystander untouched by dead-pane shutdown", state(bpid))
_ = detach("kill -9 \(bpid)")

print("D. prompt detection")
func feed(_ t: String) -> PanePrompt {
    let w = PromptWatch(); w.ingest(Array(t.utf8)[...]); return w.prompt
}
check(feed("Update available · 0.167.0 → 0.167.1\n1. Update now\n2. Skip\n") == .update(version: nil), "update prompt")
check(feed("Is this a project you created or one you trust?\n> No, exit\n  Yes, I trust this folder\n") == .trust, "trust dialog")
check(feed("Do you want to allow this command?\n") == .permission, "permission prompt")
check(feed("> build the thing\n\n⏺ Working on T001...\n") == .none, "normal output is not a prompt")
check(feed("\u{1B}[1mUpdate available\u{1B}[0m\n\u{1B}[32m1. Update now\u{1B}[0m\n") == .update(version: nil), "detected through ANSI")
let w2 = PromptWatch()
w2.ingest(Array("Update available\n1. Update now\n2. Skip\n".utf8)[...])
check(w2.prompt != .none, "prompt set")
w2.ingest(Array(String(repeating: "\nworking...\n", count: 40).utf8)[...])
check(w2.prompt == .none, "prompt clears when output resumes")

print(failures == 0 ? "\nALL PROBES PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
