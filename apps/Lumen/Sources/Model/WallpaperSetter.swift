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
