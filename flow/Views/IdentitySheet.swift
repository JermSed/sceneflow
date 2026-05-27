//
//  IdentitySheet.swift
//  flow
//
//  Settings sheet for the local user's display name. Persisted
//  in `UserDefaults` via `@AppStorage` so it survives launches
//  and is shared between any future settings entry points.
//
//  We seed a friendly default like "Curious Otter" on first
//  launch — much less awkward than an empty cursor label. The
//  user can change it any time; presence updates pick up the
//  new name on the next outgoing message.
//

import SwiftUI

/// Storage key for the local display name. Centralized so the
/// app entry point and the settings sheet stay in sync.
enum IdentityDefaults {
    static let displayNameKey = "displayName"
}

/// A small pool of friendly two-word defaults. We pick one at
/// random on first launch and persist it; from then on the user
/// owns the name. The list is hand-curated to avoid embarrassing
/// combinations.
enum IdentityNames {
    private static let adjectives = [
        "Curious", "Quiet", "Bright", "Clever", "Warm", "Cool",
        "Bold", "Calm", "Sunny", "Mellow", "Sharp", "Brisk"
    ]
    private static let animals = [
        "Otter", "Fox", "Heron", "Hare", "Lynx", "Wren",
        "Badger", "Falcon", "Stoat", "Newt", "Marten", "Crane"
    ]

    static func random() -> String {
        let a = adjectives.randomElement() ?? "Anonymous"
        let n = animals.randomElement() ?? "Otter"
        return "\(a) \(n)"
    }
}

struct IdentitySheet: View {

    @Environment(\.dismiss) private var dismiss
    @AppStorage(IdentityDefaults.displayNameKey) private var displayName: String = ""
    @State private var draft: String = ""

    /// Color the peer is currently rendered with. Passed in so
    /// the sheet can preview the "you on cursors" appearance.
    let color: Color

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Circle()
                            .fill(color)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        TextField("Your name", text: $draft)
                            #if os(iOS)
                            .textInputAutocapitalization(.words)
                            #endif
                            .autocorrectionDisabled(true)
                    }
                } header: {
                    Text("Display name")
                } footer: {
                    Text("Shown on your cursor and in the peers list for everyone you collaborate with.")
                }
            }
            .navigationTitle("You")
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
                        displayName = trimmed.isEmpty ? IdentityNames.random() : trimmed
                        dismiss()
                    }
                }
            }
            .onAppear {
                if displayName.isEmpty {
                    displayName = IdentityNames.random()
                }
                draft = displayName
            }
        }
    }
}
