// TerminalGrid — the left side of the window: a vertical stack of agent panes, each
// tethered by a rope to the orchestrator dock on the right.
//
// Layout is deliberately ONE column, not a grid.
//
// A multi-column grid was the obvious first shape and it is wrong here: a rope leaving a
// pane in column 0 must cross the pane in column 1 (and 2) to reach the dock, so it is
// drawn over live terminal text or it has to be hidden behind it. Either way the tether
// stops being readable at exactly the moment it matters.
//
// Stacked vertically, every pane owns a distinct horizontal band, so every rope has a
// clear corridor to the dock and no two ropes can cross. The cost is that panes get
// shorter as agents are added; the stack scrolls below a usable minimum rather than
// squeezing terminal text to nothing.

import SwiftUI
import RealmLensCore

/// Coordinate space shared by the panes and the rope canvas. One name, so an anchor
/// recorded by a pane and a dock rect measured by the grid cannot drift apart.
enum GridSpace {
    static let name = "realm.terminalGrid"
}

struct TerminalGrid: View {
    var agents: AgentsStore
    @Environment(LensStore.self) private var lens

    /// Raw SwiftUI anchors from the panes. Kept unresolved: an `Anchor` is only valid
    /// against the `GeometryProxy` it was read from, so converting to CGPoint during a
    /// preference callback and caching it across a resize produced stale rope ends.
    @State private var paneAnchors: [String: Anchor<CGRect>] = [:]

    /// Corridor between the panes and the dock rail. Wide enough for a rope to be
    /// visibly a curve rather than a straight tick.
    private let ropeGutter: CGFloat = 76
    /// Thumbnail column sizing, shared by layout and leader.
    static let thumbFraction: CGFloat = 0.32
    static let minThumbWidth: CGFloat = 150
    static let maxThumbWidth: CGFloat = 240
    private let paneGap: CGFloat = 10
    private let dockInset: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let layout = PaneLayout(outerWidth: geo.size.width,
                                    ropeGutter: ropeGutter, dockInset: dockInset,
                                    paneGap: paneGap,
                                    minThumbWidth: Self.minThumbWidth,
                                    maxThumbWidth: Self.maxThumbWidth,
                                    thumbFraction: Self.thumbFraction)
            let railX = layout.railX

            ZStack(alignment: .topLeading) {
                // The dock rail: a thin vertical rule the ropes terminate on. Drawn
                // first so rope ends sit on top of it rather than under it.
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 3, height: max(0, geo.size.height - 2 * dockInset))
                    .offset(x: railX, y: dockInset)

                paneStack(layout: layout)
                    .frame(width: layout.paneWidth, alignment: .topLeading)

                // Every rope enters this one corridor and travels right along it. Because
                // each anchor is a point ON the corridor's left edge (a "portal"), the
                // corridor is empty of panes by construction, no rope can begin behind a
                // card, and ordering the dock by portal Y makes crossings impossible.
                // Leader lines for panes that cannot reach the corridor directly. Only the
                // hero needs one: thumbnails adjoin the corridor on their right edge.
                HeroLeader(geometry: leaderGeometry(in: geo))
                    .allowsHitTesting(false)

                RopeLayer(anchors: resolve(paneAnchors, in: geo),
                          dock: OrchestratorDock(
                            leading: CGRect(x: railX, y: dockInset,
                                            width: 3, height: max(0, geo.size.height - 2 * dockInset))))

                if agents.displayedHosts.isEmpty {
                    emptyState.frame(width: max(120, geo.size.width - ropeGutter))
                }
            }
            .coordinateSpace(name: GridSpace.name)
            .onPreferenceChange(PaneAnchorKey.self) { prefs in
                paneAnchors = prefs
            }
        }
    }

    // MARK: panes

    /// Minimum height for a terminal to be readable at 11pt monospaced: about 12 lines.
    private static let minPaneHeight: CGFloat = 150
    /// Height of a collapsed pane. The header is ~22pt; this adds a one-line preview so a
    /// strip is not just a label, but stays out of the way of the focused pane.
    private static let stripHeight: CGFloat = 22

    /// A minimized pane needs its header (~24pt) plus about five preview lines (~55pt) to
    /// carry any information at all. Below this the column scrolls rather than shrinking.
    private static let minThumbHeight: CGFloat = 90

    /// Horizontal lane reserved above the thumbnail column for the hero's rope. No card
    /// occupies this band, so the rope can cross the column without passing behind a pane.
    private static let heroLaneHeight: CGFloat = 20

    /// Layout: hero pane on the left, ONE column of minimized thumbnails on the right,
    /// and a reserved horizontal lane above the thumbnails for the hero's rope.
    ///
    /// Why one column and a lane, rather than a thumbnail grid: a rope must be traceable
    /// from the card it belongs to into the corridor. With two thumbnail columns the hero's
    /// exit corner lands INSIDE the second column, so its rope either starts behind a card
    /// or has to be routed around one. Measured at 7 panes / 730pt wide: hero width 413.7,
    /// thumbnail columns at x 0..104 and 114..218, hero corner x=413.7 — inside the cards.
    ///
    /// With one column the geometry is unambiguous:
    ///   * every thumbnail's right edge is adjacent to the corridor, so its rope is a short
    ///     horizontal run at its own vertical centre;
    ///   * the hero's rope crosses the thumbnail column through a RESERVED LANE that holds
    ///     no cards, so it cannot pass behind one;
    ///   * all portals share one x and the dock is ordered by portal y, so ropes nest.
    private func paneStack(layout: PaneLayout) -> some View {
        GeometryReader { geo in
            let focusedName = agents.focused ?? agents.displayedHosts.first?.spec.name
            let ordered = orderedHosts(focused: focusedName)
            let others = Array(ordered.dropFirst())
            let othersCount = others.count

            // Widths come from PaneLayout, the same value the leader uses. Deriving them
            // here independently is what produced the 59.84pt disagreement.
            let thumbWidth = layout.thumbWidth
            let focusWidth = othersCount > 0 ? layout.heroWidth : layout.paneWidth
            let lane: CGFloat = othersCount > 0 ? Self.heroLaneHeight : 0
            let thumbArea = max(0, geo.size.height - lane)
            // One column: a thumbnail below the legible minimum would not be worth a row,
            // so past that the column scrolls rather than shrinking further.
            let usableRows = max(1, Int((thumbArea + paneGap) / (Self.minThumbHeight + paneGap)))
            let thumbHeight = max(Self.minThumbHeight,
                                  (thumbArea - paneGap * CGFloat(min(othersCount, usableRows) - 1))
                                  / CGFloat(max(1, min(othersCount, usableRows))))
            let totalNeeded = CGFloat(othersCount) * thumbHeight
                              + paneGap * CGFloat(max(0, othersCount - 1))
            let scrolls = totalNeeded > thumbArea + 0.5

            HStack(alignment: .top, spacing: paneGap) {
                if let hero = ordered.first {
                    PaneCard(
                        host: hero,
                        isFocused: true,
                        onFocus: { agents.focused = hero.spec.name },
                        onClose: { agents.remove(hero.spec.name) },
                        onRestart: { agents.restart(hero.spec.name) },
                        minimized: false
                    )
                    .frame(width: focusWidth, height: geo.size.height)
                }
                if othersCount > 0 {
                    // The reserved lane lives OUTSIDE the scroll viewport. Padding the
                    // scrolled content instead meant that scrolling dragged cards up into
                    // the lane, so a visible card overlapped the corridor the hero's rope
                    // runs through. At N=9/H=788 with an 80pt offset the first card sat at
                    // -60 and its portal at -9.4, above a "reserved" lane that was not
                    // reserved at all.
                    VStack(spacing: 0) {
                        Color.clear.frame(height: lane)
                        if scrolls {
                            ScrollView(.vertical) {
                                VStack(spacing: paneGap) {
                                    ForEach(others, id: \.spec.name) { host in
                                        card(host, thumbWidth: thumbWidth,
                                             thumbHeight: thumbHeight)
                                    }
                                }
                            }
                            .frame(width: thumbWidth,
                                   height: max(0, geo.size.height - lane))
                        } else {
                            VStack(spacing: paneGap) {
                                ForEach(others, id: \.spec.name) { host in
                                    card(host, thumbWidth: thumbWidth,
                                         thumbHeight: thumbHeight)
                                }
                            }
                            .frame(width: thumbWidth, height: max(0, geo.size.height - lane),
                                   alignment: .top)
                        }
                    }
                    .frame(width: thumbWidth, height: geo.size.height, alignment: .top)
                }
            }
        }
    }

    /// Where the hero's leader line runs, derived from real layout constants so it cannot
    /// drift from the cards it must avoid.
    struct LeaderGeometry: Equatable {
        var start: CGPoint      // hero's trailing centre
        var gapX: CGFloat       // centre of the inter-card gap
        var laneY: CGFloat      // centre of the reserved lane
        var end: CGPoint        // corridor entry, where RopeCanvas takes over
        var active: Bool
    }

    private func leaderGeometry(in geo: GeometryProxy) -> LeaderGeometry? {
        guard agents.displayedHosts.count > 1 else { return nil }   // single pane needs no leader
        // Use the SAME layout the panes are built from. Recomputing the hero width from the
        // outer geometry instead of the pane width was a 59.84pt error at G=730, which put
        // the leader's vertical run 54.8pt inside the thumbnail column.
        let layout = PaneLayout(outerWidth: geo.size.width,
                                ropeGutter: ropeGutter,
                                dockInset: dockInset,
                                paneGap: paneGap,
                                minThumbWidth: Self.minThumbWidth,
                                maxThumbWidth: Self.maxThumbWidth,
                                thumbFraction: Self.thumbFraction)
        let laneY = Self.heroLaneHeight / 2
        // Hero starts on its own trailing edge, at its vertical centre.
        let start = CGPoint(x: layout.heroWidth, y: geo.size.height / 2)
        // The vertical run happens in the inter-card gap, which is immediately right of the
        // hero and left of the thumbnail column.
        let gapX = layout.heroWidth + paneGap / 2
        // The corridor entry is level with the lane, so the rope joins the corridor high
        // and clear of every card.
        let end = CGPoint(x: layout.corridorLeftX, y: laneY)
        return LeaderGeometry(start: start, gapX: gapX, laneY: laneY, end: end, active: true)
    }

    @ViewBuilder
    private func card(_ host: TerminalHost, thumbWidth: CGFloat,
                      thumbHeight: CGFloat) -> some View {
        PaneCard(
            host: host,
            isFocused: false,
            onFocus: { agents.focused = host.spec.name },
            onClose: { agents.remove(host.spec.name) },
            onRestart: { agents.restart(host.spec.name) },
            minimized: true
        )
        .frame(width: thumbWidth, height: thumbHeight)
    }

    /// Focused pane FIRST, then the rest in stable roster order. Putting the expanded pane
    /// at the top means the reading position never shifts when focus changes, and the
    /// strips read as a list of the other agents rather than as a random remainder.
    private func orderedHosts(focused: String?) -> [TerminalHost] {
        guard let focused,
              let idx = agents.displayedHosts.firstIndex(where: { $0.spec.name == focused })
        else { return agents.displayedHosts }
        var out = agents.displayedHosts
        let hero = out.remove(at: idx)
        out.insert(hero, at: 0)
        return out
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No terminal panes").font(.headline).foregroundStyle(.secondary)
            Text("Add a pane to open an interactive agent CLI.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: anchors

    /// Turns SwiftUI anchors into plain points, pairing each with its lease status.
    /// Status comes from the SPACE (leases), not from the process: an agent can be alive
    /// and idle, and a rope that lit up merely because a process existed would be noise.
    private func resolve(_ prefs: [String: Anchor<CGRect>], in geo: GeometryProxy) -> [RopeAnchor] {
        // Left edge of the CORRIDOR, not the rail. The rail is at width-dockInset; the
        // corridor starts one ropeGutter to its left, at the right edge of the pane area.
        // Using the rail position collapsed the corridor to zero width.
        let corridorLeftX = PaneLayout(outerWidth: geo.size.width,
                                       ropeGutter: ropeGutter, dockInset: dockInset,
                                       paneGap: paneGap,
                                       minThumbWidth: Self.minThumbWidth,
                                       maxThumbWidth: Self.maxThumbWidth,
                                       thumbFraction: Self.thumbFraction).corridorLeftX
        let now = lens.clock
        let map = agents.leaseMap(from: lens.leases, now: now)
        // SAME order as the visual stack. The dock distributes entry points by array
        // position, so resolving in storage order while drawing focus-first made the
        // origins visual-ordered and the dock roster-ordered — every focus change on a
        // non-first pane forced the ropes to cross.
        let visual = orderedHosts(focused: agents.focused ?? agents.displayedHosts.first?.spec.name)
        let built = visual.compactMap { host -> RopeAnchor? in
            guard let anchor = prefs[host.spec.name] else { return nil }
            let status: RopeStatus
            if let entry = map[host.spec.name] {
                if !entry.live {
                    status = .stalled(lease: entry.resource)
                } else if entry.remaining < 120 {
                    status = .expiring(lease: entry.resource)
                } else {
                    status = .active(lease: entry.resource)
                }
            } else {
                status = .idle
            }
            // Portal on the corridor's left edge, at the card's own top corner height.
            // Not the card's corner itself: a card corner can sit INSIDE a neighbouring
            // thumbnail column, which drew the rope behind a pane. All portals share one
            // x, so ordering them by y guarantees ropes cannot cross in the corridor.
            // Portal on the corridor's left edge at the card's own vertical centre. Using
            // the card's real bounds (not a recomputed height) keeps this correct through
            // the hero lane, the scroll view and any future inset.
            let rect = geo[anchor]
            let isHero = host.spec.name == (agents.focused ?? agents.displayedHosts.first?.spec.name)
            // A scrolled-away card still reports a rect, often above the lane or below the
            // viewport. Its portal must be CLAMPED into the corridor's usable band, or the
            // rope is routed from a point no visible card owns. Cards whose centre is
            // outside the band contribute no rope at all: a tether to nothing misleads.
            let bandTop = Self.heroLaneHeight
            let bandBottom = max(bandTop, geo.size.height)
            let centreY = rect.midY
            guard centreY >= bandTop - 1, centreY <= bandBottom + 1 else { return nil }
            let clampedY = min(max(centreY, bandTop), bandBottom)
            let portal: CGPoint
            if isHero, agents.displayedHosts.count > 1 {
                // The hero reaches the corridor via its leader line, which ends at the lane
                // height. Starting the rope at the card centre instead would leave the
                // leader dangling and the corridor unused.
                portal = CGPoint(x: corridorLeftX, y: Self.heroLaneHeight / 2)
            } else {
                portal = CGPoint(x: corridorLeftX, y: clampedY)
            }
            return RopeAnchor(agent: host.spec.name, origin: portal, status: status)
        }
        // Order by PORTAL position, not by roster or fill order. The dock distributes its
        // entry points by array index, so two ropes whose portals are inverted relative to
        // their dock slots must cross. Sorting here makes dock order equal visual order,
        // and since every portal shares one x, y-ordering can never cross.
        return built.sorted { $0.origin.y < $1.origin.y }
    }
}

/// The grid's horizontal layout, computed once and shared by the panes, the ropes and the
/// leader. Two separate derivations of "how wide is the hero" disagreed by 59.84pt at
/// G=730; one value makes that class of bug impossible.
struct PaneLayout: Equatable {
    let outerWidth: CGFloat
    let paneWidth: CGFloat        // width available to the pane stack
    let thumbWidth: CGFloat
    let heroWidth: CGFloat
    let corridorLeftX: CGFloat
    let railX: CGFloat

    init(outerWidth: CGFloat, ropeGutter: CGFloat, dockInset: CGFloat, paneGap: CGFloat,
         minThumbWidth: CGFloat, maxThumbWidth: CGFloat, thumbFraction: CGFloat) {
        self.outerWidth = outerWidth
        self.paneWidth = max(0, outerWidth - ropeGutter - dockInset)
        self.thumbWidth = min(maxThumbWidth, max(minThumbWidth, paneWidth * thumbFraction))
        self.heroWidth = max(0, paneWidth - thumbWidth - paneGap)
        self.corridorLeftX = max(0, outerWidth - ropeGutter - dockInset)
        self.railX = max(0, outerWidth - dockInset)
    }
}

/// Bridges the rope renderer into the grid's ZStack without importing the rope file's
/// internals. Kept separate so `RopeCanvas` stays a pure, testable view.
struct RopeLayer: View {
    let anchors: [RopeAnchor]
    let dock: OrchestratorDock

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RopeCanvas(anchors: anchors, dock: dock, reduceMotion: reduceMotion)
            .allowsHitTesting(false)
    }
}

/// The hero's route from its own card into the corridor.
///
/// Drawn as a rounded elbow rather than a bezier because every segment must be provably
/// clear of the thumbnail column: a curve would bulge into the cards by an amount that
/// depends on the control points, and "looks like it misses" is not a guarantee.
struct HeroLeader: View {
    let geometry: TerminalGrid.LeaderGeometry?

    var body: some View {
        if let g = geometry {
            Path { path in
                path.move(to: g.start)
                // 1. out of the card into the inter-card gap
                path.addLine(to: CGPoint(x: g.gapX, y: g.start.y))
                // 2. up the gap to the reserved lane (no card occupies this column)
                path.addLine(to: CGPoint(x: g.gapX, y: g.laneY))
                // 3. along the lane to the corridor entry
                path.addLine(to: g.end)
            }
            .stroke(Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
    }
}
