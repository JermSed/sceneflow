//
//  ImageImport.swift
//  flow
//
//  Helpers for getting an `ImageNote` out of platform image
//  sources (pasteboard payloads, dragged files) into the doc.
//
//  We compress on insert because Automerge sync ships the raw
//  bytes to every peer through the relay's WebSocket. A
//  full-resolution iPhone photo is ~3 MB; multiplied across a
//  team's session that's a lot to push around. Downscaling to
//  ~1600px wide / JPEG quality 0.8 keeps each image around
//  200–400 KB while still looking fine on iPad screens.
//

import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageImport {

    /// Max image dimension after downscale. Above this we resample;
    /// below, the original bytes pass through.
    static let maxDimension: CGFloat = 1600

    /// JPEG compression quality used when re-encoding photos.
    static let jpegQuality: CGFloat = 0.8

    /// Take arbitrary bytes (PNG, JPEG, HEIF...) and produce a
    /// downscaled JPEG suitable for embedding in the doc. Returns
    /// nil if `ImageIO` can't decode the input.
    ///
    /// Output is always JPEG so the renderer doesn't have to
    /// guess at format. Loses transparency — acceptable for
    /// photo-style images; for screenshots we keep PNG by going
    /// through `compressedPNG(_:)` instead.
    static func compressedJPEG(_ source: Data) -> (Data, CGFloat, CGFloat)? {
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        let scaled = downscale(cg)
        guard let data = encodeJPEG(scaled) else { return nil }
        return (data, CGFloat(scaled.width), CGFloat(scaled.height))
    }

    /// PNG variant for inputs that need to preserve transparency
    /// (UI screenshots, drawings, etc.). Detects PNG inputs by
    /// looking for the magic header.
    static func compressedPNG(_ source: Data) -> (Data, CGFloat, CGFloat)? {
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        let scaled = downscale(cg)
        guard let data = encodePNG(scaled) else { return nil }
        return (data, CGFloat(scaled.width), CGFloat(scaled.height))
    }

    /// Best-effort decode + downscale. Picks PNG when the original
    /// looked PNG-ish (preserves alpha), JPEG otherwise.
    static func bestEffortCompress(_ source: Data) -> (data: Data, width: CGFloat, height: CGFloat, format: String)? {
        let looksLikePNG = source.starts(with: [0x89, 0x50, 0x4E, 0x47])
        if looksLikePNG, let (d, w, h) = compressedPNG(source) {
            return (d, w, h, "png")
        }
        if let (d, w, h) = compressedJPEG(source) {
            return (d, w, h, "jpeg")
        }
        // Last resort: pass through raw, mark as best-effort jpeg.
        return (source, 800, 600, "jpeg")
    }

    // MARK: - Internals

    private static func downscale(_ cg: CGImage) -> CGImage {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let longest = max(w, h)
        guard longest > maxDimension else { return cg }

        let scale = maxDimension / longest
        let newW = Int((w * scale).rounded())
        let newH = Int((h * scale).rounded())

        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = cg.bitmapInfo.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: newW, height: newH,
            bitsPerComponent: cg.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return cg
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? cg
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

// MARK: - Platform image → ImageNote

#if canImport(UIKit)
import UIKit

extension ImageNote {
    /// Build an `ImageNote` from raw image bytes (typically from
    /// `UIPasteboard.general.image?.pngData()` etc.). Compresses
    /// the input to keep doc + sync payloads modest.
    static func make(from data: Data, at x: Double, y: Double, z: Int) -> ImageNote? {
        guard let result = ImageImport.bestEffortCompress(data) else { return nil }
        return ImageNote(
            id: UUID(),
            x: x, y: y, z: z,
            width: Double(result.width),
            height: Double(result.height),
            data: result.data,
            format: result.format)
    }
}
#elseif canImport(AppKit)
import AppKit

extension ImageNote {
    static func make(from data: Data, at x: Double, y: Double, z: Int) -> ImageNote? {
        guard let result = ImageImport.bestEffortCompress(data) else { return nil }
        return ImageNote(
            id: UUID(),
            x: x, y: y, z: z,
            width: Double(result.width),
            height: Double(result.height),
            data: result.data,
            format: result.format)
    }
}
#endif
