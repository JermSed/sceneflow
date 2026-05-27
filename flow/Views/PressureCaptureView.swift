//
//  PressureCaptureView.swift
//  flow
//
//  iOS-only UIKit drag-capture surface that exposes real Apple
//  Pencil pressure (and finger touches with a sane fallback).
//
//  SwiftUI's `DragGesture` doesn't surface `UITouch.force`, and it
//  doesn't expose `event.coalescedTouches(for:)` either — which
//  matters because a Pencil event can carry many sub-samples that
//  arrive bundled in a single touchesMoved callback. Drop those
//  on the floor and the rendered stroke looks like a polyline of
//  big segments instead of the smooth curve the Pencil produced.
//
//  This wrapper:
//   • Hosts a tiny `PressureCaptureUIView` inside SwiftUI.
//   • Overrides `touchesBegan/Moved/Ended/Cancelled`.
//   • Reads coalesced sub-touches so every sub-sample becomes a
//     `Sample` callback (x, y in the view's local coord space,
//     plus a normalized pressure 0…1).
//   • Reports `phase: .began | .changed | .ended` so the SwiftUI
//     caller can mirror its existing pen+eraser dispatch.
//
//  Fingers don't carry a real force on most devices. We fall back
//  to 0.5 in that case so the data shape stays consistent — a
//  later pressure-aware renderer will simply not vary on finger
//  strokes, which matches what every other sketching app does.
//
//  Not used on macOS or visionOS (no `UITouch`); on those
//  platforms CanvasView keeps using the SwiftUI `DragGesture`.
//

#if canImport(UIKit)

import SwiftUI
import UIKit

struct PressureCaptureView: UIViewRepresentable {

    enum Phase { case began, changed, ended }

    struct Sample: Sendable {
        var location: CGPoint
        var pressure: Double   // 0…1, normalized
        var phase: Phase
    }

    /// Called for every touch sample. Make sure the closure is
    /// cheap — Pencil at 240Hz can fire it that often.
    let onSample: (Sample) -> Void

    func makeUIView(context: Context) -> PressureCaptureUIView {
        let view = PressureCaptureUIView()
        view.onSample = onSample
        return view
    }

    func updateUIView(_ uiView: PressureCaptureUIView, context: Context) {
        // The handler captures `tool` / `color` / `width` via
        // closure, which change between renders. Re-bind every
        // time so the latest values are used.
        uiView.onSample = onSample
    }
}

final class PressureCaptureUIView: UIView {

    var onSample: ((PressureCaptureView.Sample) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // One-finger-at-a-time matches our stroke model. Letting
        // two touches start parallel strokes is a future feature,
        // not a Phase-3 default.
        isMultipleTouchEnabled = false
        isUserInteractionEnabled = true
        // Make sure empty regions accept hits — UIView defaults
        // to clearColor.alpha = 0 being non-hit-testable in some
        // contexts. Using a transparent backgroundColor keeps the
        // view visually invisible while still receiving touches.
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        emit(touch: touch, phase: .began)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        // Coalesced touches are the bundled sub-samples that
        // accumulated between the last main touch event and this
        // one. Replaying them gives us the real input frequency
        // (often 120–240Hz with Pencil) rather than the much
        // sparser run-loop tick rate.
        if let coalesced = event?.coalescedTouches(for: touch), !coalesced.isEmpty {
            for t in coalesced {
                emit(touch: t, phase: .changed)
            }
        } else {
            emit(touch: touch, phase: .changed)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        emit(touch: touch, phase: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Treat cancel like an end — the SwiftUI caller wants the
        // stroke committed (or discarded) either way.
        guard let touch = touches.first else { return }
        emit(touch: touch, phase: .ended)
    }

    private func emit(touch: UITouch, phase: PressureCaptureView.Phase) {
        let p = touch.preciseLocation(in: self)
        let pressure: Double
        if touch.type == .pencil, touch.maximumPossibleForce > 0 {
            pressure = max(0, min(1, Double(touch.force / touch.maximumPossibleForce)))
        } else if touch.maximumPossibleForce > 0, touch.force > 0 {
            // 3D-Touch capable hardware reports finger force too;
            // use it when available.
            pressure = max(0, min(1, Double(touch.force / touch.maximumPossibleForce)))
        } else {
            // No pressure source — use a fixed midpoint so the
            // doc's `Point.pressure` field stays meaningful.
            pressure = 0.5
        }
        onSample?(PressureCaptureView.Sample(
            location: p,
            pressure: pressure,
            phase: phase))
    }
}

#endif
