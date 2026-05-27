//
//  PeerPill.swift
//  flow
//
//  Overlapping avatar list in the board toolbar showing who else
//  is currently on this board. Same affordance Figma / Docs use:
//  a glanceable "who's here" indicator that doesn't compete with
//  the canvas itself.
//
//  Tapping the pill opens a small popover listing each peer by
//  name + colored dot. We cap the visible avatars at five and
//  show a "+N" overflow chip; the popover always shows everyone.
//
//  The local user is included as the first avatar with a subtle
//  "you" cue (white inner ring) so the user can confirm they're
//  using the color/name everyone else sees.
//

import SwiftUI

struct PeerPill: View {

    @ObservedObject var presence: PresenceCoordinator
    let documentId: String

    @State private var showRoster = false

    private static let maxVisible = 4

    var body: some View {
        Button { showRoster.toggle() } label: {
            HStack(spacing: -6) {
                avatar(color: presence.localColor, isLocal: true)
                ForEach(visibleRemote, id: \.peerId) { peer in
                    avatar(color: peer.color, isLocal: false)
                }
                if overflowCount > 0 {
                    Text("+\(overflowCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, minHeight: 22)
                        .padding(.horizontal, 4)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.08))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.white, lineWidth: 1.5))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(remoteOnBoard.count + 1) people on this board")
        .popover(isPresented: $showRoster, arrowEdge: .top) {
            roster
                .padding(12)
                .frame(minWidth: 220)
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Visible peers

    /// All remote peers currently on this board, sorted so the
    /// avatar order is stable across redraws. Materialized as a
    /// concrete struct (rather than tuples) because the implicit
    /// tuple types tripped the type-checker's complexity budget.
    private var remoteOnBoard: [RemotePeer] {
        var out: [RemotePeer] = []
        for (peerId, state) in presence.peers {
            guard state.lastDocumentId == documentId else { continue }
            out.append(RemotePeer(
                peerId: peerId,
                color: state.color,
                name: state.displayName ?? PeerPresence.fallbackName(for: peerId)))
        }
        return out.sorted { $0.peerId < $1.peerId }
    }

    private var visibleRemote: [RemotePeer] {
        Array(remoteOnBoard.prefix(Self.maxVisible))
    }

    private var overflowCount: Int {
        max(0, remoteOnBoard.count - Self.maxVisible)
    }

    // MARK: - Pieces

    private func avatar(color: Color, isLocal: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: 24, height: 24)
            .overlay(
                Circle()
                    .stroke(
                        isLocal ? Color.white : Color(white: 0.97),
                        lineWidth: 2))
    }

    /// Materialized form of "one remote peer to render". Avoids
    /// the tuple-typed prop that timed out the type-checker.
    private struct RemotePeer {
        let peerId: String
        let color: Color
        let name: String
    }

    private var roster: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                avatar(color: presence.localColor, isLocal: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(presence.localDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text("You")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !remoteOnBoard.isEmpty {
                Divider()
            }
            ForEach(remoteOnBoard, id: \.peerId) { peer in
                HStack(spacing: 10) {
                    avatar(color: peer.color, isLocal: false)
                    Text(peer.name)
                        .font(.system(size: 13))
                    Spacer()
                }
            }
        }
    }
}
