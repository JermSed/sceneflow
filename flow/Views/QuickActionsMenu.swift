//
//  QuickActionsMenu.swift
//  flow
//
//  Floating "right-click style" menu for the spatial field.
//  Opens at the double-tap location with the most common
//  in-place actions: drop a comment pin, drop text, paste from
//  clipboard. Tapping an option performs the action at the
//  click location (not at viewport center) and dismisses the
//  menu.
//
//  Visually a small rounded card with icon+label buttons, like
//  Figma's contextual menu. We don't try to replace the toolbar
//  — the toolbar stays as the canonical entry point; this is a
//  shortcut for "I want to drop something *here*, right now."
//

import SwiftUI

struct QuickActionsMenu: View {
    let onAddComment: () -> Void
    let onAddText: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(icon: "text.bubble", label: "Comment here") {
                onAddComment()
            }
            divider
            row(icon: "textformat", label: "Text here") {
                onAddText()
            }
        }
        .frame(width: 180)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.thinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        // The whole card is interactive; dismissal happens via
        // the parent's tap-outside catcher.
    }

    private func row(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }
}
