//
//  FieldView.swift
//  flow
//
//  Phase 1 step #4 — the unified infinite canvas.
//
//  One pannable / pinch-zoomable plane that holds:
//
//   • the active sketch (a fixed frame anchored at field origin)
//   • all captured snapshots at their (x, y) positions
//
//  Coordinate systems:
//
//   • **Field coords** — the infinite plane. Snapshot (x, y) in the
//     doc model is in this space. The active sketch frame's top-left
//     sits at field (0, 0).
//   • **Screen coords** — `field * scale + pan`. The transform lives
//     in `.scaleEffect` + `.offset` on the content ZStack.
//   • **Sketch-local coords** — inside the active sketch frame,
//     `(0, 0)` is the frame's top-left. Stroke points stored in the
//     doc are in this space, NOT field space. That means moving a
//     snapshot only changes the snapshot's (x, y); the strokes inside
//     don't need re-translation.
//
//  Gestures:
//
//   • Drawing on the active sketch: handled by the nested `CanvasView`
//     (its `DragGesture` reads local coordinates, so points land in
//     sketch-local space exactly as before).
//   • Dragging a snapshot: each tile owns a `DragGesture`. We keep
//     a per-tile live translation in `@State` so the tile follows
//     the finger immediately, then commit to the doc once on release
//     (writing on every onChanged is wasteful — `moveSnapshot` is
//     last-write-wins, so the intermediate writes are noise).
//   • Panning the field: a `DragGesture` on a clear background layer.
//     The active sketch and snapshot tiles are above it, so their
//     gestures take priority where they hit.
//   • Pinch-zoom: `MagnificationGesture` attached simultaneously to
//     the whole field. Anchored at top-leading so the pan doesn't
//     swim when scaling.
//

import SwiftUI

struct FieldView: View {

    @ObservedObject var store: BoardStore

    /// Logical size of the active sketch and of each snapshot tile.
    /// Phase 1 is "every frame is the same size as the sketch" — a
    /// future settings panel could let users vary tile dimensions.
    static let sketchSize = CGSize(width: 800, height: 600)

    // MARK: - View state

    /// Committed pan, in screen-space points. Re-anchored on each
    /// drag-end so subsequent drags add to it.
    @State private var pan: CGSize = .zero

    /// In-flight pan during an active drag — kept separate so the
    /// `onEnded` handler doesn't have to subtract anything weird.
    @State private var pendingPan: CGSize = .zero

    /// Committed zoom factor.
    @State private var scale: CGFloat = 1.0

    /// In-flight zoom multiplier during an active pinch.
    @State private var pendingScale: CGFloat = 1.0

    /// Tracks which snapshot (if any) is being dragged and how far
    /// it's been moved this gesture. Storing the in-flight translation
    /// here (rather than mutating the doc on every change) keeps pen-
    /// like-frequency writes off the CRDT hot path.
    @State private var draggingSnapshot: (id: UUID, translation: CGSize)?

    /// Whether we've done the initial "center the sketch on screen"
    /// pan. Flips true once `GeometryReader` reports the first size.
    @State private var didCenter = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background pan target. Filling the GeometryReader
                // gives the field its hit area — without an explicit
                // shape, taps on empty regions wouldn't reach the
                // pan gesture.
                Color(white: 0.96)
                    .contentShape(Rectangle())
                    .gesture(panGesture)

                // Transformed content: sketch frame + snapshot tiles.
                content
                    .scaleEffect(currentScale, anchor: .topLeading)
                    .offset(currentPan)
                    .allowsHitTesting(true)
            }
            .clipped()
            // Simultaneous so the pinch works regardless of which
            // sub-gesture is currently active.
            .simultaneousGesture(magnifyGesture)
            .onAppear { centerSketchOnce(in: geo.size) }
        }
    }

    // MARK: - Content (transformed)

    private var content: some View {
        ZStack(alignment: .topLeading) {
            activeSketchFrame
                .frame(width: Self.sketchSize.width, height: Self.sketchSize.height)
                .offset(x: 0, y: 0)   // sketch is anchored at field origin

            ForEach(store.canvas.snapshots) { snap in
                snapshotTile(for: snap)
                    .frame(width: Self.sketchSize.width, height: Self.sketchSize.height)
                    .offset(x: snap.x + draggingOffset(for: snap.id).width,
                            y: snap.y + draggingOffset(for: snap.id).height)
                    // .gesture (not .highPriorityGesture) so the
                    // CanvasView's drawing gesture inside the sketch
                    // frame still wins when the drag starts there.
                    .gesture(dragGesture(for: snap))
            }
        }
    }

    /// The active sketch — bordered so the user can see where the
    /// drawable area ends. Inside is the existing `CanvasView`, which
    /// already does input + render.
    private var activeSketchFrame: some View {
        CanvasView(store: store)
            .background(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.blue.opacity(0.4), lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func snapshotTile(for snapshot: Snapshot) -> some View {
        SnapshotTileView(snapshot: snapshot)
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
        // Translation arrives in screen-space; convert to field-space
        // so the tile tracks the finger 1:1 when zoomed.
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
    /// invert the canvas. Values picked to feel right on iPad —
    /// half-size up to 4× is enough range for arranging.
    private func clampScale(_ s: CGFloat) -> CGFloat {
        max(0.25, min(4.0, s))
    }

    private func dragGesture(for snapshot: Snapshot) -> some Gesture {
        DragGesture()
            .onChanged { value in
                draggingSnapshot = (snapshot.id, value.translation)
            }
            .onEnded { value in
                // Apply the screen-space translation back through the
                // current zoom to get the field-space delta.
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

    /// Center the sketch frame the first time we know how big our
    /// container is. Wrapping in `didCenter` so it doesn't re-run on
    /// every rotation / size change (subsequent layouts would yank
    /// the user's pan).
    private func centerSketchOnce(in size: CGSize) {
        guard !didCenter else { return }
        didCenter = true
        pan = CGSize(
            width: (size.width - Self.sketchSize.width) / 2,
            height: (size.height - Self.sketchSize.height) / 2)
    }
}

// MARK: - Snapshot tile

/// Renders a frozen snapshot's strokes inside a tile the same size as
/// the active sketch frame. Visually distinguished from the active
/// frame with a gray border (vs the active frame's blue border) so
/// the user can tell which one is currently editable.
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
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.4), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Same midpoint-quadratic smoothing used by `CanvasView`.
    /// Duplicated rather than shared because pulling it into a
    /// helper file would mean two render call sites importing it —
    /// when the live and frozen renderers diverge (variable width,
    /// pressure-aware shading), keeping them separate makes that
    /// easy. Revisit if a third caller appears.
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
