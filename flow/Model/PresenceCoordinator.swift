//
//  PresenceCoordinator.swift
//  flow
//
//  Phase 3 — the ephemeral presence channel.
//
//  CLAUDE.md is firm: presence data MUST NOT enter the Automerge
//  document. Cursors, peer identity, and in-progress strokes are
//  intentionally fleeting; persisting them would bloat the change
//  log and force every reload to re-render irrelevant state.
//
//  Originally this routed presence through `automerge-repo-swift`'s
//  ephemeral-message channel (`SyncV1Msg.ephemeral`). That doesn't
//  work in 0.3.2 — the library logs `UNIMPLEMENTED EPHEMERAL
//  MESSAGE PASSING` on the receive side and drops the message. So
//  Sceneflow ships a small side-channel WebSocket alongside the
//  sync server (`sync-server/presence.js`) and PresenceCoordinator
//  speaks to it directly via `URLSessionWebSocketTask`.
//
//  Wire format: a Codable `PresenceEnvelope` JSON-encoded. The
//  envelope carries the sender peer id, the board's documentId
//  (string), and a `PresenceMessage` variant:
//
//   • `.cursor` — peer's cursor moved; nothing being drawn.
//   • `.liveStroke` — peer is drawing; payload includes the full
//     points buffer so far. Idempotent — receivers replace their
//     stored copy with the latest payload.
//   • `.endStroke` — peer lifted their pen; receiver drops its
//     copy of the overlay since the doc-sync layer will deliver
//     the real stroke shortly.
//
//  Identity for the MVP is intentionally minimal: each peer has a
//  stable color derived from a per-launch UUID. No names yet —
//  the user explicitly chose "cursors only" for the first cut.
//
//  Stale-presence cleanup: a slow timer prunes peer entries we
//  haven't heard from in `peerStaleThreshold` seconds. That keeps
//  the cursor overlay clean when someone closes the app without
//  emitting a graceful goodbye.
//

import Foundation
import Combine
import SwiftUI

// MARK: - Public state types

/// What we know about another peer right now. Identified externally
/// by the peer ID (`String`); held by `PresenceCoordinator.peers`.
struct PeerPresence: Hashable, Sendable {
    /// Color derived from peer ID — stable across launches because
    /// the source string is stable.
    var color: Color
    /// Display name the peer broadcasts. Optional because not
    /// every message carries it; falls back to a short hex form
    /// of the peer id when nil (`PeerPresence.fallbackName(for:)`).
    var displayName: String?
    /// Last reported cursor in field coordinates, or `nil` if the
    /// peer hasn't moved their cursor recently.
    var cursor: CGPoint?
    /// In-progress stroke being drawn right now, or `nil` if the
    /// peer isn't actively dragging.
    var liveStroke: PeerLiveStroke?
    /// Which board (`DocumentId.id` form) the peer was last seen
    /// on. Views filter on this so a peer drawing in board A
    /// doesn't pollute a viewer who's looking at board B.
    var lastDocumentId: String?
    /// Last time we heard anything from this peer. Used by the
    /// cleanup timer to drop stale entries.
    var lastSeenAt: Date

    /// Short, deterministic label for peers that haven't told us
    /// their name yet. Six hex chars from the peer id is enough
    /// to distinguish at the scale we care about.
    static func fallbackName(for peerId: String) -> String {
        "Guest \(peerId.prefix(6))"
    }
}

struct PeerLiveStroke: Hashable, Sendable {
    var id: UUID
    var points: [Point]
    var color: UInt32
    var width: Double
}

// MARK: - Wire format

/// Envelope sent over the side-channel WebSocket. Always JSON.
///
/// Carries the sender's display name on every message so a peer
/// that connects mid-session learns names immediately rather than
/// having to wait for a hypothetical "hello" packet.
struct PresenceEnvelope: Codable, Sendable {
    var senderId: String
    var senderName: String?
    var documentId: String
    var msg: PresenceMessage
}

struct PresenceMessage: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case cursor
        case liveStroke
        case endStroke
    }
    var kind: Kind
    var cursor: WirePoint?
    var strokeId: String?
    var points: [WirePoint]?
    var color: UInt32?
    var width: Double?
}

struct WirePoint: Codable, Sendable {
    var x: Double
    var y: Double
}

// MARK: - Coordinator

@MainActor
final class PresenceCoordinator: ObservableObject {

    /// Peer state keyed by peer ID. SwiftUI observes this.
    @Published private(set) var peers: [String: PeerPresence] = [:]

    /// Our own peer ID. Each app launch gets a fresh UUID — peers
    /// across launches don't collide and we never accidentally
    /// render our own cursor back at ourselves.
    let localPeerId: String

    /// Color for the local peer (toolbar tint, future "you" label).
    let localColor: Color

    /// Display name the local peer sends out with every message.
    /// Settable so the settings sheet can update it live; sending
    /// happens next time the user moves the pen.
    @Published var localDisplayName: String = "You"

    /// URL of the presence relay.
    let relayURL: URL

    /// Cursor entries older than this are cleared. Full peer
    /// entries older than `peerStaleThreshold` are dropped.
    private let cursorStaleThreshold: TimeInterval = 3
    private let peerStaleThreshold: TimeInterval = 10

    private var transport: PresenceTransport
    private var pruneTimer: AnyCancellable?

    init(relayURL: URL = URL(string: "ws://localhost:3031")!) {
        self.relayURL = relayURL
        self.localPeerId = UUID().uuidString
        self.localColor = Self.color(for: localPeerId)
        self.transport = PresenceTransport(url: relayURL)
        self.transport.onReceive = { [weak self] data in
            self?.handleIncoming(data)
        }
        self.transport.connect()
        startPruneTimer()
    }

    // MARK: Sending

    /// Broadcast a cursor update (peer is hovering / panning, not drawing).
    func sendCursor(_ point: CGPoint, in documentId: DocumentIdProxy) {
        let envelope = makeEnvelope(
            for: documentId,
            msg: PresenceMessage(
                kind: .cursor,
                cursor: WirePoint(x: point.x, y: point.y)))
        send(envelope)
    }

    /// Broadcast the current in-progress stroke. Idempotent —
    /// receivers replace their stored copy with the latest payload.
    func sendLiveStroke(
        id: UUID,
        points: [Point],
        color: UInt32,
        width: Double,
        cursor: CGPoint,
        in documentId: DocumentIdProxy
    ) {
        let envelope = makeEnvelope(
            for: documentId,
            msg: PresenceMessage(
                kind: .liveStroke,
                cursor: WirePoint(x: cursor.x, y: cursor.y),
                strokeId: id.uuidString,
                points: points.map { WirePoint(x: $0.x, y: $0.y) },
                color: color,
                width: width))
        send(envelope)
    }

    /// Tell peers we lifted the pen. They drop their overlay; the
    /// doc-sync layer fills in the real stroke a moment later.
    func sendEndStroke(id: UUID, in documentId: DocumentIdProxy) {
        let envelope = makeEnvelope(
            for: documentId,
            msg: PresenceMessage(
                kind: .endStroke,
                strokeId: id.uuidString))
        send(envelope)
    }

    /// Common envelope assembly — keeps the sender id + name
    /// attached to every outgoing message in one place.
    private func makeEnvelope(
        for documentId: DocumentIdProxy,
        msg: PresenceMessage
    ) -> PresenceEnvelope {
        PresenceEnvelope(
            senderId: localPeerId,
            senderName: localDisplayName,
            documentId: documentId.stringValue,
            msg: msg)
    }

    private func send(_ envelope: PresenceEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        transport.send(data)
    }

    // MARK: Receiving

    private func handleIncoming(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(PresenceEnvelope.self, from: data),
              envelope.senderId != localPeerId
        else { return }
        ingest(envelope)
    }

    private func ingest(_ envelope: PresenceEnvelope) {
        let peerId = envelope.senderId
        var state = peers[peerId] ?? PeerPresence(
            color: Self.color(for: peerId),
            displayName: nil,
            cursor: nil,
            liveStroke: nil,
            lastDocumentId: nil,
            lastSeenAt: .now)
        state.lastSeenAt = .now
        state.lastDocumentId = envelope.documentId
        if let name = envelope.senderName, !name.isEmpty {
            state.displayName = name
        }

        switch envelope.msg.kind {
        case .cursor:
            state.cursor = envelope.msg.cursor.map { CGPoint(x: $0.x, y: $0.y) }
            state.liveStroke = nil
        case .liveStroke:
            state.cursor = envelope.msg.cursor.map { CGPoint(x: $0.x, y: $0.y) }
            if let idString = envelope.msg.strokeId, let id = UUID(uuidString: idString) {
                state.liveStroke = PeerLiveStroke(
                    id: id,
                    points: (envelope.msg.points ?? []).map {
                        Point(x: $0.x, y: $0.y, pressure: 0.5)
                    },
                    color: envelope.msg.color ?? 0x111111FF,
                    width: envelope.msg.width ?? 2.5)
            }
        case .endStroke:
            state.liveStroke = nil
        }

        peers[peerId] = state
    }

    // MARK: Pruning

    private func startPruneTimer() {
        pruneTimer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.prune() }
    }

    private func prune() {
        let now = Date()
        for (peerId, state) in peers {
            let age = now.timeIntervalSince(state.lastSeenAt)
            if age > peerStaleThreshold {
                peers.removeValue(forKey: peerId)
            } else if age > cursorStaleThreshold {
                var s = state
                s.cursor = nil
                s.liveStroke = nil
                peers[peerId] = s
            }
        }
    }

    // MARK: Identity

    /// Derive a stable color from a peer ID. Hash the bytes →
    /// take the low 8 bits as a hue, fix saturation and lightness
    /// for legibility on both light and dark canvases.
    static func color(for peerId: String) -> Color {
        var hasher = Hasher()
        hasher.combine(peerId)
        let h = hasher.finalize()
        let hue = Double(UInt(bitPattern: h) % 360) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.85)
    }
}

// MARK: - DocumentId proxy

/// Tiny shim so this file doesn't have to import `AutomergeRepo`.
/// The string form is all we put on the wire.
struct DocumentIdProxy {
    let stringValue: String
    init(_ s: String) { self.stringValue = s }
}

// MARK: - Transport

/// A reconnecting WebSocket that ships `Data` payloads to a relay
/// and surfaces incoming payloads via an `onReceive` callback.
///
/// Reconnect strategy: a small fixed backoff (1s). The presence
/// channel is purely best-effort — if it drops, we lose cursors
/// for a beat and pick them back up when the socket comes back.
/// No queueing of unsent messages; presence is intrinsically
/// "what's happening right now," and a stale cursor is worse than
/// a missed one.
final class PresenceTransport: NSObject, @unchecked Sendable {

    var onReceive: ((Data) -> Void)?

    private let url: URL
    private var task: URLSessionWebSocketTask?
    private lazy var session: URLSession = {
        URLSession(configuration: .default,
                   delegate: nil,
                   delegateQueue: nil)
    }()
    private var reconnectInFlight = false

    init(url: URL) {
        self.url = url
    }

    func connect() {
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop()
    }

    func send(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            // A send failure usually means the socket is dead.
            // Let the receive loop's failure path drive reconnect.
            if error != nil { self?.scheduleReconnect() }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    Task { @MainActor in self.onReceive?(data) }
                case .string(let str):
                    if let data = str.data(using: .utf8) {
                        Task { @MainActor in self.onReceive?(data) }
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure:
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard !reconnectInFlight else { return }
        reconnectInFlight = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.reconnectInFlight = false
            self.connect()
        }
    }
}
