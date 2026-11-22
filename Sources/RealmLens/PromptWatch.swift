// PromptWatch — detects when an agent CLI is stopped waiting for a human.
//
// Why this exists: pre-authorizing permissions (`--dangerously-skip-permissions` and
// friends) removes the *permission* prompts, but two other blockers remain and both look
// exactly like a working pane from the outside:
//
//   * an UPDATE prompt ("Update available ... 1. Update now  2. Skip")
//   * a first-run WORKSPACE TRUST dialog ("Is this a project you created or one you
//     trust?")
//
// A blocked pane still holds its lease and still looks busy in the roster, so the
// orchestrator reports an agent as working while nothing is happening. That is the same
// silent-divergence failure the ropes were built to prevent, one level down.
//
// Detection is deliberately conservative. A false positive is worse than a miss here: it
// would tell the user to intervene in a pane that is fine, and they would stop trusting
// the flag. Patterns are matched against the tail of the output only, and only when the
// process has produced NO output since — a busy pane clears the flag on its next write.

import Foundation
import SwiftTerm

/// What a pane appears to be waiting for.
enum PanePrompt: Equatable {
    case none
    case update(version: String?)
    case trust
    case permission

    var label: String? {
        switch self {
        case .none: return nil
        case .update(let v): return v.map { "update \($0)" } ?? "update prompt"
        case .trust: return "trust prompt"
        case .permission: return "permission prompt"
        }
    }

    /// One glyph plus a word. Colour is never the only signal, and the header has room
    /// for about this much before it starts truncating.
    var glyph: String {
        switch self {
        case .none: return ""
        case .update: return "↑"
        case .trust: return "?"
        case .permission: return "!"
        }
    }
}

/// Watches a PTY output stream for signs that a CLI has stopped to ask something.
///
/// Not thread-safe by design: it is only fed from the terminal's data callback, which
/// SwiftTerm delivers on a single queue.
final class PromptWatch {
    /// How much recent output to consider. Prompts are multi-line but never long.
    private static let tailLimit = 4096

    private var tail = ""
    /// Set when output stopped right after a recognised prompt.
    private(set) var prompt: PanePrompt = .none
    /// Tail offset before which text predates the last cleared prompt and must NOT be
    /// treated as evidence of a current one. Clearing `prompt` alone was not enough:
    /// detection then re-scanned the whole tail, found the same old menu, and re-flagged
    /// it immediately. The floor is what makes the clear stick.
    private var detectFloor = 0
    /// Offset just past the text that produced the current prompt. Anything after this is
    /// newer than the prompt and therefore evidence that it was answered.
    private var promptEnd = 0

    /// Feed freshly received bytes.
    func ingest(_ slice: ArraySlice<UInt8>) {
        guard !slice.isEmpty else { return }
        tail.append(String(decoding: slice, as: UTF8.self))
        if tail.count > Self.tailLimit {
            let dropped = tail.count - Self.tailLimit
            tail = String(tail.suffix(Self.tailLimit))
            // Offsets are into `tail`, so they move with it.
            detectFloor = max(0, detectFloor - dropped)
            promptEnd = max(0, promptEnd - dropped)
        }

        if prompt != .none {
            // A prompt clears when the pane produces MEANINGFUL output. Repaints do not
            // count (see hasVisibleContent): a dialog that is still on screen keeps
            // redrawing its borders, and treating that as activity hid every real prompt.
            let fresh = String(tail.dropFirst(min(promptEnd, tail.count)))
            if hasVisibleContent(fresh) {
                prompt = .none
                // Exclude everything up to and including the old prompt. Without this the
                // very next detect() call would rediscover the same menu text.
                detectFloor = promptEnd
                promptEnd = 0
            }
        }

        if prompt == .none {
            let seen = detect(from: detectFloor)
            if seen != .none {
                prompt = seen
                promptEnd = tail.count
            }
        }
    }

    /// True when the text contains a complete line of MEANINGFUL output.
    ///
    /// A TUI waiting at a dialog still repaints: box borders, the cursor, blank padding.
    /// Treating any complete line as activity meant the flag was detected and then cleared
    /// by the next repaint, so it was off almost all the time — a blocked agent looked like
    /// a working one. Repaints are the pty's heartbeat, not evidence of work.
    ///
    /// A line counts as activity only if it carries real text: at least two non-blank
    /// characters that are not box-drawing, and not purely punctuation used for borders.
    private func hasVisibleContent(_ raw: String) -> Bool {
        let text = visibleText(raw)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // The trailing fragment is still arriving; only completed lines count.
        return lines.dropLast().contains { line in
            let meaningful = line.filter { ch in
                !ch.isWhitespace
                    && ch != "\u{00A0}"
                    && !Self.isBoxDrawing(ch)
            }
            return meaningful.count >= 2
        }
    }

    /// Box-drawing and block glyphs are how a REPAINT looks, not how progress looks.
    private static func isBoxDrawing(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2500...0x257F: return true   // box drawing
        case 0x2580...0x259F: return true   // block elements
        case 0x250:            return true  // a plain dash border run
        default: return false
        }
    }

    /// Called when the child exits; a prompt is meaningless then.
    func reset() {
        tail = ""
        prompt = .none
        detectFloor = 0
        promptEnd = 0
    }

    /// Strip ANSI escapes and box drawing so patterns match the visible text. Agent CLIs
    /// draw menus with borders and colour, and the raw bytes contain both interleaved.
    private func visibleText(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "\u{1B}" {
                // Skip CSI ... final-byte and the two-byte ESC forms.
                var j = raw.index(after: i)
                if j < raw.endIndex, raw[j] == "[" {
                    j = raw.index(after: j)
                    while j < raw.endIndex, !(raw[j].isLetter) { j = raw.index(after: j) }
                    i = j < raw.endIndex ? raw.index(after: j) : raw.endIndex
                    continue
                }
                i = j < raw.endIndex ? raw.index(after: j) : raw.endIndex
                continue
            }
            out.append(c)
            i = raw.index(after: i)
        }
        return out
    }

    /// Lines that look like a selectable option: "1. Update now", "2) Skip", "❯ 3. Yes",
    /// "- Skip". Two or more is what distinguishes a menu from prose that happens to
    /// mention updating.
    private static func choiceLineCount(in text: String) -> Int {
        // Every line except the last is newline-terminated. The trailing fragment is
        // incomplete and must not count: "2." looks like a finished option, so a menu
        // split mid-line could be half-counted, and the rest of that line then arrived as
        // "activity" that floored the menu away. Classification must be independent of
        // where the PTY happened to break the write.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if let last = lines.last, !last.isEmpty { lines.removeLast() }
        return lines.reduce(0) { total, rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // Strip a leading pointer/selection marker.
            for marker in ["❯", ">", "→", "*", "•"] where line.hasPrefix(marker) {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { return total }
            let digits = line.prefix { $0.isNumber }
            guard !digits.isEmpty else {
                return line.hasPrefix("- ") ? total + 1 : total
            }
            let after = line.dropFirst(digits.count)
            return (after.hasPrefix(".") || after.hasPrefix(")"))
                ? total + 1 : total
        }
    }

    private func detect(from floor: Int = 0) -> PanePrompt {
        // Only the last few lines matter: a prompt is at the bottom of the screen, and
        // scanning the whole tail would match a prompt the user already answered. `floor`
        // additionally excludes text that is known to predate the last cleared prompt.
        let scan = String(tail.dropFirst(min(floor, tail.count)))
        let text = visibleText(scan)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(12)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let window = lines.joined(separator: "\n").lowercased()
        if window.isEmpty { return .none }

        // Order matters: the trust dialog often mentions "permissions", so it is checked
        // before the generic permission pattern.
        // Every CLI words its workspace-trust dialog differently, and matching one
        // vendor's phrasing missed the others in the real app:
        //   Claude   "Is this a project you created or one you trust?" ... "Yes, I trust this folder"
        //   Codex    "Trust this folder?" ... "1. Trust and continue 2. Back to Agent Command"
        //   Antigravity "Do you trust the contents of this project?"
        // So match on the SUBJECT (trust + folder/project/workspace) plus a choice shape,
        // not on a sentence.
        if window.contains("bypass permissions mode") && window.contains("yes, i accept") {
            return .permission
        }
        let mentionsTrust = window.contains("trust")
            && (window.contains("folder") || window.contains("project")
                || window.contains("workspace") || window.contains("directory"))
        let isQuestion = window.contains("?") || window.contains("trust and continue")
            || window.contains("no, exit")
        // No choice-count requirement: Claude's options are UNNUMBERED ("> No, exit" /
        // "  Yes, I trust this folder"), so demanding a numbered option missed the very
        // dialog that started this. The question mark is the structural signal, and it is
        // what keeps ordinary prose about trust settings from matching.
        if mentionsTrust && isQuestion {
            return .trust
        }

        // An UPDATE **MENU**, not an update NOTICE.
        //
        // Hermes prints "△ update available" as a passive banner while its input box is
        // live and accepting a prompt. Treating that as a blocking prompt is a false
        // positive, and a false positive is worse than a miss here: it tells the user to
        // intervene in a healthy pane, and after that they stop trusting the flag.
        //
        // A blocking menu has SELECTABLE OPTIONS. Require the words plus at least two
        // numbered/bulleted choice lines.
        let hasUpdateWords = window.contains("update available")
            || window.contains("update now")
            || (window.contains("update") && window.contains("skip"))
        if hasUpdateWords && Self.choiceLineCount(in: window) >= 2 {
            return .update(version: nil)
        }

        // A CLI asking for approval. Matched narrowly: many normal answers contain the
        // word "allow", so require a question shape.
        if window.contains("do you want to allow")
            || window.contains("allow this command")
            || window.contains("approve this")
            || window.contains("permission to run") {
            return .permission
        }

        return .none
    }
}

/// `LocalProcessTerminalView` consumes its own data callback, so the stream is observed by
/// overriding `dataReceived` rather than by installing a second delegate (which SwiftTerm
/// documents as a mistake — it replaces the one it needs internally).
final class ObservableTerminalView: LocalProcessTerminalView {
    /// Invoked on the terminal's data queue with every chunk of child output.
    var onOutput: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // Observe first: the superclass implementation drives the screen, and a throw or
        // return in an observer must not be able to stop rendering.
        onOutput?(slice)
        super.dataReceived(slice: slice)
    }
}
