//
//  FieldView.swift
//  flow
//
//  The unified infinite canvas — Phase 1 step #4.
//
//  One pannable / pinch-zoomable plane that holds the active sketch
//  frame at field origin and every captured snapshot at its (x, y).
//
//  Visual language is borrowed from Figma:
//
//   • A neutral medium-light gray "infinite paper" backdrop, not
//     white — so the white frames read as paper sitting on a desk.
//   • A faint dot grid in the field's coordinate space gives the
//     plane a sense of scale and motion when panning / zooming.
//   • Frames have no border in their resting state. They sit on
//     the backdrop on a small drop shadow, the way Figma frames do.
//   • The active sketch frame gets a subtle accent-colored outline
//     so the user can tell at a glance which one is editable.
//   • Each frame has a small label floating above it: "Sketch" for
//     the live area, "Snapshot 1", "Snapshot 2", … for the captures.
//
//  Coordinate systems (unchanged from earlier — see ../Model for
//  details): field coords, screen coords, sketch-local coords.
//

import SwiftUI
import AutomergeRepo

struct FieldView: View {

    @ObservedObject var store: BoardStore

    /// Sync identity for the board this view is showing. Passed
    /// down to `CanvasView` so its presence broadcasts get routed
    /// per-board, and used to filter received presence so we only
    /// render cursors / overlays for peers on *this* board.
    let documentId: DocumentId

    /// Presence channel for the app. Optional so this view can be
    /// previewed in isolation; production wires it from
    /// `BoardLibrary.presence`.
    @ObservedObject var presence: PresenceCoordinator

    /// Currently selected drawing tool. Bound from
    /// `BoardOpenView` so the floating toolbar pill and the
    /// drawing surface share the same selection.
    @Binding var tool: DrawingTool

    /// Active pen color (and the color used to render in-progress
    /// previews of the user's own strokes).
    @Binding var color: UInt32

    /// Active stroke width.
    @Binding var width: Double

    /// Whether the user has locally asked to see the sketch frame.
    /// True OR a non-empty active sketch (e.g. a peer is drawing)
    /// reveals the frame; otherwise the field shows snapshots only.
    @Binding var sketchOpenedLocally: Bool

    /// Snapshot currently being edited, if any. Set by tapping
    /// a snapshot tile; cleared by tapping a "Done" affordance
    /// on the edited tile. When set, the tool pill shows and
    /// drawing/erasing route to that snapshot's strokes list.
    @State private var editingSnapshotId: UUID?

    /// Logical size of the active sketch and of each snapshot tile.
    static let sketchSize = CGSize(width: 800, height: 600)

    /// Spacing between the major dot-grid points. Picked so the
    /// dots are visible but not noisy at scale = 1.
    private static let gridSpacing: CGFloat = 24

    /// Pixel offset of each frame's title above its top edge.
    private static let titleHeight: CGFloat = 22

    // MARK: - View state

    @State private var pan: CGSize = .zero
    @State private var pendingPan: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var pendingScale: CGFloat = 1.0
    @State private var draggingSnapshot: (id: UUID, translation: CGSize)?
    @State private var didCenter = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 1. Backdrop. Pan-gesture target so taps on empty
                //    field pan the whole plane.
                Color(red: 0.91, green: 0.91, blue: 0.93)
                    .contentShape(Rectangle())
                    .gesture(panGesture)

                // 2. Everything that lives "on" the plane:
                //    grid + sketch + snapshots, all transformed
                //    together so they pan and zoom as one piece.
                content(in: geo.size)
                    .scaleEffect(currentScale, anchor: .topLeading)
                    .offset(currentPan)
                    .allowsHitTesting(true)
            }
            .clipped()
            .simultaneousGesture(magnifyGesture)
            .onAppear { centerSketchOnce(in: geo.size) }
        }
        // safeAreaInset puts the pill above the home indicator
        // (and any future bottom system chrome) by inserting it
        // *into* the safe area rather than overlaying at the raw
        // bottom edge — that's where the previous .overlay version
        // disappeared on iPad.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The drawing tool pill only makes sense when there's
            // SOME drawing surface to act on — either the active
            // sketch is visible, or the user is editing a snapshot.
            // Hide it when the field is read-only-arranging.
            if hasEditableSurface {
                ToolbarPill(tool: $tool, color: $color, width: $width)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: hasEditableSurface)
        // If a snapshot the user was editing gets removed by a
        // peer (delete-snapshot, future feature), drop the
        // editing-id so the tool pill doesn't linger pointing at
        // nothing.
        .onChange(of: store.canvas.snapshots.map(\.id)) { _, ids in
            if let editing = editingSnapshotId, !ids.contains(editing) {
                editingSnapshotId = nil
            }
        }
        // Auto-reveal the sketch when a peer starts drawing
        // (empty → non-empty transition on active strokes). The
        // sketch stays open after that — even when the peer
        // stops, the user can review what landed and capture it.
        // We deliberately only fire on the 0 → N edge, so an old
        // active sketch loaded from disk does NOT auto-open.
        .onChange(of: store.canvas.activeSketch.strokes.count) { old, new in
            if old == 0, new > 0, !sketchOpenedLocally {
                sketchOpenedLocally = true
            }
        }
    }

    /// Single source of truth for "is the active sketch on screen
    /// right now". Only the local-open flag controls this — we
    /// don't auto-show based on doc state, because old strokes
    /// from a previous session shouldn't force the frame open
    /// when the user re-enters a board. Live collab is preserved
    /// by `.onChange` below: a 0 → N transition in active strokes
    /// (i.e., a peer just started drawing) flips
    /// `sketchOpenedLocally` so the user sees the collab arrive.
    private var isSketchVisible: Bool {
        sketchOpenedLocally
    }

    /// Either the sketch is open OR a snapshot is being edited
    /// — anything that needs the bottom tool pill.
    private var hasEditableSurface: Bool {
        isSketchVisible || editingSnapshotId != nil
    }

    // MARK: - Transformed content

    @ViewBuilder
    private func content(in containerSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Faint dot grid. Sized to comfortably cover any
            // reasonable pan range; the grid is part of the plane,
            // so we want it to extend well beyond the viewport.
            dotGrid(size: gridCoverage(containerSize: containerSize))
                .offset(x: gridOrigin(containerSize: containerSize).x,
                        y: gridOrigin(containerSize: containerSize).y)
                .allowsHitTesting(false)

            // Active sketch frame at field origin. Shown when:
            //  • the user opened it locally with "+", OR
            //  • the doc says the active sketch has strokes
            //    (someone else is mid-draw — keep collab live).
            if isSketchVisible {
                frame(
                    title: "Sketch",
                    titleColor: .accentColor,
                    isActive: true,
                    content: { activeSketchBody }
                )
                .offset(x: 0, y: 0)
            }

            // Captured snapshots.
            ForEach(Array(store.canvas.snapshots.enumerated()), id: \.element.id) { idx, snap in
                snapshotFrame(index: idx, snapshot: snap)
                    .offset(
                        x: snap.x + draggingOffset(for: snap.id).width,
                        y: snap.y + draggingOffset(for: snap.id).height)
            }

            // Peer cursors. Drawn inside the transformed layer so
            // they live in field coordinates and pan / zoom with
            // the plane. Cursors from peers drawing in the sketch
            // are already in sketch-local coords (= field coords
            // because the sketch frame is anchored at the field
            // origin), so they line up naturally.
            ForEach(peerCursors, id: \.peerId) { entry in
                PeerCursor(color: entry.color)
                    .offset(
                        x: entry.position.x - PeerCursor.dotSize / 2,
                        y: entry.position.y - PeerCursor.dotSize / 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// One frame's worth of chrome: title floating above, frame
    /// body below. Pulled out so the active sketch and snapshots
    /// share the exact same surface treatment.
    @ViewBuilder
    private func frame<Body: View>(
        title: String,
        titleColor: Color,
        isActive: Bool,
        @ViewBuilder content: () -> Body
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(titleColor)
                .offset(y: -Self.titleHeight)

            content()
                .frame(width: Self.sketchSize.width, height: Self.sketchSize.height)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.accentColor.opacity(0.55) : Color.black.opacity(0.06),
                            lineWidth: isActive ? 1.5 : 0.5)
                )
                .shadow(color: .black.opacity(0.10),
                        radius: isActive ? 14 : 10,
                        x: 0, y: 4)
        }
    }

    private var activeSketchBody: some View {
        ZStack {
            CanvasView(
                store: store,
                target: .activeSketch,
                documentId: documentId,
                presence: presence,
                tool: tool,
                color: color,
                width: width)
            // Peers' in-progress strokes are drawn inside the
            // active sketch frame because they're in sketch-local
            // coordinates. Each is colored with the peer's
            // identity color so multiple drawers stay
            // distinguishable.
            ForEach(peerLiveStrokes, id: \.peerId) { entry in
                Canvas { ctx, _ in
                    guard !entry.stroke.points.isEmpty else { return }
                    ctx.stroke(
                        FieldView.strokePath(for: entry.stroke.points),
                        with: .color(entry.color),
                        style: StrokeStyle(
                            lineWidth: entry.stroke.width,
                            lineCap: .round,
                            lineJoin: .round))
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// One snapshot, in either view or edit mode. View mode is
    /// the read-only tile + drag-to-reposition + tap-to-edit;
    /// edit mode swaps in a `CanvasView` targeting this snapshot
    /// and exposes a Done button in the title row.
    ///
    /// Splitting drag (move) and tap (edit) is the usual SwiftUI
    /// trick of attaching `.onTapGesture` separately from the
    /// drag — short presses fire the tap, longer movements fire
    /// the drag. We only attach the drag gesture when NOT editing
    /// so the drawing surface inside the tile owns the touch.
    @ViewBuilder
    private func snapshotFrame(index: Int, snapshot: Snapshot) -> some View {
        let isEditing = editingSnapshotId == snapshot.id
        let title = "Snapshot \(index + 1)"
        ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isEditing ? Color.accentColor : Color.secondary)
                if isEditing {
                    Button {
                        editingSnapshotId = nil
                    } label: {
                        Text("Done")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .offset(y: -Self.titleHeight)

            snapshotBody(snapshot: snapshot, isEditing: isEditing)
                .frame(width: Self.sketchSize.width, height: Self.sketchSize.height)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isEditing ? Color.accentColor.opacity(0.55) : Color.black.opacity(0.06),
                            lineWidth: isEditing ? 1.5 : 0.5))
                .shadow(color: .black.opacity(0.10),
                        radius: isEditing ? 14 : 10,
                        x: 0, y: 4)
                .onTapGesture {
                    // Tap toggles edit mode for this snapshot.
                    // Tap-to-deselect is the Done button's job.
                    if !isEditing {
                        editingSnapshotId = snapshot.id
                    }
                }
                .gesture(isEditing ? nil : dragGesture(for: snapshot))
        }
    }

    @ViewBuilder
    private func snapshotBody(snapshot: Snapshot, isEditing: Bool) -> some View {
        if isEditing {
            CanvasView(
                store: store,
                target: .snapshot(snapshot.id),
                documentId: documentId,
                presence: presence,
                tool: tool,
                color: color,
                width: width)
        } else {
            SnapshotTileView(snapshot: snapshot)
        }
    }

    /// Flattened list of all peers currently drawing on this board.
    /// Filters by `lastDocumentId` so peers active on a different
    /// board don't bleed into this one's overlay.
    private var peerLiveStrokes: [PeerStrokeEntry] {
        let boardId = documentId.id
        return presence.peers.compactMap { (peerId, state) in
            guard let stroke = state.liveStroke,
                  state.lastDocumentId == boardId
            else { return nil }
            return PeerStrokeEntry(
                peerId: peerId,
                stroke: stroke,
                color: state.color)
        }
    }

    /// Flattened list of peer cursors (in field coords).
    private var peerCursors: [PeerCursorEntry] {
        let boardId = documentId.id
        return presence.peers.compactMap { (peerId, state) in
            guard let cursor = state.cursor,
                  state.lastDocumentId == boardId
            else { return nil }
            return PeerCursorEntry(
                peerId: peerId,
                position: cursor,
                color: state.color)
        }
    }

    // MARK: - Grid

    /// Generous grid coverage so panning doesn't reveal the edge
    /// of the dot pattern in practice. Three viewport sizes in
    /// each direction is plenty for casual use; if the user pans
    /// very far we'll re-center next time the view appears.
    private func gridCoverage(containerSize: CGSize) -> CGSize {
        CGSize(
            width: max(containerSize.width * 6, Self.sketchSize.width * 8),
            height: max(containerSize.height * 6, Self.sketchSize.height * 8))
    }

    private func gridOrigin(containerSize: CGSize) -> CGPoint {
        let coverage = gridCoverage(containerSize: containerSize)
        return CGPoint(
            x: -coverage.width / 2 + Self.sketchSize.width / 2,
            y: -coverage.height / 2 + Self.sketchSize.height / 2)
    }

    private func dotGrid(size: CGSize) -> some View {
        Canvas { ctx, _ in
            let spacing = Self.gridSpacing
            // Dot color tuned to be subtly visible against the
            // backdrop without competing with frames.
            let dotColor = Color(white: 0.78)
            let radius: CGFloat = 0.9
            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    let rect = CGRect(
                        x: x - radius, y: y - radius,
                        width: radius * 2, height: radius * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
                    y += spacing
                }
                x += spacing
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Gestures

    private var currentScale: CGFloat { scale * pendingScale }

    private var currentPan: CGSize {
        CGSize(width: pan.width + pendingPan.width,
               height: pan.height + pendingPan.height)
    }

    private func draggingOffset(for id: UUID) -> CGSize {
        guard let dragging = draggingSnapshot, dragging.id == id else {
            return .zero
        }
        return CGSize(
            width: dragging.translation.width / currentScale,
            height: dragging.translation.height / currentScale)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                pendingPan = value.translation
            }
            .onEnded { value in
                pan = CGSize(
                    width: pan.width + value.translation.width,
                    height: pan.height + value.translation.height)
                pendingPan = .zero
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                pendingScale = value
            }
            .onEnded { value in
                scale = clampScale(scale * value)
                pendingScale = 1.0
            }
    }

    /// Hard-clamp zoom so the user can't pinch into oblivion or
    /// invert the canvas. Half-size up to 4× is plenty for arranging.
    private func clampScale(_ s: CGFloat) -> CGFloat {
        max(0.25, min(4.0, s))
    }

    private func dragGesture(for snapshot: Snapshot) -> some Gesture {
        DragGesture()
            .onChanged { value in
                draggingSnapshot = (snapshot.id, value.translation)
            }
            .onEnded { value in
                let dx = value.translation.width / currentScale
                let dy = value.translation.height / currentScale
                do {
                    try store.moveSnapshot(
                        id: snapshot.id,
                        to: snapshot.x + dx,
                        y: snapshot.y + dy)
                } catch {
                    assertionFailure("moveSnapshot failed: \(error)")
                }
                draggingSnapshot = nil
            }
    }

    // MARK: - Initial framing

    private func centerSketchOnce(in size: CGSize) {
        guard !didCenter else { return }
        didCenter = true
        pan = CGSize(
            width: (size.width - Self.sketchSize.width) / 2,
            height: (size.height - Self.sketchSize.height) / 2)
    }
}

// MARK: - Presence overlays

private struct PeerStrokeEntry {
    let peerId: String
    let stroke: PeerLiveStroke
    let color: Color
}

private struct PeerCursorEntry {
    let peerId: String
    let position: CGPoint
    let color: Color
}

/// The little colored dot we render at a peer's reported cursor
/// position. Kept small and shadowless so it doesn't fight with
/// the sketch content underneath.
private struct PeerCursor: View {
    let color: Color
    static let dotSize: CGFloat = 12
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Self.dotSize, height: Self.dotSize)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 1.5))
    }
}

extension FieldView {
    /// Shared midpoint-quadratic smoothing — same algorithm
    /// `CanvasView` uses for its render path. Lifted to a static
    /// so peer-stroke rendering doesn't have to duplicate it.
    fileprivate static func strokePath(for points: [Point]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        let p0 = CGPoint(x: first.x, y: first.y)
        path.move(to: p0)

        if points.count == 1 {
            path.addLine(to: CGPoint(x: p0.x + 0.01, y: p0.y))
            return path
        }
        if points.count == 2 {
            let p1 = CGPoint(x: points[1].x, y: points[1].y)
            path.addLine(to: p1)
            return path
        }

        let firstMid = midpoint(
            CGPoint(x: points[0].x, y: points[0].y),
            CGPoint(x: points[1].x, y: points[1].y))
        path.addLine(to: firstMid)
        for i in 1..<(points.count - 1) {
            let ctrl = CGPoint(x: points[i].x, y: points[i].y)
            let nextMid = midpoint(
                ctrl,
                CGPoint(x: points[i + 1].x, y: points[i + 1].y))
            path.addQuadCurve(to: nextMid, control: ctrl)
        }
        let last = points[points.count - 1]
        path.addLine(to: CGPoint(x: last.x, y: last.y))
        return path
    }

    fileprivate static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

// MARK: - Snapshot tile

/// Renders a frozen snapshot's strokes. The framing chrome (border,
/// shadow, title) is provided by `FieldView.frame`, so this view
/// just paints the strokes onto a transparent canvas.
private struct SnapshotTileView: View {
    let snapshot: Snapshot

    var body: some View {
        Canvas { ctx, _ in
            for stroke in snapshot.strokes {
                guard !stroke.points.isEmpty else { continue }
                let path = strokePath(for: stroke.points)
                ctx.stroke(
                    path,
                    with: .color(Color(rgba: stroke.color)),
                    style: StrokeStyle(
                        lineWidth: stroke.width,
                        lineCap: .round,
                        lineJoin: .round))
            }
        }
    }

    /// Same midpoint-quadratic smoothing used by `CanvasView`.
    /// Duplicated rather than shared because pulling it into a
    /// helper file would mean two render call sites importing it
    /// — when the live and frozen renderers diverge (variable
    /// width, pressure-aware shading), keeping them separate makes
    /// that easy. Revisit if a third caller appears.
    private func strokePath(for points: [Point]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        let p0 = CGPoint(x: first.x, y: first.y)
        path.move(to: p0)

        if points.count == 1 {
            path.addLine(to: CGPoint(x: p0.x + 0.01, y: p0.y))
            return path
        }
        if points.count == 2 {
            let p1 = CGPoint(x: points[1].x, y: points[1].y)
            path.addLine(to: p1)
            return path
        }

        let firstMid = midpoint(
            CGPoint(x: points[0].x, y: points[0].y),
            CGPoint(x: points[1].x, y: points[1].y))
        path.addLine(to: firstMid)
        for i in 1..<(points.count - 1) {
            let ctrl = CGPoint(x: points[i].x, y: points[i].y)
            let nextMid = midpoint(
                ctrl,
                CGPoint(x: points[i + 1].x, y: points[i + 1].y))
            path.addQuadCurve(to: nextMid, control: ctrl)
        }
        let last = points[points.count - 1]
        path.addLine(to: CGPoint(x: last.x, y: last.y))
        return path
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
