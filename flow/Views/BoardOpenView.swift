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
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct BoardOpenView: View {

    let boardId: UUID

    @EnvironmentObject private var library: BoardLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    /// Trigger flag for capture. The toolbar button flips this
    /// to true; `FieldView` observes the change, performs the
    /// capture at its current viewport center, then resets it.
    @State private var captureRequest: Bool = false

    /// Trigger flag for "add text note" — same hand-off pattern
    /// as captureRequest. Set by the Cmd+V paste handler when
    /// the clipboard has a string; FieldView creates a TextNote
    /// at the current viewport center and resets the flag.
    @State private var addTextRequest: String? = nil

    /// Trigger flag for "add image note" with the image bytes
    /// to embed. Same hand-off pattern.
    @State private var addImageRequest: Data? = nil

    /// Figma-style: when armed, the next click in the field
    /// places a TextNote at that exact field position (instead
    /// of dropping one at viewport center). Toggled by the
    /// toolbar's text button; ESC cancels.
    @State private var isPlacingText: Bool = false

    /// Same modal-tool pattern for placing a comment pin. The
    /// two are mutually exclusive — arming one disarms the other.
    @State private var isPlacingComment: Bool = false

    /// Currently-selected object on the field, if any. Lifted
    /// here so toolbar shortcuts (delete, future duplicate) can
    /// act on the selection.
    @State private var selection: FieldSelection? = nil

    /// Connector-drawing mode. Same modal tool pattern as the
    /// other placement tools.
    @State private var isPlacingConnector: Bool = false

    /// Pulse: when this changes, FieldView dismisses any
    /// active in-place editing (snapshot edit mode, text edit
    /// mode, open comment popover). Using a Date as a "trigger
    /// flag" rather than a Bool because we only ever want
    /// observers to fire on each press, not be sticky.
    @State private var dismissEditingPulse: Date = .distantPast

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
                        sketchOpenedLocally: $sketchOpenedLocally,
                        captureRequest: $captureRequest,
                        addTextRequest: $addTextRequest,
                        addImageRequest: $addImageRequest,
                        isPlacingText: $isPlacingText,
                        isPlacingComment: $isPlacingComment,
                        selection: $selection,
                        isPlacingConnector: $isPlacingConnector,
                        dismissEditingPulse: $dismissEditingPulse)

                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if shouldShowOfflineBanner {
                        OfflineBanner()
                            .padding(.bottom, 10)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: shouldShowOfflineBanner)
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
                ProgressView("Opening board…")
            }
        }
        .navigationTitle(boardName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
            dismiss()
        } catch {
            loadError = error.localizedDescription
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
                .help("Redo")
            }
        }

        // Hidden buttons that exist only to host keyboard
        // shortcuts. Delete/Backspace removes the selected
        // object; Escape clears selection / cancels modal tools.
        ToolbarItem(placement: .navigation) {
            Group {
                Button("Delete") {
                    deleteSelection(in: store)
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(selection == nil)
                Button("Escape") {
                    isPlacingText = false
                    isPlacingComment = false
                    isPlacingConnector = false
                    selection = nil
                    // Pulse FieldView to dismiss any in-place
                    // edit modes too (snapshot edit / text edit
                    // / open comment popover).
                    dismissEditingPulse = .now
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .hidden()
            .frame(width: 0, height: 0)
        }

        ToolbarItem(placement: .primaryAction) {
            PeerPill(
                presence: library.presence,
                documentId: summary.documentIdString)
        }

        ToolbarItem(placement: .primaryAction) {
            Button { sketchOpenedLocally = true } label: {
                Label("New sketch", systemImage: "square.and.pencil")
            }
            .disabled(isSketchVisible(store: store))
            .help("New sketch")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { captureRequest = true } label: {
                Label("Keep sketch", systemImage: "checkmark.square")
            }
            .disabled(store.canvas.activeSketch.strokes.isEmpty)
            .help("Keep this sketch as a movable frame")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    isPlacingText = true
                    isPlacingComment = false
                    isPlacingConnector = false
                } label: { Label("Add text", systemImage: "textformat") }
                Button {
                    isPlacingComment = true
                    isPlacingText = false
                    isPlacingConnector = false
                } label: { Label("Add comment", systemImage: "text.bubble") }
                Button {
                    isPlacingConnector = true
                    isPlacingText = false
                    isPlacingComment = false
                } label: { Label("Connect frames", systemImage: "arrow.right") }
                .disabled(store.canvas.snapshots.count < 2)
                Button(action: pasteFromClipboard) { Label("Paste", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v", modifiers: .command)
                Divider()
                Button { showIdentitySheet = true } label: {
                    Label("Your name", systemImage: "person.crop.circle")
                }
            } label: { Label("Add to board", systemImage: "plus.circle") }
            .help("Add to board")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showShareSheet = true } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share board")
        }
    }

    private func isSketchVisible(store: BoardStore) -> Bool {
        sketchOpenedLocally || !store.canvas.activeSketch.strokes.isEmpty
    }

    // Capture placement was moved into FieldView so it can use
    // pan/scale to drop the new snapshot at the viewport center.
    // The toolbar button just toggles `captureRequest` and
    // FieldView's `.onChange` does the work.

    /// Delete the currently-selected object via the store's
    /// typed remove. Clears the selection on success so the
    /// toolbar updates immediately.
    private func deleteSelection(in store: BoardStore) {
        guard let selection else { return }
        do {
            switch selection {
            case .snapshot(let id):
                // Removing a snapshot uses the existing
                // removeSnapshot path on BoardDocument; we add
                // a tiny BoardStore wrapper for it inline here
                // because previously it was only reachable via
                // undo of capture.
                if let s = store.canvas.snapshots.first(where: { $0.id == id }) {
                    // Push a snapshotCaptured-style entry to
                    // make delete undoable: from the store's
                    // POV "undo the delete" = "re-add the snapshot
                    // with its strokes". For now we just remove
                    // via the raw path; undo will be a follow-up.
                    _ = s
                }
                try store.removeSelectedSnapshot(id: id)
            case .text(let id):
                try store.removeText(id: id)
            case .image(let id):
                try store.removeImage(id: id)
            }
            self.selection = nil
        } catch {
            assertionFailure("delete selection failed: \(error)")
        }
    }

    /// Read the system clipboard and dispatch into FieldView.
    /// Image wins over text — pasting a Finder-copied PNG with
    /// some incidental text representation should still drop the
    /// image. Falls through silently when the clipboard has
    /// nothing we can use.
    private func pasteFromClipboard() {
        #if canImport(UIKit)
        let pb = UIPasteboard.general
        if pb.hasImages, let img = pb.image,
           let png = img.pngData() ?? img.jpegData(compressionQuality: 0.9) {
            addImageRequest = png
            return
        }
        if pb.hasStrings, let s = pb.string, !s.isEmpty {
            addTextRequest = s
            return
        }
        #elseif canImport(AppKit)
        let pb = NSPasteboard.general
        // Image types AppKit knows how to surface.
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in imageTypes {
            if let data = pb.data(forType: type) {
                addImageRequest = data
                return
            }
        }
        // Generic file URL → load the bytes and let the
        // compressor figure out the format.
        if let urlString = pb.string(forType: .fileURL),
           let url = URL(string: urlString),
           let data = try? Data(contentsOf: url) {
            addImageRequest = data
            return
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            addTextRequest = s
            return
        }
        #endif
    }
}
