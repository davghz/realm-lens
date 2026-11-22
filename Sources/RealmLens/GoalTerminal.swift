import Foundation

enum GoalRole: String, Decodable {
    case orchestrator, worker
    var label: String { self == .orchestrator ? "Orchestrator" : "Worker" }
}

struct GoalTerminalRequest: Decodable {
    let bridge: String
    let role: GoalRole
    let agent: String
    let identity: String
    let task: String
    let run: String
    let title: String
    let directory: String

    var folder: URL { URL(fileURLWithPath: directory, isDirectory: true) }
    var prompt: String {
        let summary = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "Realm \(role.label), \(task): \(summary.prefix(650)). Read \(folder.appendingPathComponent("assignment.txt").path) now, carry out that assignment, and submit the requested JSON to \(folder.appendingPathComponent("reply.json").path)."
    }

    func fail(_ message: String) {
        let errorFile = folder.appendingPathComponent("error.txt")
        guard FileManager.default.fileExists(atPath: folder.path),
              !FileManager.default.fileExists(atPath: errorFile.path),
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent("reply.json").path)
        else { return }
        try? message.write(to: errorFile, atomically: true, encoding: .utf8)
    }
}

/// Match the startup menu and its selected row on the rendered TUI, so a redraw
/// or a change in the default choice cannot turn Return into "No, exit".
struct GoalStartupChoice: Equatable {
    let dialog: String
    let keys: [UInt8]
}

struct GoalTerminalScreen {
    let harness: String
    let rows: [String]
    let text: String

    init(lines: [String], harness: String) {
        self.harness = harness
        rows = lines.map {
            $0.replacingOccurrences(of: "\0", with: " ").lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        text = rows.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var startupChoice: GoalStartupChoice? {
        let label: String
        let accept: String
        if harness == "agy", text.contains("auto is now the default"), text.contains("esc to dismiss") {
            return GoalStartupChoice(dialog: "agent mode notice", keys: [27])
        } else if harness == "claude", text.contains("bypass permissions mode"), text.contains("yes, i accept") {
            label = "full access"
            accept = "yes, i accept"
        } else if ["claude", "agy", "codex"].contains(harness),
                  text.contains("trust this folder") || text.contains("trust and continue") {
            label = "workspace trust"
            accept = text.contains("yes, i trust this folder") ? "yes, i trust this folder" : "trust and continue"
        } else { return nil }
        guard let positive = rows.firstIndex(where: { $0.contains(accept) }),
              let negative = rows.firstIndex(where: { $0.contains("no, exit") || $0.contains("back to agent command") }),
              positive != negative else { return nil }
        let markers: Set<Character> = [">", "›", "❯", "→"]
        func selected(_ row: Int) -> Bool { rows[row].first.map(markers.contains) ?? false }
        if selected(positive) { return GoalStartupChoice(dialog: label, keys: [13]) }
        if selected(negative) { return GoalStartupChoice(dialog: label, keys: [27, 91, positive > negative ? 66 : 65]) }
        return nil
    }

    var readyForAssignment: Bool {
        guard startupChoice == nil, quotaMessage == nil else { return false }
        switch harness {
        case "claude": return text.contains("bypass permissions on") || text.contains("for shortcuts")
        case "codex": return text.contains("for shortcuts") || text.contains("for agents") || text.contains("ask codex")
        case "agy": return text.contains("for shortcuts") || text.contains("auto mode:") || text.contains("agent mode in /config")
        case "opencode": return text.contains("ctrl+p commands") || text.contains("ask anything")
        default: return true
        }
    }

    var quotaMessage: String? {
        if harness == "agy", text.contains("individual quota reached"),
           text.contains("please upgrade your subscription") || text.contains("resets in") {
            return "Antigravity reported its individual usage limit. See the Antigravity terminal for the reset time."
        }
        guard harness == "claude",
              text.contains("you've hit your weekly limit") || text.contains("you’ve hit your weekly limit"),
              text.contains("resets") || text.contains("/rate-limit-options") else { return nil }
        return "Claude Code reported its weekly usage limit. See the Claude terminal for the reset time."
    }
}
