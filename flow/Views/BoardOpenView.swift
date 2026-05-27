//
//  BoardOpenView.swift
//  flow
//
//  Hosts an open board: loads the `BoardStore` via the library, then
//  hands it to `CanvasView` and adds the board-level toolbar (Capture,
//  and the snapshot count read-out so the user can tell something
//  happened when they captured).
//

import SwiftUI

struct BoardOpenView: View {

    let boardId: UUID

    @EnvironmentObject private var library: BoardLibrary
    @State private var store: BoardStore?
    @State private var loadError: String?
    @State private var showShareSheet = false
    @State private var showIdentitySheet = false
    @State private var tool: DrawingTool = .pen
    @State private var color: UInt32 = DrawingPalette.colors.first ?? 0x111111FF
    @State private var width: Double = DrawingPalette.widths[1]   // default = "normal"

    /// Whether the user has explicitly asked to see the active
    /// sketch frame (tapped "+"). Independent of the doc state
    /// — the frame also auto-shows when the sketch contains
    /// strokes (e.g. a peer is mid-draw) regardless of this flag.
    @State private var sketchOpenedLocally: Bool = false

    var body: some View {
        Group {
            if let store, let summary = library.boards.first(where: { $0.id == boardId }) {
                ZStack(alignment: .top) {
                    FieldView(
                        store: store,
                        documentId: summary.documentId,
                        presence: library.presence,
                        tool: $tool,
                        color: $color,
                        width: $width,
                        sketchOpenedLocally: $sketchOpenedLocally)

                    // Slim banner that drops down from the top of
                    // the board when the sync socket isn't ready.
                    // Local edits keep working (Automerge is
                    // offline-first) — the banner just tells the
                    // user that "what they draw will sync once the
                    // relay is reachable again."
                    if shouldShowOfflineBanner {
                        OfflineBanner()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: shouldShowOfflineBanner)
                .toolbar { toolbar(for: store, summary: summary) }
                .sheet(isPresented: $showShareSheet) {
                    ShareBoardSheet(summary: summary)
                }
                .sheet(isPresented: $showIdentitySheet) {
                    IdentitySheet(color: library.presence.localColor)
                }
            } else if let loadError {
                loadErrorView(loadError)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(boardName)
        .task { await loadStore() }
    }

    private func loadStore() async {
        loadError = nil
        do {
            store = try await library.openBoard(id: boardId)
        } catch {
            loadError = "\(error)"
        }
    }

    /// Error state for when `openBoard` throws. The most common
    /// cause we've seen in the wild is a corrupted local file
    /// (e.g. an interrupted write during sync). Offer two ways
    /// out: retry (handles transient failures) and delete-and-
    /// recover (handles persistent corruption — for shared
    /// boards the user can re-join via the share URL after).
    @ViewBuilder
    private func loadErrorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't open board", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The local copy may be corrupted. Try again, or delete this board and re-join it from the share link if it's collaborative.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        } actions: {
            HStack(spacing: 12) {
                Button {
                    Task { await loadStore() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    deleteThisBoard()
                } label: {
                    Label("Delete board", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func deleteThisBoard() {
        do {
            try library.deleteBoard(id: boardId)
            // Pop back to the list. The NavigationStack path lives
            // on flowApp; clearing the destination by setting our
            // own boardName change is awkward, so we lean on the
            // OS's standard back-on-disappear behavior here — the
            // user is already mid-error so the auto-pop is what
            // they expect.
        } catch {
            assertionFailure("deleteBoard failed: \(error)")
        }
    }

    private var boardName: String {
        library.boards.first(where: { $0.id == boardId })?.name ?? "Board"
    }

    /// Show the offline banner only when we're genuinely unable
    /// to talk to the relay (disconnected). `connecting` /
    /// `reconnecting` are transient by design — flashing the
    /// banner for those is more noise than signal.
    private var shouldShowOfflineBanner: Bool {
        library.syncStatus.state == .disconnected
    }

    @ToolbarContentBuilder
    private func toolbar(for store: BoardStore, summary: BoardSummary) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SyncStatusIndicator(observer: library.syncStatus)
        }

        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Button {
                    store.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo)
                .accessibilityLabel("Undo")

                Button {
                    store.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
                .accessibilityLabel("Redo")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            PeerPill(
                presence: library.presence,
                documentId: summary.documentIdString)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showIdentitySheet = true
            } label: {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(library.presence.localColor)
            }
            .accessibilityLabel("Your name")
        }

        // Two contextual buttons. The sketch is hidden by default;
        // "+" reveals it; once visible, Capture freezes it back
        // into a snapshot and hides it again. We keep both visible
        // so the user can see where each lives, and gate them on
        // sketch state for affordance.
        ToolbarItem(placement: .primaryAction) {
            Button {
                sketchOpenedLocally = true
            } label: {
                // A plain "+" reads as "new thing" everywhere on
                // iOS. The earlier square.and.pencil icon was
                // too subtle and got mistaken for a generic edit
                // glyph.
                Label("New sketch", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18, weight: .semibold))
            }
            .disabled(isSketchVisible(store: store))
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                capture(in: store)
            } label: {
                Label("Capture", systemImage: "camera")
            }
            // Capturing an empty sketch would create a blank
            // snapshot. Only enable when there's something to freeze.
            .disabled(store.canvas.activeSketch.strokes.isEmpty)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showShareSheet = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func isSketchVisible(store: BoardStore) -> Bool {
        sketchOpenedLocally || !store.canvas.activeSketch.strokes.isEmpty
    }

    private func capture(in store: BoardStore) {
        do {
            // Drop new snapshots in a horizontal row to the right of
            // anything already placed, so consecutive captures don't
            // stack on top of each other. The user is free to drag
            // them anywhere afterward.
            let gap: Double = 60
            let tileW = Double(FieldView.sketchSize.width)
            let snapshots = store.canvas.snapshots
            let baselineX = tileW + gap   // first snapshot sits just right of the sketch
            let nextX = snapshots
                .map { $0.x + tileW + gap }
                .max() ?? baselineX
            let z = snapshots.count
            _ = try store.captureSnapshot(at: nextX, y: 0, z: z)
            // Capture clears the active sketch; close the local
            // reveal too so the field returns to "snapshots only".
            sketchOpenedLocally = false
        } catch {
            assertionFailure("capture failed: \(error)")
        }
    }
}
