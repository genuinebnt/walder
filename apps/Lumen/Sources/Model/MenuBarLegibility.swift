import AppKit
import CoreGraphics

/// Judges whether the menu bar will be readable over a wallpaper.
///
/// macOS draws the menu bar directly on the desktop picture and picks its text
/// colour from the whole image, not from the strip the text actually sits on.
/// A wallpaper that is dark overall but bright along the top — or busy with
/// detail there — leaves the menu bar hard to read. This samples the strip the
/// menu bar will occupy, after the crop macOS would apply, and says so.
enum MenuBarLegibility {
    struct Verdict {
        /// True when the strip is likely to make the menu bar hard to read.
        let isRisky: Bool
        let summary: String
        /// Mean luminance of the strip, 0...1.
        let luminance: Double
        /// How much the strip varies — busy detail is as bad as a mid tone.
        let variation: Double
    }

    /// Height of the menu bar in points. Sampling a little more than it
    /// occupies is deliberate: text sits inside the bar with margin.
    private static let barHeight: CGFloat = 26

    /// Assesses `image` as it would appear filling a display of `displaySize`.
    static func assess(_ image: NSImage, displaySize: CGSize) -> Verdict? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width > 0, cgImage.height > 0,
              displaySize.width > 0, displaySize.height > 0
        else { return nil }

        // The part of the image that survives a centre-crop to the display's
        // shape, which is what macOS shows.
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scale = max(displaySize.width / imageSize.width,
                        displaySize.height / imageSize.height)
        let visible = CGSize(width: displaySize.width / scale,
                             height: displaySize.height / scale)
        let originX = (imageSize.width - visible.width) / 2
        let originY = (imageSize.height - visible.height) / 2

        // The menu bar's share of that, in image pixels. CGImage is top-left
        // origin, so the top of the screen is the top of the crop.
        let stripHeight = max(1, (barHeight / displaySize.height) * visible.height)
        let strip = CGRect(x: originX, y: originY, width: visible.width, height: stripHeight)
            .integral

        guard let cropped = cgImage.cropping(to: strip) else { return nil }
        return measure(cropped)
    }

    /// Downsamples the strip to a handful of pixels and reads them. Sampling
    /// rather than scanning keeps this cheap enough to run per wallpaper.
    private static func measure(_ strip: CGImage) -> Verdict? {
        let width = 64, height = 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminances: [Double] = []
        luminances.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            // Rec. 709 luma, which is close enough to perceived brightness.
            luminances.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        guard !luminances.isEmpty else { return nil }

        let mean = luminances.reduce(0, +) / Double(luminances.count)
        let variance = luminances.reduce(0) { $0 + pow($1 - mean, 2) } / Double(luminances.count)
        let deviation = sqrt(variance)

        // Two ways a menu bar goes unreadable: a mid tone that neither white
        // nor black text sits well on, and detail busy enough that whichever
        // colour is chosen fails somewhere along the bar.
        let midTone = mean > 0.34 && mean < 0.68
        let busy = deviation > 0.20

        let summary: String
        if busy && midTone {
            summary = "Busy mid-tones under the menu bar"
        } else if busy {
            summary = "Lots of detail under the menu bar"
        } else if midTone {
            summary = "Mid-tone under the menu bar"
        } else if mean <= 0.34 {
            summary = "Dark under the menu bar — reads well"
        } else {
            summary = "Light under the menu bar — reads well"
        }

        return Verdict(isRisky: busy || midTone,
                       summary: summary,
                       luminance: mean,
                       variation: deviation)
    }
}
