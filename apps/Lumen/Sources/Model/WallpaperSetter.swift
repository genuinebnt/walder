import AppKit

/// Applies a local image file to one or all screens.
///
/// This is the one piece the Rust core cannot own: `NSWorkspace` is the only
/// supported way to set a per-screen desktop image on macOS.
enum WallpaperSetter {
    static func apply(fileURL: URL, to screen: NSScreen?, fit: DisplayTarget.Fit) throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: scaling(for: fit).rawValue,
            .allowClipping: fit == .fill
        ]
        let targets = screen.map { [$0] } ?? NSScreen.screens
        for target in targets {
            try NSWorkspace.shared.setDesktopImageURL(fileURL, for: target, options: options)
        }
    }

    private static func scaling(for fit: DisplayTarget.Fit) -> NSImageScaling {
        switch fit {
        case .fill: .scaleProportionallyUpOrDown
        case .fit: .scaleProportionallyDown
        case .stretch: .scaleAxesIndependently
        }
    }

    /// Live screen list, mapped onto the app's display model.
    static func connectedDisplays() -> [DisplayTarget] {
        NSScreen.screens.enumerated().map { index, screen in
            let size = screen.frame.size
            let scale = screen.backingScaleFactor
            let pixels = CGSize(width: size.width * scale, height: size.height * scale)
            return DisplayTarget(
                id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .stringValue ?? "screen-\(index)",
                name: screen.localizedName,
                resolution: "\(Int(pixels.width)) × \(Int(pixels.height))",
                aspect: pixels.width / max(pixels.height, 1)
            )
        }
    }
}
