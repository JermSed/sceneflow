//
//  SyncStatusIndicator.swift
//  flow
//
//  Small toolbar pill that surfaces sync state to the user:
//
//   • green dot  — WebSocket is connected and ready for messages
//   • amber dot  — connecting or reconnecting
//   • gray dot   — disconnected (offline; local edits still work)
//
//  The peer count is shown next to the dot once we have one. We
//  count peers from `WebSocketProvider.peeredConnections` which
//  is the list of peers we've actually completed the sync
//  handshake with — i.e. people we can exchange document changes
//  with right now, not just "is the relay socket open."
//
//  Why a separate view instead of inlining in BoardOpenView's
//  toolbar: SwiftUI's `@StateObject` semantics inside `@ToolbarContentBuilder`
//  closures are finicky and we want a stable Combine subscription
//  to `statePublisher` that doesn't churn as the toolbar rebuilds.
//

import SwiftUI
import Combine
import AutomergeRepo

struct SyncStatusIndicator: View {

    @ObservedObject var observer: SyncStatusObserver

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var color: Color {
        switch observer.state {
        case .ready:
            return observer.peerCount > 0 ? .green : .yellow
        case .connected, .reconnecting:
            return .orange
        case .disconnected:
            return .gray
        }
    }

    private var label: String {
        switch observer.state {
        case .ready:
            return observer.peerCount == 0
                ? "no peers"
                : "\(observer.peerCount) peer\(observer.peerCount == 1 ? "" : "s")"
        case .connected:
            return "connecting"
        case .reconnecting:
            return "reconnecting"
        case .disconnected:
            return "offline"
        }
    }

    private var accessibilityText: String {
        "Sync status: \(label)"
    }
}

/// Subscribes to the WebSocket provider's state + peer-list
/// publishers and republishes them as observable properties.
///
/// `@MainActor` because views read these properties directly. The
/// underlying provider is actor-isolated, so we receive its
/// updates on the main run loop.
@MainActor
final class SyncStatusObserver: ObservableObject {

    @Published private(set) var state: WebSocketProviderState = .disconnected
    @Published private(set) var peerCount: Int = 0

    private var stateSub: AnyCancellable?

    /// Poll the provider's peer list on a slow timer. The provider
    /// doesn't expose a Combine publisher for `peeredConnections`,
    /// so a timer is simpler than wrapping its internal state. A
    /// 2-second cadence is plenty for a status pill.
    private var pollTimer: AnyCancellable?

    init(provider: WebSocketProvider) {
        // `WebSocketProvider` is `@AutomergeRepo`-actor isolated, so
        // we have to hop over to read its publishers / properties.
        // We grab the state publisher once via an actor hop and then
        // subscribe on the main run loop; the publisher itself is
        // Sendable so once we have it the subscription is fine.
        let captured = self
        Task { @AutomergeRepo in
            let publisher = provider.statePublisher
            await MainActor.run {
                captured.stateSub = publisher
                    .receive(on: RunLoop.main)
                    .sink { [weak captured] newState in
                        captured?.state = newState
                    }
            }
        }

        pollTimer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self, weak provider] _ in
                guard let self, let provider else { return }
                Task { @AutomergeRepo in
                    let count = provider.peeredConnections.count
                    await MainActor.run { self.peerCount = count }
                }
            }
    }
}
