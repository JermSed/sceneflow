//
//  FieldSelection.swift
//  flow
//
//  Which object on the spatial field the user has selected,
//  if any. Single-tap on snapshots / text / images sets this;
//  tap on empty field clears. Knowing the selection lets the
//  toolbar offer contextual actions (delete, eventually
//  duplicate / change color / etc) and drives the resize
//  handles on snapshots and images.
//
//  Comments aren't part of selection right now — they have
//  their own popover with a delete button. If we add multi-
//  select later we'll fold them in.
//

import Foundation

enum FieldSelection: Equatable, Hashable, Sendable {
    case snapshot(UUID)
    case text(UUID)
    case image(UUID)
}
