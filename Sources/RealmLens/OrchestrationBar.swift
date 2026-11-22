import AppKit
import SwiftUI

struct OrchestrationBar: View {
    @Environment(LensStore.self) private var lens
    @Bindable var run: OrchestrationRun
    let space: URL?
    let spaceReadable: Bool
    @State private var showingOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Goal", text: $run.goal, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("orchestration-goal")
                    .disabled(run.isActive)
                if run.isActive {
                    Button("Cancel Run") { run.cancel() }
                        .disabled(run.phase == .canceling)
                } else {
                    Button("Run Goal") {
                        if let space, let terminals = lens.agents {
                            run.start(space: space, terminals: terminals)
                        }
                    }
                    .accessibilityIdentifier("run-goal")
                    .buttonStyle(.borderedProminent)
                    .disabled(!run.canStart || !spaceReadable || space == nil)
                }
            }
            HStack(spacing: 10) {
                Picker("Orchestrator", selection: $run.planner) {
                    ForEach(OrchestrationRun.Agent.allCases) { agent in
                        Text(agent.label).tag(agent)
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("goal-orchestrator")
                .disabled(run.isActive)

                Menu {
                    ForEach(OrchestrationRun.Agent.allCases) { agent in
                        Toggle(agent.label, isOn: workerSelection(agent))
                    }
                } label: {
                    Text("Workers (\(run.workers.count))")
                }
                .fixedSize()
                .disabled(run.isActive)

                let names = OrchestrationRun.Agent.allCases.filter { run.workers.contains($0) }.map(\.label)
                Text(names.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Picker("Per turn", selection: $run.timeoutMinutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .fixedSize()
                .disabled(run.isActive)
                Spacer(minLength: 0)
                Toggle("Full access (YOLO)", isOn: $run.fullAccess)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .disabled(run.isActive)
                    .help("Use each CLI’s automatic approval mode and confirm recognized workspace-trust and bypass startup dialogs.")

                if let report = run.reportURL {
                    Button("Open Report") { NSWorkspace.shared.open(report) }
                }
            }
            if run.phase != .idle {
                runStatus
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var runStatus: some View {
        DisclosureGroup(isExpanded: $showingOutput) {
            ScrollViewReader { scroll in
                ScrollView {
                    Text(verbatim: run.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("run-output-end")
                }
                .frame(height: 100)
                .onAppear { scroll.scrollTo("run-output-end") }
                .onChange(of: run.output) { _, _ in scroll.scrollTo("run-output-end") }
            }
        } label: {
            HStack(spacing: 6) {
                if run.isActive {
                    ProgressView().controlSize(.mini)
                }
                Text(run.phase.label)
                    .font(.caption.weight(.semibold))
                    .fixedSize()
                if !run.latestLine.isEmpty {
                    Text(verbatim: run.latestLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(run.latestLine)
                }
            }
        }
    }

    private func workerSelection(_ agent: OrchestrationRun.Agent) -> Binding<Bool> {
        Binding {
            run.workers.contains(agent)
        } set: { selected in
            if selected {
                run.workers.insert(agent)
            } else {
                run.workers.remove(agent)
            }
        }
    }
}
