//
//  DrawingTool.swift
//  flow
//
//  Tool selection, color, and width — everything the toolbar pill
//  exposes to the user, plus the floating pill view itself.
//
//  Color and width are not tool-specific: switching from pen to
//  eraser doesn't reset them, because the user almost always wants
//  to come right back. Width DOES apply to both tools — eraser
//  width controls the erase radius (multiplied modestly so a 4pt
//  pen erases with a comfortable thumb-sized radius).
//

import SwiftUI

// MARK: - Tool

enum DrawingTool: String, CaseIterable, Identifiable, Sendable {
    case pen
    case eraser

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pen:    return "pencil.tip"
        case .eraser: return "eraser"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .pen:    return "Pen"
        case .eraser: return "Eraser"
        }
    }
}

// MARK: - Color & width palettes

/// Hand-picked color palette. Six entries: enough variety for a
/// session, few enough to fit in a single row without paginating.
/// Stored as 0xRRGGBBAA to match the doc's `Stroke.color` shape so
/// there's no conversion at the write boundary.
enum DrawingPalette {
    static let colors: [UInt32] = [
        0x111111FF,  // near-black (default)
        0xE53935FF,  // red
        0xFB8C00FF,  // orange
        0xFDD835FF,  // yellow
        0x43A047FF,  // green
        0x1E88E5FF,  // blue
        0x8E24AAFF,  // purple
        0xFFFFFFFF,  // white (for dark surfaces / highlight)
    ]

    /// Four discrete widths. Roughly fine-pen, normal-pen,
    /// marker, and big-marker. Discrete (not a slider) because
    /// continuous width feels twitchy when you're aiming at it
    /// with a finger.
    static let widths: [Double] = [1.5, 2.5, 5.0, 9.0]
}

// MARK: - Toolbar pill

/// Floating pill at the bottom of the canvas. Holds the tool
/// switch plus color and width pickers that pop over the pill
/// when tapped.
struct ToolbarPill: View {

    @Binding var tool: DrawingTool
    @Binding var color: UInt32
    @Binding var width: Double

    @State private var showColorPicker = false
    @State private var showWidthPicker = false

    var body: some View {
        HStack(spacing: 6) {
            toolSegment
            divider
            colorButton
            widthButton
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 3)
    }

    // MARK: Tool segment

    private var toolSegment: some View {
        HStack(spacing: 2) {
            ForEach(DrawingTool.allCases) { option in
                Button { tool = option } label: {
                    Image(systemName: option.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 38, height: 32)
                        .foregroundStyle(
                            tool == option ? Color.white : Color.primary.opacity(0.7))
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(tool == option ? Color.accentColor : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.accessibilityLabel)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 2)
    }

    // MARK: Color

    private var colorButton: some View {
        Button { showColorPicker.toggle() } label: {
            // Outer ring uses the current color so it reads as
            // "the active swatch" even at a glance.
            Circle()
                .fill(Color(rgba: color))
                .frame(width: 24, height: 24)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color")
        .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
            ColorGrid(color: $color, palette: DrawingPalette.colors) {
                showColorPicker = false
            }
            .padding(12)
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Width

    private var widthButton: some View {
        Button { showWidthPicker.toggle() } label: {
            // The button's dot scales with the current width so
            // the toolbar tells you the current stroke size at a
            // glance, even without opening the picker.
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: 32, height: 32)
                Circle()
                    .fill(Color(rgba: color))
                    .frame(width: widthPreviewSize, height: widthPreviewSize)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Width")
        .popover(isPresented: $showWidthPicker, arrowEdge: .bottom) {
            WidthGrid(width: $width, color: color, widths: DrawingPalette.widths) {
                showWidthPicker = false
            }
            .padding(12)
            .presentationCompactAdaptation(.popover)
        }
    }

    /// Map the current stroke width to a preview-dot diameter
    /// that's small enough to fit inside the 32pt button while
    /// remaining visibly distinct between the four width options.
    private var widthPreviewSize: CGFloat {
        let normalized = min(max(width, 1), 12)
        return 4 + CGFloat(normalized) * 1.2
    }
}

// MARK: - Color popover

private struct ColorGrid: View {
    @Binding var color: UInt32
    let palette: [UInt32]
    let onPick: () -> Void

    /// Two rows of four — fits without scrolling and reads as a
    /// proper palette rather than a long line.
    private let columns = [GridItem(.fixed(30), spacing: 10),
                           GridItem(.fixed(30), spacing: 10),
                           GridItem(.fixed(30), spacing: 10),
                           GridItem(.fixed(30), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(palette, id: \.self) { swatch in
                Button {
                    color = swatch
                    onPick()
                } label: {
                    Circle()
                        .fill(Color(rgba: swatch))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .stroke(
                                    swatch == color ? Color.accentColor : Color.black.opacity(0.15),
                                    lineWidth: swatch == color ? 2.5 : 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Width popover

private struct WidthGrid: View {
    @Binding var width: Double
    let color: UInt32
    let widths: [Double]
    let onPick: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(widths, id: \.self) { w in
                Button {
                    width = w
                    onPick()
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Capsule()
                                .fill(Color.clear)
                                .frame(width: 80, height: 18)
                            Capsule()
                                .fill(Color(rgba: color))
                                .frame(width: 70, height: CGFloat(w))
                        }
                        Spacer(minLength: 0)
                        if abs(w - width) < 0.01 {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(abs(w - width) < 0.01
                                  ? Color.accentColor.opacity(0.08)
                                  : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
