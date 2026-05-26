//
//  CanvasView.swift
//  flow
//
//  The live drawing surface.
//
//  Pen samples are buffered locally in `@State` while the user is
//  drawing, and the finished stroke is committed to the document in
//  ONE Automerge change on release. This matters for two reasons
//  CLAUDE.md is explicit about:
//
//    1. The CRDT change log stays compact — one change per stroke,
//       not 60+ per stroke.
//    2. SwiftUI re-decodes the whole `CanvasDoc` on every
//       `objectDidChange` from the underlying `Automerge.Document`.
//       Doing that 60–120× per second per stroke is what made
//       drawing feel laggy. Buffering moves the hot path entirely
//       into local `@State`, which is essentially free.
//
//  Under sync, this also means peers see strokes appear when the
//  pen lifts rather than streaming them sample-by-sample. That's
//  acceptable for the MVP collaboration story — live cursor /
//  in-progress-stroke previews belong on the *presence* channel
//  (Phase 3), not the CRDT doc itself.
//
//  Things this view explicitly does NOT do (yet):
//
//   • Pencil pressure / tilt — `DragGesture` doesn't expose force.
//     Pressure is stored as 0.5; switching to UIKit's
//     `UIPanGestureRecognizer` for coalesced touches with `.force`
//     is a self-contained follow-up that won't change the doc model.
//   • Color / width pickers — hardcoded near-black @ 2.5pt.
//

import SwiftUI

struct CanvasView: View {

    @ObservedObject var store: BoardStore

    /// In-flight stroke points, in sketch-local coordinates.
    /// Lives in `@State` so SwiftUI invalidates the body when it
    /// grows — but the doc isn't touched until release.
    @State private var inProgressPoints: [Point] = []

    /// The id we minted for the stroke we just committed. We hold
    /// onto it (and onto `inProgressPoints`) until that stroke
    /// shows up in `store.canvas` — otherwise there's a one-runloop
    /// gap between "we cleared the local buffer" and "the doc-derived
    /// canvas reflects the new stroke" where the stroke isn't drawn
    /// from either source and the user sees it flash out and back in.
    @State private var pendingStrokeId: UUID?

    /// Hardcoded for Phase 1 — pickers come later.
    private let defaultColor: UInt32 = 0x111111FF  // near-black
    private let defaultWidth: Double = 2.5

    var body: some View {
        Canvas { ctx, _ in
            // 1. Already-committed strokes from the doc.
            for stroke in store.canvas.activeSketch.strokes {
                guard !stroke.points.isEmpty else { continue }
                ctx.stroke(
                    Self.path(for: stroke.points),
                    with: .color(Color(rgba: stroke.color)),
                    style: Self.strokeStyle(width: stroke.width))
            }
            // 2. The stroke the user is drawing right now (or just
            //    finished drawing, if the commit hasn't propagated
            //    through the @Published canvas yet). Rendered from
            //    the local buffer with the same style as committed
            //    strokes so the handoff is invisible.
            //
            //    `showLiveOverlay` ensures we don't double-draw
            //    once the doc-derived canvas already includes the
            //    same stroke.
            if showLiveOverlay, !inProgressPoints.isEmpty {
                ctx.stroke(
                    Self.path(for: inProgressPoints),
                    with: .color(Color(rgba: defaultColor)),
                    style: Self.strokeStyle(width: defaultWidth))
            }
        }
        // The frame chrome (white paper background, border, shadow)
        // lives in FieldView so we render onto a transparent canvas
        // here. Still need an explicit hit-test shape so the drag
        // gesture catches taps in empty regions of the sketch.
        .contentShape(Rectangle())
        .gesture(dragGesture)
        // When the just-committed stroke lands in the doc-derived
        // canvas, drop the local buffer. We key this on stroke
        // count rather than identity equality so it's cheap.
        .onChange(of: store.canvas.activeSketch.strokes.count) {
            if let id = pendingStrokeId,
               store.canvas.activeSketch.strokes.contains(where: { $0.id == id }) {
                inProgressPoints = []
                pendingStrokeId = nil
            }
        }
        // Pen down outside the view bounds, lift outside → drag
        // cancellation doesn't fire onEnded reliably; clear local
        // state on disappear so a half-finished buffer doesn't
        // carry into the next session.
        .onDisappear {
            inProgressPoints = []
            pendingStrokeId = nil
        }
    }

    /// Whether the local in-progress buffer should be drawn on top
    /// of the doc-derived canvas. During the drag itself
    /// `pendingStrokeId` is nil and we always draw. After commit
    /// we keep drawing until the doc reflects the new stroke; once
    /// it does, we suppress the overlay so we don't render the
    /// same stroke twice in the same frame.
    private var showLiveOverlay: Bool {
        guard let id = pendingStrokeId else { return true }
        return !store.canvas.activeSketch.strokes.contains(where: { $0.id == id })
    }

    // MARK: - Gesture

    /// `minimumDistance: 0` so a single tap leaves a visible dot
    /// — otherwise dotting an i requires a tiny drag.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                inProgressPoints.append(Point(
                    x: Double(value.location.x),
                    y: Double(value.location.y),
                    pressure: 0.5))
            }
            .onEnded { _ in
                commitInProgressStroke()
            }
    }

    private func commitInProgressStroke() {
        guard !inProgressPoints.isEmpty else { return }
        let id = UUID()
        let stroke = Stroke(
            id: id,
            color: defaultColor,
            width: defaultWidth,
            points: inProgressPoints)
        do {
            try store.commitStroke(stroke)
            // Hold onto inProgressPoints; .onChange below will clear
            // them once the doc-derived canvas catches up. That's
            // what makes the handoff visually seamless.
            pendingStrokeId = id
        } catch {
            // A commit failure here means the Automerge doc itself
            // refused the write — almost certainly a programming
            // error, not a runtime condition we can recover from.
            // Drop the buffer so the next stroke starts clean.
            assertionFailure("commitStroke failed: \(error)")
            inProgressPoints = []
        }
    }

    // MARK: - Path building

    /// Build a smoothed `Path` from a sequence of points.
    ///
    /// Algorithm: quadratic Bezier through midpoints, with the
    /// sampled points as control points. The rendered curve passes
    /// through the midpoint of each consecutive pair of samples
    /// rather than through the samples themselves, and the samples
    /// "round off" the corner. C1-continuous, which is what reads
    /// as "smooth" to the eye.
    ///
    /// Cheap, no extra deps. Degenerate cases (1 / 2 points) draw
    /// a dot / line so a tap or short flick still leaves a mark.
    private static func path(for points: [Point]) -> Path {
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

        let firstMid = Self.midpoint(
            CGPoint(x: points[0].x, y: points[0].y),
            CGPoint(x: points[1].x, y: points[1].y))
        path.addLine(to: firstMid)

        for i in 1..<(points.count - 1) {
            let ctrl = CGPoint(x: points[i].x, y: points[i].y)
            let nextMid = Self.midpoint(
                ctrl,
                CGPoint(x: points[i + 1].x, y: points[i + 1].y))
            path.addQuadCurve(to: nextMid, control: ctrl)
        }

        let last = points[points.count - 1]
        path.addLine(to: CGPoint(x: last.x, y: last.y))
        return path
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private static func strokeStyle(width: Double) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

// MARK: - Color packing

extension Color {
    /// Unpack a 0xRRGGBBAA color (the form we store in Automerge)
    /// into a SwiftUI `Color`.
    init(rgba: UInt32) {
        let r = Double((rgba >> 24) & 0xFF) / 255.0
        let g = Double((rgba >> 16) & 0xFF) / 255.0
        let b = Double((rgba >> 8) & 0xFF) / 255.0
        let a = Double(rgba & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
