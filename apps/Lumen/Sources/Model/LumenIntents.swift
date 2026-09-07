import AppIntents
import AppKit

/// Shortcuts actions.
///
/// App Intents declared in the main binary are discovered without a separate
/// extension, which matters here: the bundle is assembled by hand with swiftc
/// and has no target that could host one.
///
/// The intents drive the app through a notification rather than touching the
/// store directly — an intent can be invoked while the app is not running, and
/// the store only exists once the UI does.
struct ShuffleWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle Wallpaper"
    static var description = IntentDescription(
        "Sets the next wallpaper from whatever source Lumen's schedule uses.")
    /// The app has to be running to change the desktop.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .lumenShuffle, object: nil)
        return .result()
    }
}

struct NextWallpaperFromFavoritesIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Random Favorite"
    static var description = IntentDescription(
        "Picks one of your favourites at random and sets it as the wallpaper.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .lumenShuffleFavorites, object: nil)
        return .result()
    }
}

struct UndoWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "Undo Last Wallpaper"
    static var description = IntentDescription(
        "Puts back whatever was on the desktop before the current one.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .lumenUndo, object: nil)
        return .result()
    }
}

/// Groups the actions in Shortcuts, and gives them spoken phrases.
struct LumenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShuffleWallpaperIntent(),
                    phrases: ["Shuffle my wallpaper in \(.applicationName)"],
                    shortTitle: "Shuffle Wallpaper",
                    systemImageName: "shuffle")
        AppShortcut(intent: NextWallpaperFromFavoritesIntent(),
                    phrases: ["Set a random favourite in \(.applicationName)"],
                    shortTitle: "Random Favorite",
                    systemImageName: "heart")
        AppShortcut(intent: UndoWallpaperIntent(),
                    phrases: ["Undo my wallpaper in \(.applicationName)"],
                    shortTitle: "Undo Wallpaper",
                    systemImageName: "arrow.uturn.backward")
    }
}
