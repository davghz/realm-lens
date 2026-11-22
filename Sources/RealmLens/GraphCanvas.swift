// The graph. Deterministic layered layout, not a force simulation:
// a force layout moves nodes every tick, which destroys the one thing that makes a
// persistent view useful — stable position, so a glance tells you what CHANGED.

import SwiftUI
import RealmLensCore

struct GraphCanvas: View {
    let store: LensStore
    @Binding var selection: String?

    private let nodeW: CGFloat = 220
    private let nodeH: CGFloat = 44
    private let hGap: CGFloat = 72
    private let vGap: CGFloat = 18

    var body: some View {
        let layout = computeLayout()
        ZStack(alignment: .topLeading) {
            // edges beneath
            Canvas { ctx, size in
                for e in store.snapshot?.edges ?? [] {
                    guard let dep = layout.positions[e.from], let pre = layout.positions[e.to] else { continue }

                    // Ports are chosen RELATIVE to the two cards, not assumed.
                    //
                    // The layout puts prerequisites in lower ranks (further left), so the
                    // normal dependency edge travels LEFT. But two cases break that:
                    //   - a cycle (T007 <-> T008) produces a rightward edge
                    //   - two nodes in the same column (advisory edges) are vertically offset
                    // Assuming minX->maxX in those cases draws the line under the cards and
                    // points the arrow backwards.
                    let from: CGPoint
                    let to: CGPoint
                    let elbowVertical: Bool
                    let arrowDX: CGFloat
                    let arrowDY: CGFloat

                    if abs(dep.midY - pre.midY) < 1 && dep.midX > pre.midX {
                        // same row, dependent to the right -> horizontal, travelling left
                        from = CGPoint(x: dep.minX, y: dep.midY)
                        to   = CGPoint(x: pre.maxX, y: pre.midY)
                        elbowVertical = false
                        arrowDX = -6; arrowDY = 0
                    } else if dep.midX < pre.midX - 1 {
                        // dependent is LEFT of prerequisite: travelling right
                        from = CGPoint(x: dep.maxX, y: dep.midY)
                        to   = CGPoint(x: pre.minX, y: pre.midY)
                        elbowVertical = false
                        arrowDX = 6; arrowDY = 0
                    } else if abs(dep.midX - pre.midX) < 1 {
                        // SAME column: connect vertically through facing top/bottom edges.
                        // Direction follows the actual y-order, so the arrow always points
                        // from the dependent TOWARD its prerequisite.
                        let goingDown = dep.midY < pre.midY
                        from = CGPoint(x: dep.midX, y: goingDown ? dep.maxY : dep.minY)
                        to   = CGPoint(x: pre.midX, y: goingDown ? pre.minY : pre.maxY)
                        elbowVertical = true
                        arrowDY = goingDown ? 6 : -6
                        arrowDX = 0
                    } else {
                        // standard: dependent right of prerequisite, travelling left
                        from = CGPoint(x: dep.minX, y: dep.midY)
                        to   = CGPoint(x: pre.maxX, y: pre.midY)
                        elbowVertical = false
                        arrowDX = -6; arrowDY = 0
                    }

                    var path = Path()
                    path.move(to: from)
                    if elbowVertical {
                        // Bow sideways so a mutual edge pair does not draw one line on top
                        // of the other. Bow direction is stable per edge, not random.
                        let bow: CGFloat = e.from < e.to ? -14 : 14
                        let midY = (from.y + to.y) / 2
                        path.addLine(to: CGPoint(x: from.x + bow, y: midY))
                        path.addLine(to: CGPoint(x: to.x + bow, y: midY))
                    } else {
                        let midX = (from.x + to.x) / 2
                        path.addLine(to: CGPoint(x: midX, y: from.y))
                        path.addLine(to: CGPoint(x: midX, y: to.y))
                    }
                    path.addLine(to: to)

                    let style = strokeStyle(for: e.kind)
                    ctx.stroke(path, with: .color(style.color),
                               style: StrokeStyle(lineWidth: style.width, dash: style.dash))

                    // Arrowhead: base sits BEHIND the tip along the direction of travel.
                    var arrow = Path()
                    arrow.move(to: to)
                    if arrowDY == 0 {
                        arrow.addLine(to: CGPoint(x: to.x - arrowDX, y: to.y - 4))
                        arrow.addLine(to: CGPoint(x: to.x - arrowDX, y: to.y + 4))
                    } else {
                        arrow.addLine(to: CGPoint(x: to.x - 4, y: to.y - arrowDY))
                        arrow.addLine(to: CGPoint(x: to.x + 4, y: to.y - arrowDY))
                    }
                    arrow.closeSubpath()
                    ctx.fill(arrow, with: .color(style.color))
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)

            // nodes above
            ForEach(layout.order, id: \.self) { id in
                if let n = store.snapshot?.node(id), let r = layout.positions[id] {
                    NodeCard(node: n, store: store, selected: selection == id)
                        .frame(width: nodeW, height: nodeH)
                        .position(x: r.midX, y: r.midY)
                        .onTapGesture { selection = id }
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    // ------------------------------------------------------------ layout

    private struct Layout {
        var positions: [String: CGRect] = [:]
        var order: [String] = []
        var size: CGSize = .zero
    }

    private func computeLayout() -> Layout {
        guard let snap = store.snapshot else { return Layout() }

        // DAG edges only; contradicts/supports are advisory
        let dag = snap.edges.filter { ["requires", "depends_on", "cites", "assumes"].contains($0.kind) }
        var prereqsOf: [String: [String]] = [:]
        for e in dag { prereqsOf[e.from, default: []].append(e.to) }

        // Strongly-connected components first. A node inside a dependency cycle must sit in
        // the SAME column as its cycle partners, otherwise the back-edge is drawn across
        // columns and its arrow points the wrong way. Tarjan, iterative, no recursion limit.
        var sccOf: [String: Int] = [:]
        var sccMembers: [Int: [String]] = [:]
        runTarjan(nodes: snap.nodes.map(\.id), prereqs: prereqsOf,
                  sccOf: &sccOf, members: &sccMembers)

        // rank over the CONDENSED graph: one rank per SCC
        var sccPrereqs: [Int: Set<Int>] = [:]
        for (from, pres) in prereqsOf {
            guard let a = sccOf[from] else { continue }
            for p in pres {
                guard let b = sccOf[p] else { continue }
                if a != b { sccPrereqs[a, default: []].insert(b) }
            }
        }
        var sccRank: [Int: Int] = [:]
        var seenSCC = Set<Int>()
        func rankSCC(_ id: Int) -> Int {
            if let r = sccRank[id] { return r }
            if seenSCC.contains(id) { return 0 }          // defensive; condensation is acyclic
            seenSCC.insert(id)
            let ps = sccPrereqs[id] ?? []
            let r = ps.isEmpty ? 0 : (ps.map { rankSCC($0) }.max() ?? 0) + 1
            seenSCC.remove(id)
            sccRank[id] = r
            return r
        }
        for id in sccOf.values { _ = rankSCC(id) }

        var rank: [String: Int] = [:]
        for (node, scc) in sccOf { rank[node] = sccRank[scc] ?? 0 }

        // group by rank, ordered deterministically by severity then id
        var buckets: [Int: [String]] = [:]
        for n in snap.nodes { buckets[rank[n.id] ?? 0, default: []].append(n.id) }
        for (k, v) in buckets {
            buckets[k] = v.sorted { a, b in
                let na = snap.node(a)!, nb = snap.node(b)!
                let ra = severity(store.statusText(na)), rb = severity(store.statusText(nb))
                return ra == rb ? a < b : ra < rb
            }
        }

        let ranks = buckets.keys.sorted()
        let colW = nodeW + hGap
        let tallest = buckets.values.map(\.count).max() ?? 1
        let contentH = CGFloat(tallest) * (nodeH + vGap)

        var out = Layout()
        for (col, r) in ranks.enumerated() {
            let ids = buckets[r] ?? []
            let colH = CGFloat(ids.count) * (nodeH + vGap)
            let yOffset = (contentH - colH) / 2
            for (i, id) in ids.enumerated() {
                let x = CGFloat(col) * colW
                let y = yOffset + CGFloat(i) * (nodeH + vGap)
                out.positions[id] = CGRect(x: x, y: y, width: nodeW, height: nodeH)
            }
        }
        if ProcessInfo.processInfo.environment["REALM_DUMP_LAYOUT"] == "1" {
            for id in out.positions.keys.sorted() {
                let r = out.positions[id]!
                FileHandle.standardError.write(Data("LAYOUT \(id) x=\(Int(r.minX)) y=\(Int(r.minY)) rank=\(rank[id] ?? -1)\n".utf8))
            }
        }
        out.order = ranks.flatMap { buckets[$0] ?? [] }
        out.size = CGSize(width: max(400, CGFloat(ranks.count) * colW),
                          height: max(200, contentH + nodeH))
        return out
    }


    /// Iterative Tarjan SCC. Edges go dependent -> prerequisite, which is fine: an SCC is
    /// symmetric, so direction only matters for the condensation step above.
    private func runTarjan(nodes: [String], prereqs: [String: [String]],
                           sccOf: inout [String: Int], members: inout [Int: [String]]) {
        var index: [String: Int] = [:]
        var low: [String: Int] = [:]
        var onStack = Set<String>()
        var stack: [String] = []
        var next = 0
        var sccCount = 0

        for root in nodes where index[root] == nil {
            var work: [(String, Int)] = [(root, 0)]
            while let (v, pi) = work.popLast() {
                if pi == 0 {
                    index[v] = next; low[v] = next; next += 1
                    stack.append(v); onStack.insert(v)
                }
                let succ = prereqs[v] ?? []
                var advanced = false
                var i = pi
                while i < succ.count {
                    let w = succ[i]
                    if index[w] == nil {
                        work.append((v, i + 1))
                        work.append((w, 0))
                        advanced = true
                        break
                    } else if onStack.contains(w) {
                        low[v] = min(low[v]!, index[w]!)
                    }
                    i += 1
                }
                if advanced { continue }
                if low[v] == index[v] {
                    var comp: [String] = []
                    while let w = stack.popLast() {
                        onStack.remove(w)
                        comp.append(w)
                        sccOf[w] = sccCount
                        if w == v { break }
                    }
                    members[sccCount] = comp
                    sccCount += 1
                }
                if let (parent, _) = work.last {
                    low[parent] = min(low[parent] ?? Int.max, low[v] ?? Int.max)
                }
            }
        }
    }

    private func severity(_ s: String) -> Int {
        ["REFUTED": 0, "CONTESTED": 1, "TAINTED": 2, "BLOCKED": 3,
         "UNVERIFIED": 4, "OPEN": 5, "VERIFIED": 6, "DONE": 7][s] ?? 8
    }

    private func strokeStyle(for kind: String) -> (color: Color, width: CGFloat, dash: [CGFloat]) {
        switch kind {
        case "requires": return (.secondary, 1.5, [])
        case "depends_on": return (.secondary, 1.0, [])
        case "cites": return (.blue.opacity(0.6), 1.0, [4, 3])
        case "assumes": return (.orange, 1.2, [2, 3])
        case "contradicts": return (.red, 2.0, [])
        default: return (Color.secondary.opacity(0.35), 1.0, [])
        }
    }
}

struct NodeCard: View {
    let node: RealmNode
    let store: LensStore
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(store.glyph(node))
                .font(.system(.body, design: .monospaced).bold())
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(node.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(node.kind.rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Text(node.title).font(.caption).lineLimit(1)
            }
            Spacer(minLength: 0)
            if node.tainted {
                Text("!").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                                               lineWidth: selected ? 2 : 1))
        .help("\(node.id) — \(store.statusText(node))")
    }

    private var color: Color {
        switch store.statusText(node) {
        case "REFUTED": return .red
        case "CONTESTED": return .pink
        case "TAINTED": return .orange
        case "BLOCKED": return .yellow
        case "VERIFIED", "DONE": return .green
        default: return .secondary
        }
    }

    private var background: Color {
        selected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor)
    }
}
