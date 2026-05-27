//
//  CommentPopover.swift
//  flow
//
//  Popover surface for a single Figma-style comment pin. Shows
//  who wrote it + when, a multi-line editor for the comment
//  text, and two actions (resolve / delete). Saves on submit
//  or when the user taps Save explicitly.
//
//  Replies aren't here yet — each comment is one note for the
//  MVP. Adding `replies: [Reply]` later is straightforward; the
//  popover gains a list of bubbles plus a "reply" composer
//  below, and the doc model grows a list of Reply objects per
//  Comment.
//

import SwiftUI

struct CommentPopover: View {

    let comment: Comment
    @Binding var draft: String
    let onSave: (String) -> Void
    let onResolve: () -> Void
    let onDelete: () -> Void

    @FocusState private var focused: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            editor
            footer
        }
        .padding(14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(PresenceCoordinator.color(for: comment.authorPeerId))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(comment.authorName)
                    .font(.system(size: 13, weight: .semibold))
                Text(Self.dateFormatter.string(from: comment.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if comment.isResolved {
                Label("Resolved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    private var editor: some View {
        TextField(
            "Leave a comment",
            text: $draft,
            axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(2...6)
            .focused($focused)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(focused
                                    ? Color.accentColor.opacity(0.6)
                                    : Color.primary.opacity(0.08),
                                    lineWidth: focused ? 1.2 : 0.5)))
            .onSubmit { commit() }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)

            Button {
                onResolve()
            } label: {
                Label(
                    comment.isResolved ? "Reopen" : "Resolve",
                    systemImage: comment.isResolved
                        ? "arrow.uturn.left.circle"
                        : "checkmark.circle")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Save") { commit() }
                .buttonStyle(.borderedProminent)
                .disabled(draft == comment.text)
        }
        .font(.system(size: 12))
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}
