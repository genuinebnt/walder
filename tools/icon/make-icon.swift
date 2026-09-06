import AppKit
import CoreGraphics

// Renders the Lumen app icon: a warm core blooming out through the brand blue
// on a near-black ground. Run through tools/icon/make-icon.sh, which turns the
// PNGs it writes into Resources/AppIcon.icns.

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// Apple's continuous-corner ratio for macOS app icons.
let cornerRatio: CGFloat = 0.2237

func makeIcon(size: CGFloat) -> Data? {
    let scale = size / 1024                       // all geometry authored at 1024
    guard let context = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    // Leave a hair of padding so the squircle edge stays crisp when downscaled.
    let inset = 8 * scale
    let body = rect.insetBy(dx: inset, dy: inset)
    let squircle = CGPath(roundedRect: body,
                          cornerWidth: body.width * cornerRatio,
                          cornerHeight: body.height * cornerRatio,
                          transform: nil)

    context.saveGState()
    context.addPath(squircle)
    context.clip()

    // Ground: a cool near-black, lifted slightly toward the top-right.
    let ground = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 0.113, green: 0.145, blue: 0.204, alpha: 1),   // #1D2534
            CGColor(red: 0.051, green: 0.063, blue: 0.090, alpha: 1),   // #0D1017
            CGColor(red: 0.027, green: 0.031, blue: 0.043, alpha: 1),   // #07080B
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        ground,
        start: CGPoint(x: size * 0.82, y: size),
        end: CGPoint(x: size * 0.15, y: 0),
        options: []
    )

    // The bloom: warm white core → brand blue → nothing.
    let centre = CGPoint(x: size * 0.5, y: size * 0.52)
    let bloom = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 1.000, green: 0.988, blue: 0.945, alpha: 1.00),
            CGColor(red: 1.000, green: 0.847, blue: 0.522, alpha: 0.95),  // warm falloff
            CGColor(red: 0.184, green: 0.671, blue: 1.000, alpha: 0.72),
            CGColor(red: 0.039, green: 0.518, blue: 1.000, alpha: 0.34),  // #0A84FF
            CGColor(red: 0.039, green: 0.400, blue: 0.900, alpha: 0.00),
        ] as CFArray,
        locations: [0, 0.14, 0.36, 0.58, 1]
    )!
    context.drawRadialGradient(
        bloom,
        startCenter: centre, startRadius: 0,
        endCenter: centre, endRadius: size * 0.46,
        options: []
    )

    // A thin ring at the bloom's edge — reads as a lens aperture at small sizes.
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    context.setLineWidth(max(1, 5 * scale))
    context.strokeEllipse(in: CGRect(
        x: centre.x - size * 0.305, y: centre.y - size * 0.305,
        width: size * 0.61, height: size * 0.61))

    context.restoreGState()

    // Outer hairline, so the icon separates from a light Dock.
    context.addPath(squircle)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    context.setLineWidth(max(1, 3 * scale))
    context.strokePath()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

// The sizes iconutil expects in an .iconset.
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = makeIcon(size: variant.size) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent("\(variant.name).png")
    try data.write(to: url)
}
print("wrote \(variants.count) PNGs to \(outputDirectory)")
