import SwiftUI

/// Glass belongs to floating controls; artwork stays on a stable surface.
struct GlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(colorScheme == .dark ? Color(white: 0.18) : .white,
                               in: RoundedRectangle(cornerRadius: 22))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
            } else {
                fallback(content)
            }
            #else
            fallback(content)
            #endif
        }
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.16 : 0.65), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

extension View {
    func floatingGlass() -> some View { modifier(GlassSurface()) }
}
