//
//  OfflineBanner.swift
//  flow
//
//  Thin reassurance banner shown at the top of the canvas when
//  the sync WebSocket is disconnected. The point isn't to scold
//  the user — Automerge is offline-first, their edits are safe
//  on disk — it's just to set the expectation that other peers
//  won't see what they're drawing right now.
//
//  Kept deliberately understated: cloud icon, short copy, soft
//  fill. We rely on the sync status pill in the toolbar to carry
//  the "actively reconnecting" affordance; the banner is the
//  bigger-typography fallback when sync simply isn't happening.
//

import SwiftUI

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Offline")
                    .font(.system(size: 13, weight: .semibold))
                Text("Your edits stay on this device and will sync when you reconnect.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 1)
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }
}
