//
//  FieldView.swift
//  flow
//
//  The unified infinite canvas — Phase 1 step #4.
//
//  One pannable / pinch-zoomable plane that holds the active sketch
//  frame at field origin and every captured snapshot at its (x, y).
//
//  Visual language is borrowed from Figma:
//
//   • A neutral medium-light gray "infinite paper" backdrop, not
//     white — so the white frames read as paper sitting on a desk.
//   • A faint dot grid in the field's coordinate space gives the
//     plane a sense of scale and motion when panning / zooming.
//   • Frames have no border in their resting state. They sit on
//     the backdrop on a small drop shadow, the way Figma frames do.
//   • The active sketch frame gets a subtle accent-colored outline
//     so the user can tell at a glance which one is editable.
//   • Each frame has a small label floating above it: "Sketch" for
//     the live area, "Snapshot 1", "Snapshot 2", … for the captures.
//
//  Coordinate systems (unchanged from earlier — see ../Model for
//  details): field coords, screen coords, sketch-local coords.
//

import SwiftUI
import AutomergeRepo
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct FieldView: View {

    @ObservedObject var store: BoardStore

    /// Sync identity for the board this view is showing. Passed
    /// down to `CanvasView` so its presence broadcasts get routed
    /// per-board, and used to filter received presence so we only
    /// render cursors / overlays for peers on *this* board.
    let documentId: DocumentId

    /// Presence channel for the app. Optional so this view can be
    /// previewed in isolation; production wires it from
    /// `BoardLibrary.presence`.
    @ObservedObject var presence: PresenceCoordinator

    /// Currently selected drawing tool. Bound from
    /// `BoardOpenView` so the floating toolbar pill and the
    /// drawing surface share the same selection.
    @Binding var tool: DrawingTool

    /// Active pen color (and the color used to render in-progress
    /// previews of the user's own strokes).
    @Binding var color: UInt32

    /// Active stroke width.
    @Binding var width: Double

    /// Whether the user has locally asked to see the sketch frame.
    /// True OR a non-empty active sketch (e.g. a peer is drawing)
    /// reveals the frame; otherwise the field shows snapshots only.
    @Binding var sketchOpenedLocally: Bool

    /// Snapshot currently being edited, if any. Set by tapping
    /// a snapshot tile; cleared by tapping a "Done" affordance
    /// on the edited tile. When set, the tool pill shows and
    /// drawing/erasing route to that snapshot's strokes list.
    @State private var editingSnapshotId: UUID?

    /// "Trigger" binding from `BoardOpenView`'s toolbar Capture
    /// button. The parent flips this from false → true to ask
    /// for a capture; FieldView observes the change, performs
    /// the capture at the current viewport center, and flips it
    /// back. Using a binding (rather than a closure prop) keeps
    /// the toolbar logic in `BoardOpenView` — where the rest of
    /// the chrome lives — while keeping the placement math here
    /// where the pan/scale state already is.
    @Binding var captureRequest: Bool

    /// Same hand-off pattern for "add a text note": the parent
    /// writes the initial string (or empty for new note); we
    /// place it at viewport center and reset to nil.
    @Binding var addTextRequest: String?

    /// Same for "paste an image": parent writes the raw bytes,
    /// we decode/compress and place at viewport center.
    @Binding var addImageRequest: Data?

    /// Logical size of the active sketch and of each snapshot tile.
    static let sketchSize = CGSize(width: 800, height: 600)

    /// Spacing between the major dot-grid points. Picked so the
    /// dots are visible but not noisy at scale = 1.
    private static let gridSpacing: CGFloat = 24

    /// Pixel offset of each frame's title above its top edge.
    private static let titleHeight: CGFloat = 22

    // MARK: - View state

    @State private var pan: CGSize = .zero
    @State private var pendingPan: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var pendingScale: CGFloat = 1.0
    @State private var draggingSnapshot: (id: UUID, translation: CGSize)?
    @State private var didCenter = false

    /// Last container size we observed via GeometryReader. Captured
    /// so capture-placement can compute the viewport center in
    /// field coords without going through the GeometryReader proxy
    /// from a button handler.
    @State private var containerSize: CGSize = .zero

    /// Where (in field coords) the active sketch frame's top-left
    /// is rendered. View state, not doc state — each peer chooses
    /// where to anchor their own sketch view. Strokes are still
    /// stored in sketch-local coords, so peers see the same content
    /// even when their sketch frames are at different field
    /// positions.
    ///
    /// Initial value `(.nan, .nan)` is the sentinel "no position
    /// chosen yet" — when the user taps "+" we replace it with
    /// the current viewport center. We avoid `nil`/Optional here
    /// to keep the `.offset(x:y:)` math straightforward.
    @State private var sketchPosition: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 1. Backdrop. Pan-gesture target so taps on empty
                //    field pan the whole plane.
                Color(red: 0.91, green: 0.91, blue: 0.93)
                    .contentShape(Rectangle())
                    .gesture(panGesture)

                // 2. Everything that lives "on" the plane:
                //    grid + sketch + snapshots, all transformed
                //    together so they pan and zoom as one piece.
                //
                content(in: geo.size)
                    .scaleEffect(currentScale, anchor: .topLeading)
                    .offset(currentPan)
                    .allowsHitTesting(true)
            }
            .clipped()
            .simultaneousGesture(magnifyGesture)
            .onAppear {
                containerSize = geo.size
                centerSketchOnce(in: geo.size)
            }
            .onChange(of: geo.size) { _, new in containerSize = new }
        }
        // safeAreaInset puts the pill above the home indicator
        // (and any future bottom system chrome) by inserting it
        // *into* the safe area rather than overlaying at the raw
        // bottom edge — that's where the previous .overlay version
        // disappeared on iPad.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The drawing tool pill only makes sense when there's
            // SOME drawing surface to act on — either the active
            // sketch is visible, or the user is editing a snapshot.
            // Hide it when the field is read-only-arranging.
            if hasEditableSurface {
                ToolbarPill(tool: $tool, color: $color, width: $width)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: hasEditableSurface)
        // If a snapshot the user was editing gets removed by a
        // peer (delete-snapshot, future feature), drop the
        // editing-id so the tool pill doesn't linger pointing at
        // nothing.
        .onChange(of: store.canvas.snapshots.map(\.id)) { _, ids in
            if let editing = editingSnapshotId, !ids.contains(editing) {
                editingSnapshotId = nil
            }
        }
        // Auto-reveal the sketch when a peer starts drawing
        // (empty → non-empty transition on active strokes). The
        // sketch stays open after that — even when the peer
        // stops, the user can review what landed and capture it.
        // We deliberately only fire on the 0 → N edge, so an old
        // active sketch loaded from disk does NOT auto-open.
        .onChange(of: store.canvas.activeSketch.strokes.count) { old, new in
            if old == 0, new > 0, !sketchOpenedLocally {
                // Place the sketch at our viewport center too so
                // we actually see what the peer is drawing.
                sketchPosition = topLeftCenteredOnViewport()
                sketchOpenedLocally = true
            }
        }
        // When the user taps "+" we want the sketch to appear
        // wherever they're currently looking, not stuck at the
        // field origin. Watch the flag and snap the sketch into
        // place the moment it flips on.
        .onChange(of: sketchOpenedLocally) { old, new in
            if !old, new {
                sketchPosition = topLeftCenteredOnViewport()
            }
        }
        // Toolbar Capture button hand-off. The parent sets
        // `captureRequest = true`; we honor it here where we
        // have pan/scale/containerSize to place the snapshot at
        // the viewport center, then reset the flag so the next
        // tap fires again.
        .onChange(of: captureRequest) { _, requested in
            if requested {
                performCaptureAtViewportCenter()
                captureRequest = false
            }
        }
        // Same pattern for add-text / paste-image — the parent
        // sets the binding, we react here.
        .onChange(of: addTextRequest) { _, requested in
            guard let initial = requested else { return }
            addTextAtViewportCenter(initial: initial)
            addTextRequest = nil
        }
        .onChange(of: addImageRequest) { _, requested in
            guard let data = requested else { return }
            addImageAtViewportCenter(data)
            addImageRequest = nil
        }
    }

    /// Capture the sketch in place — the new snapshot lands at
    /// the sketch's current `sketchPosition`, so visually the
    /// sketch frame transforms into a snapshot without jumping.
    private func performCaptureAtViewportCenter() {
        guard !store.canvas.activeSketch.strokes.isEmpty else { return }

        let z = store.canvas.snapshots.count
        do {
            _ = try store.captureSnapshot(
                at: Double(sketchPosition.x),
                y: Double(sketchPosition.y),
                z: z)
            // Capture cleared the active sketch; close the local
            // reveal so the field returns to "snapshots only".
            sketchOpenedLocally = false
        } catch {
            assertionFailure("capture failed: \(error)")
        }
    }

    /// Compute the top-left of a `sketchSize`d frame so that the
    /// frame is centered on the current viewport. Used by both
    /// "+" (to place the sketch at viewport center) and the
    /// auto-reveal path (to make sure incoming peer drawings
    /// show up where the local user is actually looking).
    ///
    /// Math: invert the field's view transform. The viewport
    /// center in field coords is `(screen_center - pan) / scale`;
    /// shift by half the tile so what we return is the frame's
    /// top-left, which is what `.offset(x:y:)` expects.
    private func topLeftCenteredOnViewport() -> CGPoint {
        let screenCenter = CGPoint(
            x: containerSize.width / 2,
            y: containerSize.height / 2)
        let fieldCenter = CGPoint(
            x: (screenCenter.x - currentPan.width) / currentScale,
            y: (screenCenter.y - currentPan.height) / currentScale)
        return CGPoint(
            x: fieldCenter.x - Self.sketchSize.width / 2,
            y: fieldCenter.y - Self.sketchSize.height / 2)
    }

    /// Single source of truth for "is the active sketch on screen
    /// right now". Only the local-open flag controls this — we
    /// don't auto-show based on doc state, because old strokes
    /// from a previous session shouldn't force the frame open
    /// when the user re-enters a board. Live collab is preserved
    /// by `.onChange` below: a 0 → N transition in active strokes
    /// (i.e., a peer just started drawing) flips
    /// `sketchOpenedLocally` so the user sees the collab arrive.
    private var isSketchVisible: Bool {
        sketchOpenedLocally
    }

    /// Either the sketch is open OR a snapshot is being edited
    /// — anything that needs the bottom tool pill.
    private var hasEditableSurface: Bool {
        isSketchVisible || editingSnapshotId != nil
    }

    // MARK: - Transformed content

    @ViewBuilder
    private func content(in containerSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Faint dot grid. `.drawingGroup()` caches the dot
            // pattern as a single Metal-backed bitmap so panning
            // the field doesn't re-rasterize thousands of dots
            // each frame — the cached layer just translates.
            // Hit testing is off either way, so caching is safe.
            dotGrid(size: gridCoverage(containerSize: containerSize))
                .drawingGroup(opaque: false)
                .offset(x: gridOrigin(containerSize: containerSize).x,
                        y: gridOrigin(containerSize: containerSize).y)
                .allowsHitTesting(false)

            // Active sketch frame at the user's chosen position.
            // Shown when:
            //  • the user opened it locally with "+", OR
            //  • the doc says the active sketch has strokes
            //    (someone else is mid-draw — keep collab live).
            //
            // `sketchPosition` is view state only — set to the
            // current viewport center when the user taps "+".
            if isSketchVisible {
                frame(
                    title: "Sketch",
                    titleColor: .accentColor,
                    isActive: true,
                    content: { activeSketchBody }
                )
                .offset(x: sketchPosition.x, y: sketchPosition.y)
            }

            // Captured snapshots.
            ForEach(Array(store.canvas.snapshots.enumerated()), id: \.element.id) { idx, snap in
                snapshotFrame(index: idx, snapshot: snap)
                    .offset(
                        x: snap.x + draggingOffset(for: snap.id).width,
                        y: snap.y + draggingOffset(for: snap.id).height)
            }

            // Image notes. Rendered before text so text can sit
            // above images by z-order if a user really wants that.
            ForEach(store.canvas.images) { image in
                imageNoteView(image)
                    .offset(
                        x: image.x + draggingOffset(for: image.id).width,
                        y: image.y + draggingOffset(for: image.id).height)
            }

            // Text notes — top of the z-stack so they're never
            // hidden under an image accidentally.
            ForEach(store.canvas.texts) { note in
                textNoteView(note)
                    .offset(
                        x: note.x + draggingOffset(for: note.id).width,
                        y: note.y + draggingOffset(for: note.id).height)
            }

            // Peer cursors. Drawn inside the transformed layer so
            // they live in field coordinates and pan / zoom with
            // the plane. Cursors from peers drawing in the sketch
            // are already in sketch-local coords (= field coords
            // because the sketch frame is anchored at the field
            // origin), so they line up naturally.
            ForEach(peerCursors, id: \.peerId) { entry in
                PeerCursor(color: entry.color)
                    .offset(
                        x: entry.position.x - PeerCursor.dotSize / 2,
                        y: entry.position.y - PeerCursor.dotSize / 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// One frame's worth of chrome: title floating above, frame
    /// body below. Pulled out so the active sketch and snapshots
    /// share the exact same surface treatment.
    @ViewBuilder
    private func frame<Body: View>(
        title: String,
        titleColor: Color,
        isActive: Bool,
        @ViewBuilder content: () -> Body
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(titleColor)
                .offset(y: -Self.titleHeight)

            content()
                .frame(width: Self.sketchSize.width, height: Self.sketchSize.height)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.accentColor.opacity(0.55) : Color.black.opacity(0.06),
                            lineWidth: isActive ? 1.5 : 0.5)
                )
                .shadow(color: .black.opacity(0.10),
                        radius: isActive ? 14 : 10,
                        x: 0, y: 4)
        }
    }

    private var activeSketchBody: some View {
        ZStack {
            CanvasView(
                store: store,
                target: .activeSketch,
                documentId: documentId,
                presence: presence,
                tool: tool,
                color: color,
                width: width)
            // Peers' in-progress strokes are drawn inside the
            // active sketch frame because they're in sketch-local
            // coordinates. Each is colored with the peer's
            // identity color so multiple drawers stay
            // distinguishable.
            ForEach(peerLiveStrokes, id: \.peerId) { entry in
                Canvas { ctx, _ in
                    guard !entry.stroke.points.isEmpty else { return }
                    ctx.stroke(
                        FieldView.strokePath(for: entry.stroke.points),
                        with: .color(entry.color),
                        style: StrokeStyle(
                            lineWidth: entry.stroke.width,
                            lineCap: .round,
                            lineJoin: .round))
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// One snapshot, in either view or edit mode. View mode is
    /// the read-only tile + drag-to-reposition + tap-to-edit;
    /// edit mode swaps in a `CanvasView` targeting this snapshot
    /// and exposes a Done button in the title row.
    ///
    /// Splitting drag (move) and tap (edit) is the usual SwiftUI
    /// trick of attaching `.onTapGesture` separately from the
    /// drag — short presses fire the tap, longer movements fire
    /// the drag. We only attach the drag gesture when NOT editing
    /// so the drawing surface inside the tile owns the touch.
    @ViewBuilder
    private func snapshotFrame(index: Int, snapshot: Snapshot) -> some View {
        let isEditing = editingSnapshotId == snapshot.id
        let title = "Snapshot \(index + 1)"
        ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isEditing ? Color.accentColor : Color.secondary)
                if isEditing {
                    Button {
                        editingSnapshotId = nil
                    } label: {
                        Text("Done")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .offset(y: -Self.titleHeight)

            snapshotBody(snapshot: snapshot, isEditing: isEditing)
                .frame(width: Self.sketchSize.width, height: Self.sketchSize.height)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isEditing ? Color.accentColor.opacity(0.55) : Color.black.opacity(0.06),
                            lineWidth: isEditing ? 1.5 : 0.5))
                .shadow(color: .black.opacity(0.10),
                        radius: isEditing ? 14 : 10,
                        x: 0, y: 4)
        }
        // Hit area = the whole ZStack (title + body). Without
        // this, clicks on the title row — which sits ~22pt above
        // the body but is visually part of the snapshot — used
        // to fall through to the field's pan gesture, so a drag
        // started on what looked like the snapshot was actually
        // a pan and the tile appeared to fly off as the whole
        // field panned underneath it.
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap enters edit mode. Tap-to-deselect is the Done
            // button's job.
            if !isEditing { editingSnapshotId = snapshot.id }
        }
        // Move-by-drag only in view mode. In edit mode the drag
        // belongs to the drawing surface inside the tile.
        .gesture(isEditing ? nil : dragGesture(for: snapshot))
    }

    // MARK: - Text + image notes

    @State private var editingTextId: UUID?
    @State private var textEditDraft: String = ""

    @ViewBuilder
    private func textNoteView(_ note: TextNote) -> some View {
        let isEditing = editingTextId == note.id
        Group {
            if isEditing {
                TextField("", text: $textEditDraft, axis: .vertical)
                    .font(.system(size: CGFloat(note.fontSize)))
                    .foregroundStyle(Color(rgba: note.color))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.95))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.accentColor, lineWidth: 1)))
                    .textFieldStyle(.plain)
                    .onSubmit { commitTextEdit() }
                    .frame(maxWidth: 320, alignment: .leading)
            } else {
                Text(note.text.isEmpty ? "Empty note" : note.text)
                    .font(.system(size: CGFloat(note.fontSize)))
                    .foregroundStyle(
                        note.text.isEmpty
                            ? Color.secondary.opacity(0.6)
                            : Color(rgba: note.color))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.7)))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        beginTextEdit(note)
                    }
                    .gesture(textDragGesture(for: note))
            }
        }
    }

    private func beginTextEdit(_ note: TextNote) {
        textEditDraft = note.text
        editingTextId = note.id
    }

    private func commitTextEdit() {
        guard let id = editingTextId else { return }
        let trimmed = textEditDraft
        editingTextId = nil
        do { try store.updateText(id: id, to: trimmed) }
        catch { assertionFailure("updateText failed: \(error)") }
    }

    private func textDragGesture(for note: TextNote) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                draggingSnapshot = (note.id, value.translation)
            }
            .onEnded { value in
                let dx = value.translation.width / currentScale
                let dy = value.translation.height / currentScale
                do {
                    try store.moveText(id: note.id, to: note.x + dx, y: note.y + dy)
                } catch {
                    assertionFailure("moveText failed: \(error)")
                }
                draggingSnapshot = nil
            }
    }

    @ViewBuilder
    private func imageNoteView(_ image: ImageNote) -> some View {
        ImageNoteView(image: image)
            .frame(width: CGFloat(image.width), height: CGFloat(image.height))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 2)
            .contentShape(Rectangle())
            .gesture(imageDragGesture(for: image))
    }

    private func imageDragGesture(for image: ImageNote) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                draggingSnapshot = (image.id, value.translation)
            }
            .onEnded { value in
                let dx = value.translation.width / currentScale
                let dy = value.translation.height / currentScale
                do {
                    try store.moveImage(id: image.id, to: image.x + dx, y: image.y + dy)
                } catch {
                    assertionFailure("moveImage failed: \(error)")
                }
                draggingSnapshot = nil
            }
    }

    /// Add a text note at the user's current viewport center.
    /// Called by the "+text" toolbar button and the Cmd+V paste
    /// handler when the clipboard contains a string.
    func addTextAtViewportCenter(initial: String = "") {
        let topLeft = topLeftCenteredOnViewport()
        do {
            let note = try store.addText(
                at: Double(topLeft.x + Self.sketchSize.width / 2),
                y: Double(topLeft.y + Self.sketchSize.height / 2),
                text: initial)
            if initial.isEmpty {
                // Drop the user straight into edit mode so they
                // can type without an extra tap.
                beginTextEdit(note)
            }
        } catch {
            assertionFailure("addText failed: \(error)")
        }
    }

    /// Add an image note at the user's current viewport center.
    func addImageAtViewportCenter(_ data: Data) {
        let topLeft = topLeftCenteredOnViewport()
        let fieldCenter = CGPoint(
            x: topLeft.x + Self.sketchSize.width / 2,
            y: topLeft.y + Self.sketchSize.height / 2)
        // Place image centered on the viewport's field-center.
        guard var note = ImageNote.make(
            from: data,
            at: fieldCenter.x, y: fieldCenter.y,
            z: store.canvas.images.count)
        else { return }
        // Shift so the image is centered, not top-lefted, on
        // the viewport.
        note.x -= note.width / 2
        note.y -= note.height / 2
        do { _ = try store.addImage(note) }
        catch { assertionFailure("addImage failed: \(error)") }
    }

    @ViewBuilder
    private func snapshotBody(snapshot: Snapshot, isEditing: Bool) -> some View {
        if isEditing {
            CanvasView(
                store: store,
                target: .snapshot(snapshot.id),
                documentId: documentId,
                presence: presence,
                tool: tool,
                color: color,
                width: width)
        } else {
            SnapshotTileView(snapshot: snapshot)
        }
    }

    /// Flattened list of all peers currently drawing on this board.
    /// Filters by `lastDocumentId` so peers active on a different
    /// board don't bleed into this one's overlay.
    private var peerLiveStrokes: [PeerStrokeEntry] {
        let boardId = documentId.id
        return presence.peers.compactMap { (peerId, state) in
            guard let stroke = state.liveStroke,
                  state.lastDocumentId == boardId
            else { return nil }
            return PeerStrokeEntry(
                peerId: peerId,
                stroke: stroke,
                color: state.color)
        }
    }

    /// Flattened list of peer cursors (in field coords).
    private var peerCursors: [PeerCursorEntry] {
        let boardId = documentId.id
        return presence.peers.compactMap { (peerId, state) in
            guard let cursor = state.cursor,
                  state.lastDocumentId == boardId
            else { return nil }
            return PeerCursorEntry(
                peerId: peerId,
                position: cursor,
                color: state.color)
        }
    }

    // MARK: - Grid

    /// Grid coverage. Three viewport-widths in each direction is
    /// generous for casual use without blowing the cached bitmap
    /// out to silly pixel dimensions. If the user pans very far,
    /// the grid will fall off; the backdrop color extends past it
    /// so they won't see a sharp edge of "the world ends here".
    private func gridCoverage(containerSize: CGSize) -> CGSize {
        CGSize(
            width: max(containerSize.width * 3, Self.sketchSize.width * 4),
            height: max(containerSize.height * 3, Self.sketchSize.height * 4))
    }

    private func gridOrigin(containerSize: CGSize) -> CGPoint {
        let coverage = gridCoverage(containerSize: containerSize)
        return CGPoint(
            x: -coverage.width / 2 + Self.sketchSize.width / 2,
            y: -coverage.height / 2 + Self.sketchSize.height / 2)
    }

    private func dotGrid(size: CGSize) -> some View {
        Canvas { ctx, _ in
            let spacing = Self.gridSpacing
            // Dot color tuned to be subtly visible against the
            // backdrop without competing with frames.
            let dotColor = Color(white: 0.78)
            let radius: CGFloat = 0.9
            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    let rect = CGRect(
                        x: x - radius, y: y - radius,
                        width: radius * 2, height: radius * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
                    y += spacing
                }
                x += spacing
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Gestures

    private var currentScale: CGFloat { scale * pendingScale }

    private var currentPan: CGSize {
        CGSize(width: pan.width + pendingPan.width,
               height: pan.height + pendingPan.height)
    }

    private func draggingOffset(for id: UUID) -> CGSize {
        guard let dragging = draggingSnapshot, dragging.id == id else {
            return .zero
        }
        return CGSize(
            width: dragging.translation.width / currentScale,
            height: dragging.translation.height / currentScale)
    }

    private var panGesture: some Gesture {
        // Same `.global` rationale as the snapshot drag — keep
        // translations unambiguously in screen pts. The pan
        // doesn't divide by scale because we're moving the field
        // itself in screen-space.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                pendingPan = value.translation
            }
            .onEnded { value in
                pan = CGSize(
                    width: pan.width + value.translation.width,
                    height: pan.height + value.translation.height)
                pendingPan = .zero
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                pendingScale = value
            }
            .onEnded { value in
                scale = clampScale(scale * value)
                pendingScale = 1.0
            }
    }

    /// Hard-clamp zoom so the user can't pinch into oblivion or
    /// invert the canvas. Half-size up to 4× is plenty for arranging.
    private func clampScale(_ s: CGFloat) -> CGFloat {
        max(0.25, min(4.0, s))
    }

    private func dragGesture(for snapshot: Snapshot) -> some Gesture {
        // Pin the coordinate space to `.global` so `value.translation`
        // is unambiguously in screen points regardless of whatever
        // .scaleEffect / .offset is wrapping us. SwiftUI's default
        // `.local` coord space behaves inconsistently inside a
        // scaled parent (sometimes screen-space, sometimes inner
        // scaled-space) — that ambiguity was the actual cause of
        // the "snapshot flies off the screen" behavior: with scale
        // 1.0 the translation was screen pts (works), with any
        // other scale we were dividing the wrong quantity by the
        // scale and ending up with grossly amplified field-pt
        // movement. `.global` removes the ambiguity; we always
        // divide screen-pts by scale to get field-pts.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                draggingSnapshot = (snapshot.id, value.translation)
            }
            .onEnded { value in
                let dx = value.translation.width / currentScale
                let dy = value.translation.height / currentScale
                do {
                    try store.moveSnapshot(
                        id: snapshot.id,
                        to: snapshot.x + dx,
                        y: snapshot.y + dy)
                } catch {
                    assertionFailure("moveSnapshot failed: \(error)")
                }
                draggingSnapshot = nil
            }
    }

    // MARK: - Initial framing

    private func centerSketchOnce(in size: CGSize) {
        guard !didCenter else { return }
        didCenter = true
        pan = CGSize(
            width: (size.width - Self.sketchSize.width) / 2,
            height: (size.height - Self.sketchSize.height) / 2)
    }
}

// MARK: - Presence overlays

private struct PeerStrokeEntry {
    let peerId: String
    let stroke: PeerLiveStroke
    let color: Color
}

private struct PeerCursorEntry {
    let peerId: String
    let position: CGPoint
    let color: Color
}

/// Bridge that turns the raw bytes stored in an `ImageNote.data`
/// blob into a SwiftUI `Image`. Cross-platform: iOS via `UIImage`,
/// macOS via `NSImage`. Rendering is non-interactive — the
/// parent FieldView attaches gestures.
private struct ImageNoteView: View {
    let image: ImageNote

    var body: some View {
        if let img = Self.image(from: image.data) {
            img
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .overlay(
                    Text("Image")
                        .font(.caption)
                        .foregroundStyle(.secondary))
        }
    }

    /// Decode bytes to a SwiftUI Image, picking the right
    /// platform-image type so we don't carry a CoreGraphics
    /// dependency in callers.
    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let ns = NSImage(data: data) else { return nil }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }
}

/// The little colored dot we render at a peer's reported cursor
/// position. Kept small and shadowless so it doesn't fight with
/// the sketch content underneath.
private struct PeerCursor: View {
    let color: Color
    static let dotSize: CGFloat = 12
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Self.dotSize, height: Self.dotSize)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 1.5))
    }
}

extension FieldView {
    /// Shared midpoint-quadratic smoothing — same algorithm
    /// `CanvasView` uses for its render path. Lifted to a static
    /// so peer-stroke rendering doesn't have to duplicate it.
    fileprivate static func strokePath(for points: [Point]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        let p0 = CGPoint(x: first.x, y: first.y)
        path.move(to: p0)

        if points.count == 1 {
            path.addLine(to: CGPoint(x: p0.x + 0.01, y: p0.y))
            return path
        }
        if points.count == 2 {
            let p1 = CGPoint(x: points[1].x, y: points[1].y)
            path.addLine(to: p1)
            return path
        }

        let firstMid = midpoint(
            CGPoint(x: points[0].x, y: points[0].y),
            CGPoint(x: points[1].x, y: points[1].y))
        path.addLine(to: firstMid)
        for i in 1..<(points.count - 1) {
            let ctrl = CGPoint(x: points[i].x, y: points[i].y)
            let nextMid = midpoint(
                ctrl,
                CGPoint(x: points[i + 1].x, y: points[i + 1].y))
            path.addQuadCurve(to: nextMid, control: ctrl)
        }
        let last = points[points.count - 1]
        path.addLine(to: CGPoint(x: last.x, y: last.y))
        return path
    }

    fileprivate static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

// MARK: - Snapshot tile

/// Renders a frozen snapshot's strokes. The framing chrome (border,
/// shadow, title) is provided by `FieldView.frame`, so this view
/// just paints the strokes onto a transparent canvas.
private struct SnapshotTileView: View {
    let snapshot: Snapshot

    var body: some View {
        Canvas { ctx, _ in
            for stroke in snapshot.strokes {
                guard !stroke.points.isEmpty else { continue }
                let path = strokePath(for: stroke.points)
                ctx.stroke(
                    path,
                    with: .color(Color(rgba: stroke.color)),
                    style: StrokeStyle(
                        lineWidth: stroke.width,
                        lineCap: .round,
                        lineJoin: .round))
            }
        }
        // Cache the rendered tile as a Metal bitmap so dragging
        // the snapshot (or panning the whole field) just
        // translates the cached layer — no per-frame redraw of
        // every stroke. When the snapshot's content changes
        // (peer edit, local edit-mode commit) SwiftUI re-evaluates
        // the body and the cache gets refreshed once.
        .drawingGroup(opaque: false)
    }

    /// Same midpoint-quadratic smoothing used by `CanvasView`.
    /// Duplicated rather than shared because pulling it into a
    /// helper file would mean two render call sites importing it
    /// — when the live and frozen renderers diverge (variable
    /// width, pressure-aware shading), keeping them separate makes
    /// that easy. Revisit if a third caller appears.
    private func strokePath(for points: [Point]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        let p0 = CGPoint(x: first.x, y: first.y)
        path.move(to: p0)

        if points.count == 1 {
            path.addLine(to: CGPoint(x: p0.x + 0.01, y: p0.y))
            return path
        }
        if points.count == 2 {
            let p1 = CGPoint(x: points[1].x, y: points[1].y)
            path.addLine(to: p1)
            return path
        }

        let firstMid = midpoint(
            CGPoint(x: points[0].x, y: points[0].y),
            CGPoint(x: points[1].x, y: points[1].y))
        path.addLine(to: firstMid)
        for i in 1..<(points.count - 1) {
            let ctrl = CGPoint(x: points[i].x, y: points[i].y)
            let nextMid = midpoint(
                ctrl,
                CGPoint(x: points[i + 1].x, y: points[i + 1].y))
            path.addQuadCurve(to: nextMid, control: ctrl)
        }
        let last = points[points.count - 1]
        path.addLine(to: CGPoint(x: last.x, y: last.y))
        return path
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
