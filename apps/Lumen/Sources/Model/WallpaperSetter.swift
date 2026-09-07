import AppKit
import CoreGraphics

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
            // Same measurement the fit report uses, or the two panes disagree
            // about the size of the same screen.
            let pixels = WallpaperFitter.pixelSize(of: screen)
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

/// Produces a copy of a wallpaper cropped and scaled to one display exactly.
///
/// Wallhaven serves a single file per wallpaper, so when the aspect ratio does
/// not match there is nothing better to download — the choice is to accept the
/// crop macOS would make anyway, or to make it deliberately here at the
/// display's own pixel size.
enum WallpaperFitter {
    /// Native pixel size of a screen — the panel's own resolution, which is
    /// what a wallpaper is really judged against.
    ///
    /// `frame × backingScaleFactor` gives the framebuffer, not the panel. On a
    /// scaled Retina mode those differ (3600×2260 backing over a 3024×1964
    /// panel), and using the larger number marked almost every wallpaper as
    /// upscaled when it was not.
    static func pixelSize(of screen: NSScreen) -> CGSize {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber,
           let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(number.uint32Value)),
           mode.pixelWidth > 0, mode.pixelHeight > 0 {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let scale = screen.backingScaleFactor
        return CGSize(width: screen.frame.width * scale,
                      height: screen.frame.height * scale)
    }

    static var mainPixelSize: CGSize {
        NSScreen.main.map(pixelSize) ?? CGSize(width: 1920, height: 1080)
    }

    /// Writes an exactly-sized copy next to the original and returns it.
    ///
    /// `crop` is normalised (0...1) in the source image's own space. Passing
    /// nil centre-crops, which is what macOS does on its own.
    static func render(_ sourceURL: URL, to size: CGSize, in directory: URL,
                       crop: CGRect? = nil) throws -> URL {
        guard size.width >= 1, size.height >= 1,
              let image = NSImage(contentsOf: sourceURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw Failure.unreadable }

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)

        // A chosen crop is taken out of the source first; the result is then
        // scaled to the display. Without one, fall back to a centre crop.
        let source: CGImage
        if let crop, crop.width > 0, crop.height > 0 {
            let pixels = CGRect(x: crop.minX * imageSize.width,
                                y: crop.minY * imageSize.height,
                                width: crop.width * imageSize.width,
                                height: crop.height * imageSize.height).integral
            source = cgImage.cropping(to: pixels) ?? cgImage
        } else {
            source = cgImage
        }

        let sourceSize = CGSize(width: source.width, height: source.height)
        let scale = max(size.width / sourceSize.width, size.height / sourceSize.height)
        let scaled = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)

        guard let context = CGContext(
            data: nil,
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw Failure.unreadable }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(
            x: (size.width - scaled.width) / 2,
            y: (size.height - scaled.height) / 2,
            width: scaled.width, height: scaled.height))

        guard let output = context.makeImage() else { throw Failure.unreadable }
        let rep = NSBitmapImageRep(cgImage: output)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
        else { throw Failure.unreadable }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(
            path: "\(sourceURL.deletingPathExtension().lastPathComponent)"
                + "-\(Int(size.width))x\(Int(size.height))"
                + (crop == nil ? "" : "-cropped") + ".jpg")
        try data.write(to: target, options: .atomic)
        return target
    }

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "Could not read that image to resize it." }
    }
}

/// Sets the desktop picture on every Space, not just the one in front.
///
/// `NSWorkspace.setDesktopImageURL` only ever writes the current Space, which
/// is why a wallpaper set from Lumen stays behind when you swipe to another
/// desktop. macOS keeps the full picture in a store that models
/// `AllSpacesAndDisplays`, per-`Displays` and per-`Spaces` entries; this
/// rewrites the image choice in each of them and restarts the agent that owns
/// it.
///
/// That store is undocumented and its shape can change between releases, so
/// every write checks the layout first, keeps a one-time backup of the
/// original, and reports a failure the caller can fall back from rather than
/// writing a guess over it.
enum SpacesWallpaper {
    enum Failure: LocalizedError {
        case storeMissing
        case unreadable
        case unrecognisedLayout

        var errorDescription: String? {
            switch self {
            case .storeMissing:
                "This version of macOS keeps wallpapers somewhere Lumen does not know about."
            case .unreadable:
                "Could not read the system wallpaper store."
            case .unrecognisedLayout:
                "The system wallpaper store has a layout Lumen does not recognise."
            }
        }
    }

    /// One macOS Space, as the window server records it.
    struct Space: Identifiable, Hashable {
        /// The key the wallpaper store uses. The first Space has an empty one.
        let uuid: String
        /// 1-based position on its display, which is what "Desktop 2" means.
        let number: Int
        let isCurrent: Bool
        let display: String

        var id: String { "\(display)|\(uuid)|\(number)" }
        var label: String { "Desktop \(number)" }
    }

    /// The Spaces that currently exist, in order, per display.
    ///
    /// The window server keeps this in `com.apple.spaces`, and its UUIDs are
    /// the same ones the wallpaper store is keyed by — which is what makes
    /// assigning a wallpaper to one Space possible at all.
    static func spaces() -> [Space] {
        guard let config = UserDefaults.standard
            .persistentDomain(forName: "com.apple.spaces")?["SpacesDisplayConfiguration"]
            as? [String: Any],
              let management = config["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]]
        else { return [] }

        var found: [Space] = []
        for monitor in monitors {
            let display = monitor["Display Identifier"] as? String ?? "Main"
            let current = (monitor["Current Space"] as? [String: Any])?["uuid"] as? String
            let listed = monitor["Spaces"] as? [[String: Any]] ?? []

            for (index, space) in listed.enumerated() {
                // Fullscreen apps get their own Space entries; only normal
                // desktops (type 0) take a wallpaper.
                guard (space["type"] as? Int ?? 0) == 0 else { continue }
                let uuid = space["uuid"] as? String ?? ""
                found.append(Space(uuid: uuid,
                                   number: index + 1,
                                   isCurrent: uuid == current,
                                   display: display))
            }
        }
        return found
    }

    /// Points one Space at `fileURL`, leaving the others alone.
    static func apply(fileURL: URL, toSpace uuid: String) throws {
        guard isAvailable else { throw Failure.storeMissing }

        let original = try Data(contentsOf: storeURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var root = try? PropertyListSerialization.propertyList(
            from: original, options: [], format: &format) as? [String: Any],
              var spaces = root["Spaces"] as? [String: Any]
        else { throw Failure.unreadable }

        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["type": "imageFile",
                               "url": ["relative": fileURL.absoluteString]],
            format: .binary, options: 0)

        // A Space the store has not seen yet needs its entry creating.
        var entry = spaces[uuid] as? [String: Any] ?? [:]
        var slot = entry["Default"] as? [String: Any] ?? [:]
        var count = 0
        slot = rewriteDesktops(in: slot, configuration: configuration, count: &count)
        if count == 0 {
            // Nothing to rewrite means no Desktop node; make one.
            slot["Desktop"] = [
                "Content": [
                    "Choices": [[
                        "Provider": "com.apple.wallpaper.choice.image",
                        "Configuration": configuration,
                        "Files": [Any]()
                    ]],
                    "Shuffle": "$null"
                ],
                "LastSet": Date(),
                "LastUse": Date()
            ]
        }
        entry["Default"] = slot
        spaces[uuid] = entry
        root["Spaces"] = spaces

        try backUpOnce(original)
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0)
        try encoded.write(to: storeURL, options: .atomic)
        restartAgent()
    }

    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// False on a macOS that keeps wallpapers elsewhere, in which case the
    /// caller should stay with the single-Space path.
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }

    /// Points every Space and display at `fileURL`.
    static func applyEverywhere(fileURL: URL) throws {
        guard isAvailable else { throw Failure.storeMissing }

        let original = try Data(contentsOf: storeURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let root = try? PropertyListSerialization.propertyList(
            from: original, options: [], format: &format) as? [String: Any] else {
            throw Failure.unreadable
        }

        // Each choice holds its own nested binary plist.
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["type": "imageFile",
                               "url": ["relative": fileURL.absoluteString]],
            format: .binary, options: 0)

        var rewritten = 0
        let updated = rewriteDesktops(in: root, configuration: configuration, count: &rewritten)
        // Nothing matched means the layout moved. Do not write a guess over it.
        guard rewritten > 0 else { throw Failure.unrecognisedLayout }

        try backUpOnce(original)
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: updated, format: .binary, options: 0)
        try encoded.write(to: storeURL, options: .atomic)
        restartAgent()
    }

    /// Replaces the image choice under every `Desktop` node, wherever it sits.
    /// Walking rather than addressing fixed paths survives Apple adding a
    /// level, and leaves screen-saver and idle entries alone.
    private static func rewriteDesktops(in node: [String: Any],
                                        configuration: Data,
                                        count: inout Int) -> [String: Any] {
        var node = node
        for (key, value) in node {
            guard let child = value as? [String: Any] else { continue }

            if key == "Desktop", var content = child["Content"] as? [String: Any] {
                var desktop = child
                content["Choices"] = [[
                    "Provider": "com.apple.wallpaper.choice.image",
                    "Configuration": configuration,
                    "Files": [Any]()
                ]]
                desktop["Content"] = content
                desktop["LastSet"] = Date()
                desktop["LastUse"] = Date()
                node[key] = desktop
                count += 1
            } else {
                node[key] = rewriteDesktops(in: child, configuration: configuration, count: &count)
            }
        }
        return node
    }

    /// Keeps the pre-Lumen store, once, so the original stays recoverable.
    private static func backUpOnce(_ data: Data) throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appending(path: "cc.lumen.Lumen")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appending(path: "WallpaperStore.backup.plist")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try data.write(to: backup, options: .atomic)
    }

    /// The agent caches the store in memory; launchd brings it straight back.
    private static func restartAgent() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        try? process.run()
        process.waitUntilExit()
    }
}
