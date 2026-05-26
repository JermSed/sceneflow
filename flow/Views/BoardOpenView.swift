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

    var body: some View {
        Group {
            if let store {
                FieldView(store: store)
                    .toolbar { toolbar(for: store) }
                    .sheet(isPresented: $showShareSheet) {
                        if let summary = library.boards.first(where: { $0.id == boardId }) {
                            ShareBoardSheet(summary: summary)
                        }
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

    @ToolbarContentBuilder
    private func toolbar(for store: BoardStore) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SyncStatusIndicator(observer: library.syncStatus)
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
