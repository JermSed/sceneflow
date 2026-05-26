//
//  BoardListView.swift
//  flow
//
//  Root view: the list of boards. Tap a row → enter that board.
//  Use the + button to make a new one; swipe / context-menu to delete
//  or rename.
//
//  This is the SwiftUI face of `BoardLibrary`. It does no file I/O of
//  its own — every persistence concern is in the library.
//

import SwiftUI

struct BoardListView: View {

    @EnvironmentObject private var library: BoardLibrary

    /// `selection` is the board the user has navigated into. Bound to
    /// `NavigationStack`'s path so we can programmatically push the
    /// newly-created board onto the stack.
    @State private var path: [UUID] = []

    /// Sheet state for "rename board" — separate from the list so the
    /// row context-menu can just set this and the sheet observes it.
    @State private var renaming: BoardSummary?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.boards.isEmpty {
                    emptyState
                } else {
                    boardList
                }
            }
            .navigationTitle("Boards")
            .toolbar { toolbarContent }
            .navigationDestination(for: UUID.self) { id in
                BoardOpenView(boardId: id)
            }
            .sheet(item: $renaming) { summary in
                RenameSheet(summary: summary) { newName in
                    try? library.rename(id: summary.id, to: newName)
                }
            }
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        ContentUnavailableView(
            "No boards yet",
            systemImage: "rectangle.on.rectangle",
            description: Text("Tap + to start your first board."))
    }

    private var boardList: some View {
        List {
            ForEach(library.boards) { summary in
                NavigationLink(value: summary.id) {
                    BoardRow(summary: summary)
                }
                .contextMenu {
                    Button("Rename") { renaming = summary }
                    Button("Delete", role: .destructive) {
                        try? library.deleteBoard(id: summary.id)
                    }
                }
            }
            .onDelete { indexSet in
                for i in indexSet {
                    let id = library.boards[i].id
                    try? library.deleteBoard(id: id)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                createBoard()
            } label: {
                Label("New Board", systemImage: "plus")
            }
        }
    }

    // MARK: - Actions

    private func createBoard() {
        let name = "Untitled \(library.boards.count + 1)"
        Task {
            do {
                let summary = try await library.createBoard(name: name)
                path.append(summary.id)
            } catch {
                assertionFailure("createBoard failed: \(error)")
            }
        }
    }
}

// MARK: - Row

private struct BoardRow: View {
    let summary: BoardSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.name)
                .font(.headline)
            Text(summary.updatedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Rename sheet

private struct RenameSheet: View {
    let summary: BoardSummary
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(summary: BoardSummary, onCommit: @escaping (String) -> Void) {
        self.summary = summary
        self.onCommit = onCommit
        _draft = State(initialValue: summary.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $draft)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
            }
            .navigationTitle("Rename")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onCommit(trimmed) }
                        dismiss()
                    }
                }
            }
        }
    }
}
