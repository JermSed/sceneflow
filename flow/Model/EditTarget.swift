//
//  EditTarget.swift
//  flow
//
//  Which frame the user is currently drawing into. The same
//  `CanvasView` renders + accepts pen input for either kind:
//
//   • `.activeSketch` — the always-at-origin scratchpad. Capture
//     freezes it into a snapshot and clears it.
//   • `.snapshot(UUID)` — an existing captured snapshot in the
//     spatial field. Edits land on that snapshot's strokes list
//     and sync to peers like any other CRDT mutation.
//
//  Kept in its own file because both the view layer and the
//  store reference it, and it has no dependencies of its own —
//  pure data.
//

import Foundation

enum EditTarget: Equatable, Hashable, Sendable {
    case activeSketch
    case snapshot(UUID)
}
