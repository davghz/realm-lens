// RopeCanvas — the tethers between agent panes and the orchestrator dock.
//
// One cubic bezier per anchor, entering the dock rail at an evenly spaced y in
// `anchors` order. Geometry is a pure function of `anchors` and `dock`: no jitter,
// no randomness, no animation. Callers hand anchors in pane order (top to bottom);
// because both endpoints and both control points keep that order, the curves nest
// in the shared corridor instead of crossing each other.
//
// Status is never colour alone. Width, dash pattern, an expiring dot, and the
// monospaced lease tick at the dock end all vary with it, so the ropes survive
// greyscale as well as the dock rows do.
//
// Intentionally self-contained: no RealmLensCore types, no AppKit, no resources.

import SwiftUI
import Foundation

struct RopeAnchor: Identifiable, Equatable {
    let agent: String        // e.g. "opencode"
    let origin: CGPoint      // top-leading corner of that agent's terminal pane, canvas coords
    let status: RopeStatus
    var id: String { agent }
}

enum RopeStatus: Equatable {
    case active(lease: String)   // holds a live lease
    case expiring(lease: String) // live lease with < 120s left
    case stalled(lease: String)  // lease exists but expired
    case idle                    // no lease
}

struct OrchestratorDock: Equatable {
    let leading: CGRect      // the dock rail on the left edge of the orchestrator panel
}

struct RopeCanvas: View {
    let anchors: [RopeAnchor]
    let dock: OrchestratorDock
    /// Accepted for parity with the rest of the app. This view has no animation, so
    /// reduced motion renders exactly the same static geometry — there is nothing to
    /// suppress, and the parameter exists so the call site never has to special-case it.
    var reduceMotion: Bool = false

    // Curve furniture. Sizes are deliberately small: the dock rail is only a few
    // points wide, and the ropes must not compete with the pane content.
    private let thimbleRadius: CGFloat = 4
    private let chevronLength: CGFloat = 5
    private let chevronHalfHeight: CGFloat = 3
    private let expiryDotInset: CGFloat = 18
    private let expiryBeadLift: CGFloat = 4
    private let labelGap: CGFloat = 14
    private let labelWidth: CGFloat = 64
    private let labelHeight: CGFloat = 14
    private let labelRailGap: CGFloat = 18
    /// Labels sit just below the entry point. Every cubic here approaches the rail
    /// from above, so dropping the chip by a few points guarantees the stroke never
    /// strikes through the glyphs — no backdrop fill (and no guessed background
    /// colour) is needed to keep the caption readable. Nine points clears the deepest
    /// approach (~5 pt at the left edge of the chip) plus the glyph's top inset.
    private let labelDrop: CGFloat = 9

    init(anchors: [RopeAnchor], dock: OrchestratorDock, reduceMotion: Bool = false) {
        self.anchors = anchors
        self.dock = dock
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        let entries = dockEntries
        let labels = labelPlans(for: entries)
        let scrims = labels.filter(\.showsScrim)

        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                drawDock(in: &ctx)
                for entry in entries {
                    drawRope(entry, in: &ctx)
                }
                // A tight rail can thread a neighbouring rope through a label's text
                // box. Painted after the ropes and before the text, in the same
                // secondary tint as a translucent backing: the label stays legible
                // without importing AppKit for the exact control background colour.
                for label in scrims {
                    let rect = CGRect(x: labelCenterX - labelWidth / 2,
                                      y: label.y - labelHeight / 2,
                                      width: labelWidth, height: labelHeight)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(Color.secondary.opacity(0.22)))
                }
            }
            ForEach(labels) { label in
                labelView(label)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // ---------------------------------------------------------------- geometry

    private struct DockEntry {
        let index: Int
        let anchor: RopeAnchor
        let point: CGPoint
    }

    /// Dock end points. A single anchor lands in the middle of the rail; otherwise
    /// the rail is split into equal bands and each rope enters at a band centre. The
    /// half-band inset keeps the first and last ropes off the rail's very corners,
    /// which is what makes the chevrons readable when the rail is short.
    private var dockEntries: [DockEntry] {
        let count = anchors.count
        guard count > 0 else { return [] }

        let rail = dock.leading
        let inset = min(6, max(0, rail.height / 3))
        let usable = max(0, rail.height - inset * 2)

        return anchors.enumerated().map { index, anchor in
            let y: CGFloat
            if count == 1 {
                y = rail.midY
            } else {
                y = rail.minY + inset
                    + usable * (CGFloat(index) + 0.5) / CGFloat(count)
            }
            return DockEntry(index: index, anchor: anchor, point: CGPoint(x: rail.minX, y: y))
        }
    }

    /// Control-point bow for an anchor. The primary offset is the contract's 40% of
    /// the horizontal run; the index term pushes later (lower) ropes further right
    /// and then pulls their second control point further back, so the curves fan into
    /// nested arcs rather than collapsing onto one another in the corridor.
    ///
    /// The index term is capped at 15% of the run so that a very short rope cannot
    /// fold its control points past each other. Capping preserves the ordering of the
    /// curves; it only limits how far apart they bow.
    private func bow(for index: Int, horizontal: CGFloat) -> CGFloat {
        min(CGFloat(index) * 2, horizontal * 0.15)
    }

    // ---------------------------------------------------------------- drawing

    private func drawDock(in ctx: inout GraphicsContext) {
        let rail = dock.leading
        guard rail.width > 0, rail.height > 0 else { return }

        // The rail is drawn here so a canvas with zero anchors still shows the dock.
        // TerminalGrid also paints a rule at the same rect; the fill is kept light so
        // the two composite into a subtle tint rather than a hard double-darkened bar.
        let path = Path(roundedRect: rail, cornerRadius: min(2, rail.width / 2))
        ctx.fill(path, with: .color(Color.secondary.opacity(0.12)))
        ctx.stroke(path, with: .color(Color.secondary.opacity(0.28)),
                   style: StrokeStyle(lineWidth: 0.5))
    }

    private func drawRope(_ entry: DockEntry, in ctx: inout GraphicsContext) {
        let start = entry.anchor.origin
        let end = entry.point
        let style = ropeStyle(entry.anchor.status)

        // The dock is to the right of the panes by the grid's contract. Using the
        // actual run — with a 1 pt floor — rather than padding it to a minimum keeps
        // the control points ordered left-to-right, so x(t) stays monotone and a rope
        // can never double back. A pane nudged almost against the rail gets a steep,
        // short curve, which is still readable.
        let horizontal = max(1, end.x - start.x)
        let bow = bow(for: entry.index, horizontal: horizontal)

        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + horizontal * 0.4 + bow, y: start.y),
            control2: CGPoint(x: end.x - horizontal * 0.25 - bow, y: end.y)
        )
        ctx.stroke(path, with: .color(style.color),
                   style: StrokeStyle(lineWidth: style.width,
                                      lineCap: .round,
                                      lineJoin: .round,
                                      dash: style.dash))

        // Where the rope leaves the pane: a small thimble. Its faint fill keeps the
        // ring legible over a dark terminal background without hiding the pane's text.
        let outer = CGRect(x: start.x - thimbleRadius, y: start.y - thimbleRadius,
                           width: thimbleRadius * 2, height: thimbleRadius * 2)
        ctx.fill(Path(ellipseIn: outer), with: .color(style.color.opacity(0.18)))
        ctx.stroke(Path(ellipseIn: outer), with: .color(style.color),
                   style: StrokeStyle(lineWidth: 1.2))
        let pin = CGRect(x: start.x - 1.5, y: start.y - 1.5, width: 3, height: 3)
        ctx.fill(Path(ellipseIn: pin), with: .color(style.color))

        // Where it meets the dock: a chevron pointing into the rail.
        var chevron = Path()
        chevron.move(to: CGPoint(x: end.x - chevronLength, y: end.y - chevronHalfHeight))
        chevron.addLine(to: end)
        chevron.addLine(to: CGPoint(x: end.x - chevronLength, y: end.y + chevronHalfHeight))
        ctx.stroke(chevron, with: .color(style.color),
                   style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))

        // Expiring leases get a bead a fixed distance back along the rope ITSELF,
        // offset along the curve's normal. A dot centred on a solid stroke of the same
        // colour is invisible in silhouette and in greyscale, so it is lifted into
        // clear space; following the normal (rather than straight up) keeps the bead
        // attached to the rope on steep approaches too.
        if case .expiring = entry.anchor.status {
            let p1 = CGPoint(x: start.x + horizontal * 0.4 + bow, y: start.y)
            let p2 = CGPoint(x: end.x - horizontal * 0.25 - bow, y: end.y)
            let bead = expiryBeadPoint(start: start, c1: p1, c2: p2, end: end)
            let rect = CGRect(x: bead.x - 2.5, y: bead.y - 2.5, width: 5, height: 5)
            ctx.fill(Path(ellipseIn: rect), with: .color(style.color))
        }
    }

    /// Point on the rope about `expiryDotInset` points before the dock, pushed off the
    /// stroke along the local normal. Solved by bisection on t: x is monotone for this
    /// curve, so the parameter whose x lands on the target is unique.
    private func expiryBeadPoint(start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint) -> CGPoint {
        let targetX = max(start.x + 2, end.x - expiryDotInset)

        var lo: CGFloat = 0
        var hi: CGFloat = 1
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            if cubicX(mid, start: start, c1: c1, c2: c2, end: end) < targetX {
                lo = mid
            } else {
                hi = mid
            }
        }
        let t = (lo + hi) / 2
        let point = cubicPoint(t, start: start, c1: c1, c2: c2, end: end)
        let tangent = cubicTangent(t, start: start, c1: c1, c2: c2, end: end)

        let length = max(0.0001, (tangent.x * tangent.x + tangent.y * tangent.y).squareRoot())
        // Normal is the tangent rotated by -90°; pick the side that points up on
        // screen so the bead always sits above the line regardless of direction.
        var nx = tangent.y / length
        var ny = -tangent.x / length
        if ny > 0 { nx = -nx; ny = -ny }
        return CGPoint(x: point.x + nx * expiryBeadLift, y: point.y + ny * expiryBeadLift)
    }

    private func cubicX(_ t: CGFloat, start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint) -> CGFloat {
        cubicPoint(t, start: start, c1: c1, c2: c2, end: end).x
    }

    private func cubicPoint(_ t: CGFloat, start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint) -> CGPoint {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return CGPoint(x: a * start.x + b * c1.x + c * c2.x + d * end.x,
                       y: a * start.y + b * c1.y + c * c2.y + d * end.y)
    }

    private func cubicTangent(_ t: CGFloat, start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint) -> CGPoint {
        let u = 1 - t
        let a = 3 * u * u
        let b = 6 * u * t
        let c = 3 * t * t
        return CGPoint(x: a * (c1.x - start.x) + b * (c2.x - c1.x) + c * (end.x - c2.x),
                       y: a * (c1.y - start.y) + b * (c2.y - c1.y) + c * (end.y - c2.y))
    }

    private struct RopeStyle {
        let color: Color
        let width: CGFloat
        let dash: [CGFloat]
    }

    private func ropeStyle(_ status: RopeStatus) -> RopeStyle {
        switch status {
        case .active:
            return RopeStyle(color: .green, width: 1.5, dash: [])
        case .expiring:
            return RopeStyle(color: .orange, width: 1.5, dash: [])
        case .stalled:
            return RopeStyle(color: .secondary, width: 1.0, dash: [6, 4])
        case .idle:
            return RopeStyle(color: .secondary.opacity(0.35), width: 1.0, dash: [])
        }
    }

    // ---------------------------------------------------------------- labels

    private struct RopeLabel: Identifiable {
        let id: Int
        let text: String
        let y: CGFloat
        /// True when the rail is tight enough that a *neighbouring* rope could pass
        /// through this label's text box; the caption then needs a backing scrim.
        let showsScrim: Bool
    }

    /// Every rope's lease id (or an em dash for idle). Dense rails thin to every
    /// second/third label rather than shrinking the type: a missing label is fine,
    /// an unreadable one is not. The stride is computed from the actual rail pitch,
    /// then the nudge pass guarantees the 14 pt minimum on whatever remains.
    private func labelPlans(for entries: [DockEntry]) -> [RopeLabel] {
        guard !entries.isEmpty, dock.leading.height > 0 else { return [] }

        let stride = labelStride
        // A label box spans roughly `labelDrop - labelHeight/2` to
        // `labelDrop + labelHeight/2` below its entry, so once the pitch falls under
        // ~18 pt the next rope can thread through the glyphs. Only then pay for a scrim.
        let showsScrim = railPitch < 18
        var plans: [RopeLabel] = []
        var lastY: CGFloat?

        for entry in entries where entry.index % stride == 0 {
            var y = entry.point.y + labelDrop
            if let lastY, y < lastY + labelGap {
                y = lastY + labelGap
            }
            // On a very short rail the nudge can walk the tail of the list past the
            // foot of the rail. Drop those labels instead of stacking or clipping
            // them; fewer labels still communicate, collided ones do not.
            if !plans.isEmpty, y > dock.leading.maxY + 8 { continue }
            plans.append(RopeLabel(id: entry.index,
                                   text: labelText(entry.anchor.status),
                                   y: y,
                                   showsScrim: showsScrim))
            lastY = y
        }
        return plans
    }

    private var railPitch: CGFloat {
        guard !anchors.isEmpty, dock.leading.height > 0 else { return .infinity }
        return dock.leading.height / CGFloat(anchors.count)
    }

    private var labelStride: Int {
        guard !anchors.isEmpty, dock.leading.height > 0 else { return 1 }
        return max(1, Int(ceil(labelGap / railPitch)))
    }

    private func labelText(_ status: RopeStatus) -> String {
        switch status {
        case .active(let lease), .expiring(let lease), .stalled(let lease):
            let trimmed = lease.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "—" : trimmed
        case .idle:
            return "—"
        }
    }

    private func labelView(_ label: RopeLabel) -> some View {
        Text(label.text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: labelWidth, height: labelHeight, alignment: .trailing)
            .position(x: labelCenterX, y: label.y)
            .help(label.text)
            .accessibilityLabel(label.text == "—" ? "No lease" : "Lease \(label.text)")
    }

    private var labelCenterX: CGFloat {
        // Right edge sits `labelRailGap` points left of the rail, clear of both the
        // chevron and the expiring dot. The lower bound keeps the text on-screen when
        // the dock is hugged against the left edge of a narrow window.
        max(labelWidth / 2 + 2, dock.leading.minX - labelRailGap - labelWidth / 2)
    }

    // ---------------------------------------------------------------- preview data

    /// Deterministic sample data for smoke tests, with no live space required.
    /// Statuses cycle active → expiring → stalled → idle; origins form one column so
    /// the nested-curve property is obvious at a glance. Leases are named T001…,
    /// matching the reader's task-id style.
    static func previewAnchors(_ n: Int) -> [RopeAnchor] {
        let count = max(0, n)
        let agents = ["opencode", "claude", "codex", "gemini", "amp", "cursor"]

        return (0..<count).map { index in
            let lease = "T" + String(format: "%03d", index + 1)
            let status: RopeStatus
            switch index % 4 {
            case 0: status = .active(lease: lease)
            case 1: status = .expiring(lease: lease)
            case 2: status = .stalled(lease: lease)
            default: status = .idle
            }
            return RopeAnchor(agent: "\(agents[index % agents.count])-\(index + 1)",
                              origin: CGPoint(x: 48, y: 32 + CGFloat(index) * 52),
                              status: status)
        }
    }
}
