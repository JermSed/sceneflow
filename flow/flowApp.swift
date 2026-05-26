//
//  flowApp.swift
//  flow
//

import SwiftUI
import AutomergeRepo

@main
struct flowApp: App {

    /// One library per app instance. Lives on `Application Support`
    /// and survives launches. If we can't open that directory we have
    /// no place to put boards — fatalError is acceptable here because
    /// the user can't do anything useful in that state.
    @StateObject private var library: BoardLibrary = {
        do {
            return try BoardLibrary()
        } catch {
            fatalError("Failed to open BoardLibrary: \(error)")
        }
    }()

    /// State for the "joining a board via share URL" flow. We hold
    /// the in-flight DocumentId while the join completes so the UI
    /// can show progress / errors out of band of the list view.
    @State private var pendingJoin: PendingJoin?

    var body: some Scene {
        WindowGroup {
            BoardListView()
                .environmentObject(library)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .overlay(alignment: .top) {
                    if let job = pendingJoin {
                        joinBanner(for: job)
                    }
                }
        }
    }

    // MARK: - URL handling

    /// Accepts `sceneflow://board/<documentIdString>` URLs.
    ///
    /// Anything else is dropped silently — the OS only routes URLs
    /// of schemes we registered in Info.plist, so we shouldn't see
    /// foreign schemes here in normal use.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "sceneflow" else { return }

        // Two URL shapes to be tolerant of:
        //   sceneflow://board/<id>   → host = "board", path = "/<id>"
        //   sceneflow:/board/<id>    → host = nil, path = "/board/<id>"
        // The first is what we generate; the second is what some
        // sloppy share-sheet pasters produce. Accept both.
        let path = (url.host.map { [$0] } ?? []) + url.pathComponents.filter { $0 != "/" }
        guard path.count >= 2, path[0] == "board" else { return }
        let docIdString = path[1]
        guard let docId = DocumentId(docIdString) else { return }

        pendingJoin = PendingJoin(documentId: docId, status: .joining)
        Task {
            do {
                _ = try await library.joinBoard(
                    documentId: docId,
                    name: "Shared board")
                pendingJoin = PendingJoin(documentId: docId, status: .joined)
                // Clear the banner after a beat so it doesn't linger.
                try? await Task.sleep(for: .seconds(2))
                pendingJoin = nil
            } catch {
                pendingJoin = PendingJoin(
                    documentId: docId,
                    status: .failed(description: "\(error)"))
            }
        }
    }

    // MARK: - Pending-join banner

    @ViewBuilder
    private func joinBanner(for job: PendingJoin) -> some View {
        HStack {
            switch job.status {
            case .joining:
                ProgressView()
                    .controlSize(.small)
                Text("Joining shared board…")
            case .joined:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Joined — find it at the top of the list.")
            case .failed(let description):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Couldn't join.")
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Dismiss") { pendingJoin = nil }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut, value: job.status)
    }
}

/// A board-join attempt in flight. Held in app state so the URL
/// handler can fire and forget while the UI shows status.
private struct PendingJoin: Equatable {
    let documentId: DocumentId
    var status: Status

    enum Status: Equatable {
        case joining
        case joined
        case failed(description: String)
    }

    static func == (lhs: PendingJoin, rhs: PendingJoin) -> Bool {
        lhs.documentId.id == rhs.documentId.id && lhs.status == rhs.status
    }
}
