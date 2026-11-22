import Darwin
import Foundation
import Observation

/// A CLI run belongs to the selected space and survives switching window tabs.
@MainActor
@Observable
final class OrchestrationRun {
    enum Agent: String, CaseIterable, Identifiable {
        case codex, opencode, claude, hermes, agy

        var id: String { rawValue }

        var label: String {
            switch self {
            case .codex: return "Codex"
            case .opencode: return "OpenCode"
            case .claude: return "Claude"
            case .hermes: return "Hermes"
            case .agy: return "Antigravity"
            }
        }
    }

    enum Phase: Equatable {
        case idle, running, canceling, completed, canceled
        case failed(Int32)
        case couldNotStart

        var label: String {
            switch self {
            case .idle: return ""
            case .running: return "Running goal"
            case .canceling: return "Canceling run"
            case .completed: return "Goal complete"
            case .canceled: return "Run canceled"
            case .failed(let status): return "Run failed (exit \(status))"
            case .couldNotStart: return "Could not start Realm"
            }
        }
    }

    var goal = ""
    var planner: Agent = .codex
    var timeoutMinutes = 15
    var fullAccess = true
    var workers: Set<Agent> = [.codex, .opencode]
    private(set) var phase: Phase = .idle
    private(set) var output = ""
    private(set) var latestLine = ""
    private(set) var reportURL: URL?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var discardOutput = false

    var isActive: Bool { phase == .running || phase == .canceling }

    var canStart: Bool {
        !isActive && !workers.isEmpty && !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start(space: URL, terminals: AgentsStore) {
        guard process == nil, canStart else { return }
        let workerNames = Agent.allCases.filter { workers.contains($0) }.map(\.rawValue)
        let bridge = UUID().uuidString

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login startup supplies the usual CLI PATH. Pass the goal as one argument,
        // outside the shell program, so text such as quotes or $() stays literal.
        child.arguments = [
            "-lic", "exec realm \"$@\"", "realm", "orchestrate", "--planner", planner.rawValue,
            "--workers", workerNames.joined(separator: ","), "--timeout", String(timeoutMinutes * 60), "--", goal,
        ]
        child.currentDirectoryURL = space.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["REALM_SPACE"] = space.path
        environment["REALM_LENS_BRIDGE"] = bridge
        environment["REALM_AGENT"] = environment["REALM_AGENT"] ?? "realmlens"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        clearOutput()
        discardOutput = false
        do {
            try child.run()
        } catch {
            phase = .couldNotStart
            append(error.localizedDescription)
            return
        }
        try? pipe.fileHandleForWriting.close()
        process = child
        phase = .running

        let reportDirectory = space.resolvingSymlinksInPath().appendingPathComponent("runs", isDirectory: true)
        let events = Self.events(from: pipe.fileHandleForReading, child: child)
        Task { [weak self] in
            for await event in events {
                guard let self, self.process === child else { return }
                switch event {
                case .line(let line):
                    guard !self.discardOutput else { continue }
                    if line.hasPrefix("REALM_PANE ") {
                        let data = Data(line.dropFirst("REALM_PANE ".count).utf8)
                        guard self.phase == .running,
                              let request = try? JSONDecoder().decode(GoalTerminalRequest.self, from: data),
                              request.bridge == bridge,
                              request.folder.resolvingSymlinksInPath().deletingLastPathComponent().path ==
                                space.appendingPathComponent("tmp").resolvingSymlinksInPath().path,
                              request.folder.lastPathComponent.hasPrefix("pane-") else { continue }
                        terminals.deliver(request, planner: self.planner.rawValue, workers: workerNames,
                                          fullAccess: self.fullAccess)
                    } else {
                        self.append(line, reportDirectory: reportDirectory)
                    }
                case .exit(let status, let interrupted):
                    terminals.finishGoal(bridge: bridge, canceled: status != 0 || interrupted)
                    self.finish(status: status, interrupted: interrupted)
                }
            }
        }
    }

    func cancel() {
        guard phase == .running, let process, process.isRunning else { return }
        phase = .canceling
        process.interrupt()
    }

    func spaceChanged() {
        goal = ""
        clearOutput()
        // Wait for the old run to exit before allowing a new one. Its final lines
        // belong to the previous space.
        discardOutput = process != nil
        cancel()
        if process == nil { phase = .idle }
    }

    private func clearOutput() {
        output = ""
        latestLine = ""
        reportURL = nil
    }

    private func append(_ line: String, reportDirectory: URL? = nil) {
        output += line + "\n"
        if !line.isEmpty { latestLine = line }
        let prefix = "Report: "
        guard let reportDirectory, line.hasPrefix(prefix) else { return }
        let path = String(line.dropFirst(prefix.count))
        guard path.hasPrefix("/") else { return }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(reportDirectory.path + "/"), url.pathExtension == "md",
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
        reportURL = url
    }

    private func finish(status: Int32, interrupted: Bool) {
        process = nil
        if discardOutput {
            phase = .idle
        } else if interrupted || status == 130 || (phase == .canceling && status != 0) {
            phase = .canceled
        } else {
            phase = status == 0 ? .completed : .failed(status)
        }
    }

    private enum Event {
        case line(String)
        case exit(Int32, interrupted: Bool)
    }

    private nonisolated static func events(from reader: FileHandle, child: Process) -> AsyncStream<Event> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8](repeating: 0, count: 8_192)
                var pending = Data()
                // A pipe read returns as soon as any bytes are available. Frame
                // complete lines first so UTF-8 survives a split across reads.
                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(reader.fileDescriptor, $0.baseAddress, $0.count)
                    }
                    if count == 0 { break }
                    if count < 0 {
                        let error = errno
                        if error == EINTR { continue }
                        continuation.yield(.line(String(cString: strerror(error))))
                        break
                    }
                    pending.append(contentsOf: buffer.prefix(count))
                    while let newline = pending.firstIndex(of: 0x0a) {
                        continuation.yield(.line(String(decoding: pending[..<newline], as: UTF8.self)))
                        pending.removeSubrange(...newline)
                    }
                }
                if !pending.isEmpty {
                    continuation.yield(.line(String(decoding: pending, as: UTF8.self)))
                }
                try? reader.close()
                child.waitUntilExit()
                let status = child.terminationStatus
                continuation.yield(.exit(status, interrupted: child.terminationReason == .uncaughtSignal && status == SIGINT))
                continuation.finish()
            }
        }
    }
}
