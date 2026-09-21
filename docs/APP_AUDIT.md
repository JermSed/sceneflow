# Repository and Swift app audit

Date: September 21, 2026

## Scope and evidence

Reviewed the SwiftUI screen and drawing architecture, board persistence and undo paths, collaboration relays, test coverage, and JavaScript package/test setup. This is a source audit with macOS build, existing tests, and a running macOS UI check; it is not a security penetration test or a device performance benchmark. The pre-existing README modification was left untouched.

## Implemented

- Board library: searchable board names, more generous row spacing, quiet icon tiles, useful empty-state actions, creation progress gating, and visible action errors. Deleting search results uses a snapshot of IDs, avoiding index shifts during multiple deletions. Empty renames cannot be submitted.
- Canvas navigation: consolidated secondary creation actions into a native menu, retained primary sketch/capture/share actions and keyboard shortcuts, and added placement instructions with a visible Cancel action.
- Canvas appearance: quieter adaptive dark/light backdrop and grid, useful first-board guidance, and initial sketch sizing that fits smaller windows. Drawing paper remains white so stored ink colors retain their meaning.
- Drawing controls: 44-point tool and palette targets, softer material panel, named ink colors, selected accessibility traits, and width announcements.
- Interaction fixes: persisted active sketches remain visible when reopening; pinch magnification is constrained throughout the gesture, avoiding the release-time snap; a new stroke clears any pending prior gesture buffer; Pencil lift location is included in the final stroke.
- Rendering: committed ink lives in a separate equatable view; imported images are decoded when their data changes rather than on every body evaluation. These reduce redundant work but have not been measured with Instruments.
- Feedback: reduced-motion preferences respected for changed canvas/offline transitions; offline status occupies reserved space rather than obscuring drawing content; failed-board deletion dismisses the destination; blank comments cannot be submitted; QR sharing has a white quiet zone.

## Remaining findings, in priority order

| Priority | Finding and evidence | Recommended follow-up |
| --- | --- | --- |
| High | `sync-server/presence.js` broadcasts all received bytes to all clients, with no authentication or per-board routing. Client-side filtering does not prevent another connected client from reading other boards' presence data. | Introduce authenticated board subscriptions, validate messages, and enforce per-client size/rate/backpressure limits before using a shared public relay. |
| High | `flow/Model/BoardLibrary.swift`, `startAutoSave`, serializes and writes on the main queue; failures are assertion-only. Large documents can interrupt interaction, and release builds do not show a save failure. | Use a serialized background persistence path with ordered snapshots, visible save errors, retry, and lifecycle flushing. Preserve the existing atomic writes. |
| Medium | `flow/Model/BoardStore.swift` undo/redo pops and transfers history entries even when the underlying apply function catches a mutation failure. | Make apply/inverse throw, retain history on failure, and expose a recoverable error. Add failure-injection tests. |
| Medium | `FieldView` combines navigation, placement, selection, editing, rendering, and gestures in one large view. `drawingGroup` alone is not a guarantee of retained rendering. | Split stable content from gesture overlays and profile dense boards with Instruments before introducing broader caching. |
| Medium | `CanvasView` erases by sampled-point distance, not distance to stroke segments. Sparse fast strokes can be difficult to erase between samples; eraser writes also occur per hit. | Use segment-distance hit testing and group an eraser gesture into a coherent undo operation. |
| Medium | UI tests are essentially launch scaffolding; no automated coverage of sketch reopen, placement cancellation, compact layouts, or drawing gestures. | Add isolated UI fixtures and regression checks on macOS and iOS, plus actual Pencil testing. |
| Medium | Initial framing fits the sketch, but does not fit all distant snapshots on an existing board. | Add Zoom to Fit/Reset View actions and saved viewport restoration. |
| Low | Several canvas/popover labels still use fixed font sizes; canvas objects have limited VoiceOver editing semantics and small resize handles. | Complete a Dynamic Type/VoiceOver pass and add accessible object actions and larger invisible handle targets. |
| Low | Root README currently describes the assistant rather than the whole repository and includes self-references. | Reconcile project setup documentation separately with the user's existing edit. |

## Validation

- macOS Debug build: passed with code signing disabled.
- Existing Swift `flowTests` target: passed.
- JavaScript assistant tests: 41 passed, 0 failed.
- Whitespace/diff checks: passed.
- Running macOS app: board creation, first-board guidance, sketch opening, adaptive dark canvas, and drawing toolbar inspected. This inspection exposed and prompted the offline-banner overlap fix.
- iOS/visionOS builds, light-mode screenshots, VoiceOver walkthrough, and device frame-time/Pencil latency measurements were not performed. No claim of measured 60/120 fps is made.

A blank `Untitled 1` board was created during the macOS UI check.

## UI/UX follow-up

The initial controls still relied too heavily on hidden gestures. This pass adds:

- An always-available navigation panel with explicit Pan mode, zoom buttons, a percentage menu, Actual Size, and Fit All Content. Pan mode makes the canvas content non-interactive so dragging over paper moves the view instead of drawing.
- Visible Edit/Delete actions for selected frames and text, and a screen-space Done Editing button. Drawing tools follow the editing context rather than appearing to act on a different selected frame.
- Local live resize previews, with document writes deferred until release. Resize hit targets remain constant in screen space as the canvas zoom changes; connectors follow resize previews.
- Selection on drag and immediately after keeping a sketch. “Capture” is now “Keep sketch,” while finished sketches are labeled “Frame.”
- Step-specific connector guidance, highlighting of the first endpoint, and disabled connection creation until two frames exist.
- Focused text entry and a board-deletion confirmation. Existing board content is framed on opening.
- Shared glass treatment for floating controls, with Reduce Transparency support. Xcode 16.2 builds use system material; a compiler/OS-gated native `glassEffect` branch is supplied for Xcode 26 / OS 26 builds. The native branch needs validation with that newer SDK.

Validation: macOS build and existing Swift unit tests passed. Running macOS UI inspected for the new control layout, selection actions, and frame/sketch state. The user also interacted with the app during inspection, so not every visible canvas mutation was an automated test. Live resize/Pencil performance is not benchmarked. Fit-to-content uses estimated text bounds because text notes do not store measured layout dimensions. Resize currently retains the existing separate move/resize undo entries for corners that change position.

Apple reference: https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views
