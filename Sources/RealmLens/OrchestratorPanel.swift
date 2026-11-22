// OrchestratorPanel — the orchestrator dock for the terminal view.
//
// Contract (coordination/terminals/BUILD-CONTRACT.md):
//
//   struct OrchestratorPanel: View {
//       let leases: [RealmLease]
//       let nodes: [RealmNode]
//       let now: Int
//       var onSelect: (String) -> Void
//   }
//
// Four stacked, independently scrolling sections, always in this order:
//   LEASES      resource · owner · remaining; orange under two minutes
//   FRONTIER    unverified facts + open tasks, severity sorted, 8 shown (+N more)
//   ATTENTION   REFUTED / CONTESTED / TAINTED / BLOCKED, 5 shown (+N more)
//   AGENTS      distinct created_by values with last-seen age
//
// Status is never colour alone: every state carries a glyph and a spelled word
// beside the colour, so the dock stays readable in greyscale. Ids and numbers are
// monospaced; titles are prose and use the system font.
//
// Sizing: the panel is designed for 260 x 900. Each band is allocated a whole
// number of rows, and its scroll viewport is exactly that many row-heights tall.
// Two consequences follow, and they are the whole point of the arithmetic below:
//   - the bands can only ever sum to less than the panel height, so no section can
//     overlap the one beneath it;
//   - at rest every viewport shows complete rows, so no row is cut in half by a
//     band edge, and a section with more rows than fit scrolls inside its band
//     instead of squeezing its neighbours.
// The "+N more" footer reports what the contract's cap excluded. Rows that merely
// did not fit scroll inside their own band, so they are reachable rather than lost,
// and the height never silently changes what the cap means.
//
// Read-only by construction: this view only consumes the snapshot it is handed.
// It reads no more of the model than the contract allows — nodes by
// id/kind/title/createdBy/factStatus/taskState/tainted/blockedBy, leases by
// resource/owner/remaining/isLive/isStale — and never touches the cached taint
// column, which the reader exists to distrust.

import SwiftUI
import Foundation
import RealmLensCore

struct OrchestratorPanel: View {
    let leases: [RealmLease]
    let nodes: [RealmNode]
    let now: Int
    var onSelect: (String) -> Void

    private static let frontierCap = 8
    private static let attentionCap = 5

    /// An *allocation* hint, not a truncation. The contract caps only FRONTIER and
    /// ATTENTION, and leases are few by nature (one live lease per resource). This
    /// stops a long lease table from claiming half the panel and starving FRONTIER,
    /// while the section still renders — and scrolls through — every lease it has.
    private static let leaseAllocationHint = 6
    private static let seenHorizon = 7 * 86_400

    // Fixed row heights. Uniform rows mean a band's scroll position always lands on
    // a row boundary, so a row is never sliced in half at the edge of its band.
    //
    // The chrome constants are exact, not estimates — they are what makes
    // `headerBlock + rows * rowHeight` add up to precisely the band height:
    //   27 pt title line + 4 pt gap + 1 pt divider + 4 pt gap = 36
    //   4 pt gap + 13 pt footer text                      = 17
    private static let headerBlockHeight: CGFloat = 36
    private static let footerBlockHeight: CGFloat = 17
    private static let lineRowHeight: CGFloat = 32   // lease / agent: two short lines
    // One id line, up to two title lines, and the "blocked by …" line a BLOCKED
    // node adds. Sized for all three at once so a row can never clip its own text.
    private static let nodeRowHeight: CGFloat = 60
    private static let sectionSpacing: CGFloat = 4
    /// Named because it is inside headerBlockHeight's budget; double-counting it was a bug.
    private static let dividerHeight: CGFloat = 1

    var body: some View {
        let rankedFrontier = frontier
        let rankedAttention = attention
        let agentRows = agents
        let sorted = sortedLeases

        return GeometryReader { proxy in
            let gap: CGFloat = 8
            let usable = max(0, proxy.size.height - gap * 3)
            let layout = bandLayout(available: usable,
                                    leaseCount: min(sorted.count, Self.leaseAllocationHint),
                                    frontierCount: min(rankedFrontier.count, Self.frontierCap),
                                    attentionCount: min(rankedAttention.count, Self.attentionCap),
                                    agentCount: agentRows.count,
                                    showsFrontierFooter:
                                        overflow(rankedFrontier.count, Self.frontierCap) != nil,
                                    showsAttentionFooter:
                                        overflow(rankedAttention.count, Self.attentionCap) != nil)

            VStack(alignment: .leading, spacing: gap) {
                section("LEASES", count: sorted.count, height: layout.heights[0],
                        cap: Int.max) {
                    leaseList(sorted, limit: sorted.count)
                }
                section("FRONTIER", count: rankedFrontier.count, height: layout.heights[1],
                        cap: Self.frontierCap) {
                    frontierList(rankedFrontier, limit: Self.frontierCap)
                }
                section("ATTENTION", count: rankedAttention.count, height: layout.heights[2],
                        cap: Self.attentionCap) {
                    attentionList(rankedAttention, limit: Self.attentionCap)
                }
                section("AGENTS", count: agentRows.count, height: layout.heights[3],
                        cap: Int.max) {
                    agentList(agentRows, limit: agentRows.count)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    // ---------------------------------------------------------------- sizing

    private struct BandLayout {
        var heights: [CGFloat]
        var rows: [Int]
    }

    /// Divide the available height among the four sections in whole rows.
    ///
    /// Each band is `header + rows * rowHeight (+ footer)`, so the parts can only
    /// add up to less than the available height and the remainder becomes blank
    /// space below the last section. It is therefore structurally impossible for one
    /// section to overlap the next, and no band is ever given a partial row.
    private func bandLayout(available: CGFloat, leaseCount: Int, frontierCount: Int,
                            attentionCount: Int, agentCount: Int,
                            showsFrontierFooter: Bool,
                            showsAttentionFooter: Bool) -> BandLayout {
        let capacities = [leaseCount, frontierCount, attentionCount, agentCount]
        let rowHeights = [Self.lineRowHeight, Self.nodeRowHeight,
                          Self.nodeRowHeight, Self.lineRowHeight]
        let footers: [CGFloat] = [
            0,
            showsFrontierFooter ? Self.footerBlockHeight : 0,
            showsAttentionFooter ? Self.footerBlockHeight : 0,
            0,
        ]

        // Every section gets a header, one row and its footer as a floor: that is
        // enough for the "nothing here" line and keeps all four visible at once.
        var heights: [CGFloat] = (0..<4).map { index in
            Self.headerBlockHeight + rowHeights[index] + footers[index]
        }
        let floorTotal = heights.reduce(0, +)
        if available < floorTotal {
            // Smaller than the four floors: split evenly and let the scroll views
            // clip. This only happens far below the contract's height.
            let each = max(0, available / 4)
            return BandLayout(heights: [each, each, each, each], rows: [1, 1, 1, 1])
        }

        var budget = available - floorTotal
        var rows = [1, 1, 1, 1]   // the floor row each section already has

        // Greedy: repeatedly give the next row to whichever section is furthest
        // from the count it wants. This uses the height better than a proportional
        // slice rounded down to whole rows, and it naturally favours a section with
        // eight rows to show over one with two.
        while true {
            var best = -1
            var bestScore = -1.0
            for index in 0..<4 {
                guard rows[index] < capacities[index],
                      rowHeights[index] <= budget else { continue }
                let score = Double(capacities[index] - rows[index])
                          / Double(max(1, capacities[index]))
                if score > bestScore {
                    bestScore = score
                    best = index
                }
            }
            guard best >= 0 else { break }
            rows[best] += 1
            budget -= rowHeights[best]
        }

        for index in 0..<4 {
            heights[index] += CGFloat(rows[index] - 1) * rowHeights[index]
        }

        // If every section can already show everything it has, the leftover is pure
        // padding: spread it so four sparse sections fill the panel instead of
        // clustering at the top. When a section still wants rows it could not afford,
        // the leftover must NOT be handed out: inflating a band by less than a row is
        // exactly what makes the next row peek in half-clipped.
        let satisfied = (0..<4).allSatisfy { rows[$0] >= capacities[$0] }
        if budget > 0 && satisfied {
            let each = budget / 4
            for index in 0..<4 { heights[index] += each }
        }
        return BandLayout(heights: heights, rows: rows)
    }

    /// What the cap is hiding. The section scrolls, so rows that merely did not fit
    /// the band are reachable and are not counted here — this line reports only the
    /// entries the cap excluded, which is exactly what the contract describes.
    private func overflow(_ count: Int, _ cap: Int) -> String? {
        let hidden = count - min(count, cap)
        return hidden > 0 ? "+\(hidden) more" : nil
    }

    // ---------------------------------------------------------------- sections

    /// One titled section with its own scroll area. The viewport is an exact whole
    /// number of rows tall, so the resting position shows complete rows; content
    /// beyond the band scrolls rather than bleeding into the next section.
    private func section<Content: View>(
        _ title: String,
        count: Int,
        height: CGFloat,
        cap: Int,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        let footer = overflow(count, cap)
        // headerBlockHeight is DEFINED as 27 text + 4 gap + 1 divider + 4 gap = 36, so the
        // divider is already inside it. Subtracting it again here (a previous version of
        // this line did) makes every viewport exactly 1pt shorter than its row content,
        // and a band whose rows fill it scrolls its first row out of view.
        let viewport = max(0, height - Self.headerBlockHeight
                              - (footer == nil ? 0 : Self.footerBlockHeight))

        return VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 2)
                // Total, not visible: the header answers "how many are there", the
                // footer answers "how many are you not seeing".
                Text("\(count)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: Self.headerBlockHeight - Self.sectionSpacing * 2
                              - Self.dividerHeight,
                   alignment: .center)
            // Exactly 1pt, named, and part of headerBlockHeight's budget above.
            Divider().frame(height: Self.dividerHeight)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    rows()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Leave room for an overlay scrollbar so a long title never runs
                // underneath it at 260 pt.
                .padding(.trailing, 6)
            }
            // Automatic rather than always-visible: a permanent bar would eat
            // 8 of the 260 points on a panel that has none to spare.
            .scrollIndicators(.automatic)
            .frame(height: viewport, alignment: .top)
            if let footer {
                Text(footer)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(height: max(0, height), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Belt and braces: the band is the hard boundary. Anything that tries to
        // grow past it is clipped rather than allowed to overlap the next section.
        .clipped()
    }

    // ---------------------------------------------------------------- leases

    private var sortedLeases: [RealmLease] {
        leases.filter { $0.owner != nil }.sorted { a, b in
            let aLive = a.isLive(now: now)
            let bLive = b.isLive(now: now)
            if aLive != bLive { return aLive }        // live first, then expired
            let aRemaining = a.remaining(now: now)
            let bRemaining = b.remaining(now: now)
            if aRemaining != bRemaining { return aRemaining < bRemaining }
            if a.resource != b.resource { return a.resource < b.resource }
            return (a.owner ?? "") < (b.owner ?? "")
        }
    }

    @ViewBuilder
    private func leaseList(_ sorted: [RealmLease], limit: Int) -> some View {
        if sorted.isEmpty {
            empty("no leases held")
        } else {
            ForEach(Array(sorted.prefix(max(0, limit)).enumerated()), id: \.offset) { pair in
                leaseRow(pair.element)
            }
        }
    }

    private func leaseRow(_ lease: RealmLease) -> some View {
        let state = leaseState(lease)
        let target = linkedNodeID(for: lease)
        return VStack(alignment: .leading, spacing: 1) {
            // Contract order: resource · owner · remaining. Two lines, because at
            // 260 pt a single line would truncate all three to ellipses.
            HStack(spacing: 3) {
                Text(lease.resource)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(lease.owner ?? "no owner")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 4) {
                Text(state.glyph)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(state.color)
                    .frame(width: 10, alignment: .center)
                Text(state.word)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(remainingLabel(lease))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.lineRowHeight, alignment: .topLeading)
        .clipped()
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if let target { onSelect(target) }
        }
        .help("\(lease.resource) · \(lease.owner ?? "no owner") · \(state.word)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(lease.resource), \(lease.owner ?? "no owner"), \(state.word), \(remainingLabel(lease)) remaining")
    }

    private func leaseState(_ lease: RealmLease) -> (glyph: String, word: String, color: Color) {
        if lease.isLive(now: now) {
            // The contract's hard rule: under two minutes is orange.
            if lease.remaining(now: now) < 120 {
                return ("◐", "EXPIRING", .orange)
            }
            return ("●", "LIVE", .green)
        }
        if lease.isStale(now: now) {
            // Expired but never released: the owner stalled or died mid-work. Its
            // remaining time is 0, so the contract's "< 120 s" rule makes it orange
            // as well; the word and glyph are what tell the two cases apart.
            return ("○", "STALE", .orange)
        }
        // expiresAt is NULL: neither live nor stale, and remaining() reports 0.
        return ("◇", "NO EXPIRY", .secondary)
    }

    private func remainingLabel(_ lease: RealmLease) -> String {
        if lease.isLive(now: now) || lease.isStale(now: now) {
            return Self.durationText(lease.remaining(now: now))
        }
        return "—"
    }

    /// Only a lease whose resource names a node can jump anywhere.
    private func linkedNodeID(for lease: RealmLease) -> String? {
        nodes.first { $0.id == lease.resource }?.id
    }

    // ---------------------------------------------------------------- frontier

    private var frontier: [RankedNode] {
        nodes
            .compactMap { node -> RankedNode? in
                guard isFrontier(node) else { return nil }
                return RankedNode(node: node, status: effectiveStatus(node))
            }
            .sorted(by: severityOrder)
    }

    /// "Unverified facts + open tasks" is about the node's OWN state; taint and
    /// blocking are overlays. A fact with an empty status has never been checked,
    /// so it belongs here — the reader reports "" until a check writes a result.
    private func isFrontier(_ node: RealmNode) -> Bool {
        switch node.kind {
        case .fact:
            return node.factStatus.isEmpty || node.factStatus == "UNVERIFIED"
        case .task:
            return node.taskState.isEmpty || node.taskState == "OPEN"
        default:
            return false
        }
    }

    /// Overlay precedence mirrors the rest of the app: derived taint outranks a
    /// block, and a block outranks the node's own unverified/open state.
    private func effectiveStatus(_ node: RealmNode) -> String {
        if node.tainted { return "TAINTED" }
        if !node.blockedBy.isEmpty { return "BLOCKED" }
        switch node.kind {
        case .fact:
            return node.factStatus.isEmpty ? "UNVERIFIED" : node.factStatus
        default:
            return node.taskState.isEmpty ? "OPEN" : node.taskState
        }
    }

    @ViewBuilder
    private func frontierList(_ ranked: [RankedNode], limit: Int) -> some View {
        let shown = Array(ranked.prefix(max(0, min(limit, Self.frontierCap))))
        if shown.isEmpty {
            empty("frontier is clear")
        } else {
            ForEach(shown) { item in
                nodeRow(item)
            }
        }
    }

    // ---------------------------------------------------------------- attention

    private var attention: [RankedNode] {
        nodes
            .compactMap { node -> RankedNode? in
                guard let status = attentionStatus(node) else { return nil }
                return RankedNode(node: node, status: status)
            }
            .sorted(by: severityOrder)
    }

    /// One entry per node, under its worst problem: a refuted fact is a refuted
    /// fact even if it also taints its dependents. Taint and blocking are reported
    /// here only for nodes that are not already refuted or contested.
    private func attentionStatus(_ node: RealmNode) -> String? {
        if node.kind == .fact {
            if node.factStatus == "REFUTED" { return "REFUTED" }
            if node.factStatus == "CONTESTED" { return "CONTESTED" }
        }
        if node.tainted { return "TAINTED" }
        if !node.blockedBy.isEmpty { return "BLOCKED" }
        return nil
    }

    @ViewBuilder
    private func attentionList(_ ranked: [RankedNode], limit: Int) -> some View {
        let shown = Array(ranked.prefix(max(0, min(limit, Self.attentionCap))))
        if shown.isEmpty {
            empty("nothing needs attention")
        } else {
            ForEach(shown) { item in
                nodeRow(item)
            }
        }
    }

    // ---------------------------------------------------------------- agents

    /// Distinct `created_by` values. Last seen is bounded by lease evidence, which
    /// is the only clock-bearing part of the allowlisted model: a live lease is
    /// affirmative presence now, an expired lease dates the last stretch of work to
    /// its expiry, and an agent with no lease has left no evidence we may read.
    private var agents: [AgentRow] {
        var counts: [String: Int] = [:]
        for node in nodes {
            counts[agentName(node.createdBy), default: 0] += 1
        }

        var liveLease: [String: RealmLease] = [:]
        var staleAge: [String: Int] = [:]
        for lease in leases {
            guard let rawOwner = lease.owner else { continue }
            let owner = agentName(rawOwner)
            guard owner != Self.unknownAgent else { continue }
            if lease.isLive(now: now) {
                // Keep the lease that ends soonest: that is the one that will need
                // attention first.
                if let current = liveLease[owner] {
                    if lease.remaining(now: now) < current.remaining(now: now) {
                        liveLease[owner] = lease
                    }
                } else {
                    liveLease[owner] = lease
                }
            } else if lease.isStale(now: now), let age = Self.expiredAge(lease, now: now) {
                // Several expired leases: the most recent expiry is the closest
                // thing to a last-seen timestamp we have.
                staleAge[owner] = min(staleAge[owner] ?? Int.max, age)
            }
        }

        return counts.keys.map { name in
            AgentRow(name: name,
                     createdCount: counts[name] ?? 0,
                     liveLease: liveLease[name],
                     staleAge: staleAge[name])
        }
        .sorted { a, b in
            if a.sortKey != b.sortKey { return a.sortKey < b.sortKey }
            // Equal (or equally unknown) recency: alphabetical keeps the roster
            // from reshuffling between ticks.
            return a.name < b.name
        }
    }

    @ViewBuilder
    private func agentList(_ all: [AgentRow], limit: Int) -> some View {
        if all.isEmpty {
            empty("no agents yet")
        } else {
            ForEach(Array(all.prefix(max(0, limit)))) { agent in
                agentRow(agent)
            }
        }
    }

    private func agentRow(_ agent: AgentRow) -> some View {
        let style = agentStyle(agent)
        // Two compact lines, each of which compresses at exactly one place, so the
        // row can never overflow 260 pt sideways. The spelled word is fixed-size:
        // it is the non-colour channel and must not be what truncates.
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(agent.name)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let lease = agent.liveLease {
                    // Resource plus the time it has left, as one compressible tap.
                    Text("\(lease.resource) \(Self.durationText(lease.remaining(now: now)))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 4) {
                Text(style.glyph)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(style.color)
                    .frame(width: 10, alignment: .center)
                Text(style.word)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(style.color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(agent.seenLabel())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.lineRowHeight, alignment: .topLeading)
        .clipped()
        .padding(.trailing, 2)
        .help("\(agent.name) · \(agent.createdCount) node\(agent.createdCount == 1 ? "" : "s") · \(agent.seenLabel())")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name), \(style.word), \(agent.seenLabel())")
    }

    private func agentStyle(_ agent: AgentRow) -> (glyph: String, word: String, color: Color) {
        if let lease = agent.liveLease {
            return lease.remaining(now: now) < 120
                ? ("◐", "EXPIRING", .orange)
                : ("●", "LEASED", .green)
        }
        if agent.staleAge != nil {
            return ("○", "STALLED", .red)
        }
        return ("·", "IDLE", .secondary)
    }

    // ---------------------------------------------------------------- shared rows

    private func nodeRow(_ item: RankedNode) -> some View {
        let state = style(for: item.status)
        // The fixed height lives OUTSIDE the Button. Put it on the label and the
        // platform control sizing shrinks the row to its intrinsic text height,
        // which desynchronises the row pitch from the band arithmetic.
        return Button {
            onSelect(item.node.id)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(state.glyph)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(state.color)
                        .frame(width: 10, alignment: .center)
                    Text(item.node.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.status)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(state.color)
                        .lineLimit(1)
                        // The spelled word must never be the thing that truncates:
                        // it is the non-colour channel.
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                Text(item.node.title.isEmpty ? "(untitled)" : item.node.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.status == "BLOCKED" && !item.node.blockedBy.isEmpty {
                    Text("blocked by " + item.node.blockedBy.joined(separator: ", "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: Self.nodeRowHeight, alignment: .topLeading)
        .clipped()
        .padding(.trailing, 2)
        .help("\(item.node.id) — \(item.status)")
        .accessibilityLabel("\(item.node.id), \(item.status), \(item.node.title)")
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    // ---------------------------------------------------------------- styling

    /// Glyph and colour travel together; the spelled word is rendered beside them
    /// by every caller, so status never depends on colour perception.
    private func style(for status: String) -> (glyph: String, color: Color) {
        switch status {
        case "REFUTED": return ("✗", .red)
        case "CONTESTED": return ("≈", .pink)
        case "TAINTED": return ("!", .orange)
        case "BLOCKED": return ("B", .yellow)
        case "UNVERIFIED": return ("?", .secondary)
        case "OPEN": return ("○", .secondary)
        case "VERIFIED", "DONE": return ("✓", .green)
        default: return ("·", .secondary)
        }
    }

    private func severityOrder(_ a: RankedNode, _ b: RankedNode) -> Bool {
        let ra = rank(a.status)
        let rb = rank(b.status)
        if ra != rb { return ra < rb }
        return a.node.id < b.node.id
    }

    /// Same order as the window and the graph, so the dock never disagrees with
    /// them about which problem is worst.
    private func rank(_ status: String) -> Int {
        switch status {
        case "REFUTED": return 0
        case "CONTESTED": return 1
        case "TAINTED": return 2
        case "BLOCKED": return 3
        case "UNVERIFIED": return 4
        case "OPEN": return 5
        default: return 6
        }
    }

    // ---------------------------------------------------------------- formatting

    /// Compact, monospaced-friendly durations: 42s, 14m, 3h, 2d.
    private static func durationText(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3_600)h" }
        return "\(s / 86_400)d"
    }

    private static let unknownAgent = "unknown"

    /// `created_by` is nullable in the schema; the reader collapses NULL to "". Both
    /// are the same bucket, rendered as a word rather than as a blank row.
    private func agentName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.unknownAgent : trimmed
    }

    /// RealmLease does not publish `expiresAt`, but `isLive(now:)` is monotone in
    /// its argument: true for every tick before expiry, false at and after it. That
    /// makes the expiry instant recoverable exactly by binary search over past
    /// ticks, using only the contract's public API. Only stale leases pay for it,
    /// and only to turn "expired" into a real age.
    private static func expiredAge(_ lease: RealmLease, now: Int) -> Int? {
        guard lease.isStale(now: now) else { return nil }
        let oldest = now - seenHorizon
        // Expired before the horizon: report the horizon itself rather than scan
        // forever. The label then reads "seen 7d+ ago" as a lower bound.
        guard lease.isLive(now: oldest) else { return seenHorizon }
        var liveTick = oldest    // isLive == true
        var deadTick = now       // isLive == false
        while deadTick - liveTick > 1 {
            let mid = liveTick + (deadTick - liveTick) / 2
            if lease.isLive(now: mid) { liveTick = mid } else { deadTick = mid }
        }
        // deadTick is the first instant at which the lease is no longer live, i.e.
        // expiresAt itself.
        return max(0, now - deadTick)
    }

    // ---------------------------------------------------------------- models

    private struct RankedNode: Identifiable {
        let node: RealmNode
        let status: String
        var id: String { node.id }
    }

    private struct AgentRow: Identifiable {
        let name: String
        let createdCount: Int
        let liveLease: RealmLease?
        /// Seconds since this agent's most recent lease expired, when we have one.
        /// `nil` means no lease evidence at all.
        let staleAge: Int?

        var id: String { name }

        /// Sort key: most recent evidence first. A live lease is 0, a stale lease is
        /// its age, and an agent we have no evidence for sorts last.
        var sortKey: Int {
            if liveLease != nil { return 0 }
            return staleAge ?? Int.max
        }

        func seenLabel() -> String {
            if liveLease != nil { return "seen now" }
            if let staleAge {
                if staleAge <= 0 { return "seen now" }
                if staleAge >= OrchestratorPanel.seenHorizon { return "seen 7d+ ago" }
                return "seen \(OrchestratorPanel.durationText(staleAge)) ago"
            }
            return "no lease seen"
        }
    }
}
