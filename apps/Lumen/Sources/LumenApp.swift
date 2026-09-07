import SwiftUI
import AppKit

@main
struct LumenApp: App {
    @Environment(\.colorScheme) private var colorScheme
    @State private var store = Store()

    var body: some Scene {
        Window("Lumen", id: "main") {
            RootView()
                .environment(store)
                .preferredColorScheme(store.appearance.colorScheme)
                .frame(minWidth: 880, minHeight: 560)
                .task {
                    store.boot()
                    RadarNotifier.requestPermissionIfNeeded()
                    await store.search()
                    // One check on launch, so a subscription is useful before
                    // the first timer fires.
                    await store.checkRadar()
                }
                // The desktop follows light and dark like the rest of the
                // system, when a pair has been set.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didChangeOcclusionStateNotification)) { _ in
                    store.applyPairedWallpaper()
                }
                .onChange(of: colorScheme) { _, _ in store.applyPairedWallpaper() }
        }
        .windowStyle(.hiddenTitleBar)          // sidebar owns the traffic-light area
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands { LumenCommands() }

        // Quick-set popover in the menu bar.
        MenuBarExtra("Lumen", systemImage: "photo.on.rectangle.angled",
                     isInserted: Binding(get: { store.menuBarEnabled },
                                         set: { store.menuBarEnabled = $0 })) {
            QuickSetView()
                .environment(store)
                .preferredColorScheme(store.appearance.colorScheme)
        }
        .menuBarExtraStyle(.window)
    }
}

struct LumenCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        CommandGroup(after: .sidebar) {
            Button("Back") { NotificationCenter.default.post(name: .lumenBack, object: nil) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { NotificationCenter.default.post(name: .lumenForward, object: nil) }
                .keyboardShortcut("]", modifiers: .command)
        }
        CommandMenu("Wallpaper") {
            Button("Shuffle Now") { NotificationCenter.default.post(name: .lumenShuffle, object: nil) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Reload Results") { NotificationCenter.default.post(name: .lumenReload, object: nil) }
                .keyboardShortcut("r")
            Divider()
            Button("Undo Last Set") { NotificationCenter.default.post(name: .lumenUndo, object: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let lumenShuffle = Notification.Name("lumen.shuffle")
    static let lumenReload = Notification.Name("lumen.reload")
    static let lumenUndo = Notification.Name("lumen.undo")
    static let lumenBack = Notification.Name("lumen.back")
    static let lumenForward = Notification.Name("lumen.forward")
    static let lumenShowFolders = Notification.Name("lumen.showFolders")
    static let lumenShuffleFavorites = Notification.Name("lumen.shuffleFavorites")
}
