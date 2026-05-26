//
//  CanvasView.swift
//  flow
//
//  The live drawing surface — Phase 1 step #3.
//
//  This is the only place in the app where pen / touch input flows
//  into the document. The view does three things:
//
//   1. Render every stroke in `store.canvas.activeSketch.strokes`
//      using SwiftUI's `Canvas`.
//   2. Translate the user's drag into a sequence of
//      `BoardStore.beginStroke` + `appendPoint` calls.
//   3. Reset its in-progress stroke handle when the drag ends, so the
//      next drag opens a new stroke.
//
//  Things this view explicitly does NOT do (yet):
//
//   • Snapshot rendering / the spatial field — that's Phase 1 step #4.
//   • Pan and zoom — also step #4.
//   • Pencil pressure / tilt — `DragGesture` doesn't expose force.
//     We capture `pressure = 0.5` for every sample so the data shape
//     stays right; switching to UIKit's `UIPanGestureRecognizer` (via
//     `UIViewRepresentable`) to get coalesced touches with `.force`
//     is a self-contained follow-up that won't change the doc model.
//   • Stroke smoothing — straight line segments between samples are
//     jagged at slow pen speeds. A quadratic Bezier through midpoints
//     is the standard fix; defer until we have real input rates.
//   • Color / width pickers — hardcoded black @ 2.5pt for Phase 1.
//
//  Performance note:
//
//   `store.canvas` republishes on every appended point, so this view's
//   body recomputes 60–120× / sec while drawing. The `Canvas` itself
//   redraws fully each time (it doesn't diff paths). That's fine for
//   small docs; if it becomes a bottleneck we'll either subscribe to
//   Automerge patches and maintain a CGPath cache, or split the live
//   stroke into its own view so only it invalidates per-sample.
//

import SwiftUI

struct CanvasView: View {

    @ObservedObject var store: BoardStore

    /// Handle for the stroke currently being drawn. `nil` between drags.
    @State private var currentStroke: StrokeHandle?

    /// Hardcoded for Phase 1 — pickers come later.
    private let defaultColor: UInt32 = 0x111111FF  // near-black
    private let defaultWidth: Double = 2.5

    var body: some View {
        Canvas { ctx, _ in
            for stroke in store.canvas.activeSketch.strokes {
                guard !stroke.points.isEmpty else { continue }
                let path = Self.path(for: stroke.points)
                ctx.stroke(
                    path,
                    with: .color(Color(rgba: stroke.color)),
                    style: StrokeStyle(
                        lineWidth: stroke.width,
                        lineCap: .round,
                        lineJoin: .round))
            }
        }
        // A near-white background so the canvas reads as "paper" rather
        // than blending into the surrounding chrome. Also makes the
        // hit area for the drag gesture obvious to the OS.
        .background(Color(white: 0.99))
        .gesture(dragGesture)
        // If the user navigates away mid-stroke, drop the handle so
        // returning starts cleanly. (This is also why `currentStroke`
        // lives in `@State` rather than `@GestureState` — we want it
        // to survive a quick re-render but get torn down on disappear.)
        .onDisappear { currentStroke = nil }
    }

    // MARK: - Gesture

    /// `minimumDistance: 0` so a single tap starts (and ends) a stroke
    /// — without that, dotting an i requires a tiny drag.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChange(at: value.location)
            }
            .onEnded { _ in
                currentStroke = nil
            }
    }

    private func handleDragChange(at location: CGPoint) {
        do {
            // First sample of a new stroke → allocate a stroke in the
            // doc and cache its handle. Subsequent samples reuse it
            // (cheap; no tree walk).
            if currentStroke == nil {
                currentStroke = try store.beginStroke(
                    color: defaultColor, width: defaultWidth)
            }
            guard let handle = currentStroke else { return }
            try store.appendPoint(
                to: handle,
                Point(x: Double(location.x),
                      y: Double(location.y),
                      pressure: 0.5))
        } catch {
            assertionFailure("CanvasView drag failed: \(error)")
            currentStroke = nil
        }
    }

    // MARK: - Path building

    /// Build a smoothed `Path` from a stroke's points.
    ///
    /// Algorithm: quadratic Bezier through midpoints, with the
    /// sampled points as control points. The rendered curve passes
    /// through the midpoint of each consecutive pair of samples
    /// rather than through the samples themselves, and the samples
    /// "round off" the corner. Continuity is C1 (tangents match at
    /// each midpoint) which is what reads as "smooth" to the eye.
    ///
    ///                p1 (control)
    ///                  *
    ///                 / \
    ///                /   \
    ///   p0 ───→ m01 \   / m12 ───→ p2
    ///                \─/
    ///                 X (curve passes here, not through p1)
    ///
    /// Cheap (one quad curve per sample), no extra deps, works fine
    /// at typical pen sample rates. If a stroke is only 1 or 2
    /// points we degenerate to a dot or a line — `Canvas.stroke`
    /// won't render a single-point path so the 1-point case adds a
    /// hair-line so a tap leaves a visible mark.
    private static func path(for points: [Point]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        let p0 = CGPoint(x: first.x, y: first.y)
        path.move(to: p0)

        if points.count == 1 {
            // Single tap → tiny segment so `stroke` actually paints.
            path.addLine(to: CGPoint(x: p0.x + 0.01, y: p0.y))
            return path
        }
        if points.count == 2 {
            let p1 = CGPoint(x: points[1].x, y: points[1].y)
            path.addLine(to: p1)
            return path
        }

        // 3+ points: line from p[0] to the first midpoint, then
        // quad curves through subsequent midpoints with samples as
        // controls, then a final line into the last actual sample
        // so the stroke ends exactly where the pen lifted.
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
}

// MARK: - Color packing

extension Color {
    /// Unpack a 0xRRGGBBAA color (the form we store in Automerge) into
    /// a SwiftUI `Color`. Kept in this file because it's only used by
    /// the render path; if a second caller appears, hoist it.
    init(rgba: UInt32) {
        let r = Double((rgba >> 24) & 0xFF) / 255.0
        let g = Double((rgba >> 16) & 0xFF) / 255.0
        let b = Double((rgba >> 8) & 0xFF) / 255.0
        let a = Double(rgba & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
