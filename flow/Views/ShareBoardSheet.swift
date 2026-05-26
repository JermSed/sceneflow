//
//  ShareBoardSheet.swift
//  flow
//
//  Modal sheet that hands the user a `sceneflow://board/<docId>`
//  link plus a generated QR code. Tapping the link copies it to
//  the clipboard so they can paste it into a chat app; the QR is
//  for the "scan this on the other device" path (handled by the
//  URL scheme + future scanner sheet).
//
//  We render the QR with CoreImage's `CIQRCodeGenerator`. The
//  generated image is tiny — we scale it up with `transformed(by:
//  CGAffineTransform(scaleX:y:))` and turn nearest-neighbour off
//  via `.interpolation(.none)` so the squares stay crisp.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct ShareBoardSheet: View {

    let summary: BoardSummary

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    private var shareURL: URL {
        // sceneflow://board/<documentIdString>?name=<encoded>
        // We use a custom URL scheme rather than universal links so
        // sharing works without DNS / Associated-Domains setup. The
        // bs58 documentId is already URL-safe (no slashes etc).
        // The name is a hint the receiver uses for its local label
        // ("<sender's name> - shared") — it isn't authoritative
        // (the board's actual content is the CRDT), but it's much
        // friendlier than the bs58 id when the joiner sees the row.
        var components = URLComponents()
        components.scheme = "sceneflow"
        components.host = "board"
        components.path = "/\(summary.documentIdString)"
        components.queryItems = [URLQueryItem(name: "name", value: summary.name)]
        return components.url!
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Anyone with this link can join the board and edit alongside you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    qrCode
                        .frame(maxWidth: 260, maxHeight: 260)
                        .padding(.horizontal)

                    VStack(spacing: 8) {
                        Text(shareURL.absoluteString)
                            .font(.caption)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .foregroundStyle(.secondary)

                        Button {
                            copyLink()
                        } label: {
                            Label(
                                didCopy ? "Copied" : "Copy link",
                                systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 24)
            }
            .navigationTitle("Share \(summary.name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var qrCode: some View {
        if let image = Self.makeQRCode(for: shareURL.absoluteString) {
            image
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        } else {
            // Should never happen for our URLs (they're short ASCII)
            // but render a visible fallback so a silent QR failure
            // doesn't leave the sheet looking broken.
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.1))
                .overlay(Text("Couldn't generate QR")
                    .foregroundStyle(.secondary))
                .frame(height: 260)
        }
    }

    private func copyLink() {
        #if os(iOS)
        UIPasteboard.general.string = shareURL.absoluteString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareURL.absoluteString, forType: .string)
        #endif
        didCopy = true
        // Reset after a short delay so the user can copy again if needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }

    /// Build a SwiftUI Image from a string via CIQRCodeGenerator.
    /// Returns nil if either the CIFilter or the conversion to a
    /// CGImage fails — both should be impossible for ASCII input.
    static func makeQRCode(for string: String) -> Image? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // "M" = medium error correction. Default is "L". Medium
        // tolerates more occlusion (corners covered by a finger,
        // glare on a screen) at the cost of a slightly denser code.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        // The raw output is a few pixels per QR module; scale it up
        // so SwiftUI can show it crisply. `.interpolation(.none)`
        // on the rendered Image keeps the upscaling pixel-perfect.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        #if os(iOS)
        return Image(uiImage: UIImage(cgImage: cg))
        #elseif os(macOS)
        return Image(nsImage: NSImage(cgImage: cg, size: .zero))
        #endif
    }
}
