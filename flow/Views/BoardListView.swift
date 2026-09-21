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

    /// Navigation path, bound from `flowApp` so the URL handler
    /// can push a freshly-joined board onto the stack and the user
    /// lands inside the canvas instead of staring at the list and
    /// wondering what happened.
    @Binding var path: [UUID]

    /// Called with whatever the user pasted into the join sheet.
    /// `flowApp` owns the actual join flow (and its status banner),
    /// so this view just hands the text up.
    let onJoinShareText: (String) -> Void

    /// Sheet state for "rename board" — separate from the list so the
    /// row context-menu can just set this and the sheet observes it.
    @State private var renaming: BoardSummary?

    /// Sheet state for "join a shared board".
    @State private var joining = false
    @State private var isCreating = false
    @State private var actionError: String?
    @State private var searchText = ""
    @State private var pendingDeletion: [UUID] = []

    private var filteredBoards: [BoardSummary] {
        library.boards.filter { searchText.isEmpty || $0.name.localizedStandardContains(searchText) }
    }

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
            .searchable(text: $searchText, prompt: "Find a board")
            .alert("Couldn’t complete action", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK") { actionError = nil }
            } message: { Text(actionError ?? "") }
            .confirmationDialog("Delete board?", isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }), titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        let ids = pendingDeletion
                        pendingDeletion = []
                        ids.forEach(deleteBoard)
                    }
                } message: {
                    Text("This removes the local copy from this device. This action can’t be undone.")
                }
            .toolbar { toolbarContent }
            .navigationDestination(for: UUID.self) { id in
                BoardOpenView(boardId: id)
            }
            .sheet(item: $renaming) { summary in
                RenameSheet(summary: summary) { newName in
                    do { try library.rename(id: summary.id, to: newName) }
                    catch { actionError = error.localizedDescription }
                }
            }
            .sheet(isPresented: $joining) {
                JoinBoardSheet { text in
                    onJoinShareText(text)
                }
            }
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No boards yet", systemImage: "rectangle.on.rectangle")
        } description: {
            Text("A little space for your next big idea. Sketch, collect, and create together.")
        } actions: {
            Button(action: createBoard) { Label("Create a board", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
            Button("Join a shared board…") { joining = true }
                .buttonStyle(.bordered)
        }
    }

    private var boardList: some View {
        List {
            ForEach(filteredBoards) { summary in
                NavigationLink(value: summary.id) {
                    BoardRow(summary: summary)
                }
                .contextMenu {
                    Button("Rename") { renaming = summary }
                    Button("Delete", role: .destructive) {
                        pendingDeletion = [summary.id]
                    }
                }
            }
            .onDelete { indexSet in
                pendingDeletion = indexSet.map { filteredBoards[$0].id }
            }
        }
        .listStyle(.inset)
        .overlay {
            if filteredBoards.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                joining = true
            } label: {
                Label("Join Board", systemImage: "link")
            }
            Button {
                createBoard()
            } label: {
                Label(isCreating ? "Creating…" : "New Board", systemImage: "plus")
            }
            .disabled(isCreating)
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    // MARK: - Actions

    private func createBoard() {
        guard !isCreating else { return }
        isCreating = true
        let name = "Untitled \(library.boards.count + 1)"
        Task {
            defer { isCreating = false }
            do {
                let summary = try await library.createBoard(name: name)
                path.append(summary.id)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
    private func deleteBoard(_ id: UUID) {
        do { try library.deleteBoard(id: id) }
        catch { actionError = error.localizedDescription }
    }
}

// MARK: - Row

private struct BoardRow: View {
    let summary: BoardSummary

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.title2.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(summary.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(summary.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Join sheet

/// Paste a share link (or just the bare token) to join a board.
/// Validation is live via `BoardShareLink.parse` — the Join button only
/// enables when the text actually parses, so there's no error state
/// to design here. Join progress/failure is shown by `flowApp`'s
/// banner after the sheet dismisses.
private struct JoinBoardSheet: View {
    let onJoin: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var isValid: Bool { BoardShareLink.parse(text) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("sceneflow://board/…", text: $text, axis: .vertical)
                        .lineLimit(2...4)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    PasteButton(payloadType: String.self) { strings in
                        if let pasted = strings.first {
                            // PasteButton delivers off the main actor.
                            Task { @MainActor in text = pasted }
                        }
                    }
                    .buttonBorderShape(.capsule)
                } footer: {
                    Text("Paste the link from the board's share sheet — or just the token after sceneflow://board/.")
                }
            }
            .navigationTitle("Join Board")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") {
                        onJoin(text)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
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
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
