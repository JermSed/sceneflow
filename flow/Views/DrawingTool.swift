//
//  DrawingTool.swift
//  flow
//
//  Which tool the user is currently holding. Lives at the
//  `BoardOpenView` level so the floating toolbar pill and the
//  drawing surface share the same selection.
//
//  Kept deliberately small for now (pen + eraser). When we add
//  color / width / shape tools they slot in alongside; the
//  segmented control in `ToolbarPill` grows to match.
//

import SwiftUI

enum DrawingTool: String, CaseIterable, Identifiable, Sendable {
    case pen
    case eraser

    var id: String { rawValue }

    /// SF Symbol used by the toolbar pill and any toolbar items
    /// that reflect the tool.
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

/// Floating pill at the bottom of the canvas that lets the user
/// pick a tool. Two segmented buttons today; will grow when we
/// add color / width pickers.
struct ToolbarPill: View {

    @Binding var tool: DrawingTool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DrawingTool.allCases) { option in
                Button {
                    tool = option
                } label: {
                    Image(systemName: option.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 40, height: 32)
                        .foregroundStyle(
                            tool == option ? Color.white : Color.primary.opacity(0.7))
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(tool == option
                                      ? Color.accentColor
                                      : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.accessibilityLabel)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
    }
}
