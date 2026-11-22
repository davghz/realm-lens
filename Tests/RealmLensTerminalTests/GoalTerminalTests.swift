import XCTest
@testable import RealmLens

final class GoalTerminalTests: XCTestCase {
    func testTrustAndBypassFollowTheSelectedRow() {
        func keys(_ agent: String, _ lines: [String]) -> [UInt8]? {
            GoalTerminalScreen(lines: lines, harness: agent).startupChoice?.keys
        }
        XCTAssertEqual(keys("claude", ["Is this a project you trust?", "❯ No, exit", "Yes, I trust this folder"]), [27, 91, 66])
        XCTAssertEqual(keys("claude", ["WARNING: Running in Bypass Permissions mode", "No, exit", " ❯ Yes, I accept"]), [13])
        XCTAssertEqual(keys("agy", ["Do you trust the contents of this project?", "Yes, I trust this folder", "> No, exit"]), [27, 91, 65])
        XCTAssertEqual(keys("agy", ["Do you trust the contents of this project?", "› Yes, I trust this folder", "No, exit"]), [13])
        XCTAssertEqual(keys("codex", ["Trust this folder?", "> 1. Trust and continue", "2. Back to Agent Command"]), [13])
        XCTAssertNil(keys("claude", ["Bypass Permissions mode", "No, exit", "Yes, I accept"]))
        XCTAssertNil(keys("claude", ["Do you want to allow this command?", "> Yes, I accept", "No, exit"]))
    }

    func testReadinessAndQuotaAreSeparateFromConfirmation() {
        let ready = GoalTerminalScreen(lines: [" » bypass permissions on (shift+tab to cycle)"], harness: "claude")
        XCTAssertTrue(ready.readyForAssignment)
        XCTAssertNil(ready.startupChoice)
        let notice = GoalTerminalScreen(lines: ["Auto is now the default agent mode", "esc to dismiss"], harness: "agy")
        XCTAssertEqual(notice.startupChoice?.keys, [27])
        XCTAssertFalse(notice.readyForAssignment)
        let limit = GoalTerminalScreen(lines: ["You've hit your weekly limit · resets Nov 24 at 3pm", "/rate-limit-options", "> Add funds", "? for shortcuts"], harness: "claude")
        XCTAssertNotNil(limit.quotaMessage)
        XCTAssertNil(limit.startupChoice)
        XCTAssertFalse(limit.readyForAssignment)
        XCTAssertNil(GoalTerminalScreen(lines: ["The weekly limit is mentioned in this file"], harness: "claude").quotaMessage)
        let agyLimit = GoalTerminalScreen(lines: ["⚠ Individual quota reached. Please upgrade your",
                                                  "subscription to increase your limits. Resets in 135h4m35s.",
                                                  "? for shortcuts"], harness: "agy")
        XCTAssertNotNil(agyLimit.quotaMessage)
        XCTAssertFalse(agyLimit.readyForAssignment)
        XCTAssertNil(GoalTerminalScreen(lines: ["Antigravity Starter Quota", "? for shortcuts"], harness: "agy").quotaMessage)
    }

    @MainActor
    func testWindowCancellationAndIndividualPaneClosureReportDistinctOutcomes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let assignment = GoalTerminalRequest(bridge: "test", role: .worker, agent: "codex", identity: "codex/test",
                                             task: "T002", run: "run-test", title: "Check the page", directory: folder.path)
        let spec = AgentSpec(name: "Codex · Worker", command: "/bin/cat", arguments: [], workingDirectory: folder.path, harness: "codex")
        let error = folder.appendingPathComponent("error.txt")

        let canceled = TerminalHost(spec: spec, role: .worker, assignment: assignment)
        canceled.shutdown(reportAbandonedAssignment: false)
        canceled.processTerminated(source: canceled.view, exitCode: 15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: error.path))

        let closed = TerminalHost(spec: spec, role: .worker, assignment: assignment)
        closed.shutdown()
        closed.processTerminated(source: closed.view, exitCode: 15)
        assignment.fail("A later exit notification")
        XCTAssertEqual(try String(contentsOf: error, encoding: .utf8), "codex terminal closed before submitting T002")
    }
}
