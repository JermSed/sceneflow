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
                        width: $width)

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
                ContentUnavailableView(
                    "Couldn't open board",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(boardName)
        .task {
            do {
                store = try await library.openBoard(id: boardId)
            } catch {
                loadError = "\(error)"
            }
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

        ToolbarItem(placement: .primaryAction) {
            Button {
                capture(in: store)
            } label: {
                Label("Capture", systemImage: "camera")
            }
            // Capturing an empty sketch would create a blank snapshot
            // — disable until there's something to freeze.
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
        } catch {
            assertionFailure("capture failed: \(error)")
        }
    }
}
