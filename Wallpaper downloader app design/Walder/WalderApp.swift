import SwiftUI

@main
struct WalderApp: App {
    @State private var store = Store()

    var body: some Scene {
        Window("Walder", id: "main") {
            RootView()
                .environment(store)
                .preferredColorScheme(store.appearance.colorScheme)
                .frame(minWidth: 880, minHeight: 560)
                .task { await store.search() }
        }
        .windowStyle(.hiddenTitleBar)          // sidebar owns the traffic-light area
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands { WalderCommands() }

        // Quick-set popover in the menu bar.
        MenuBarExtra("Walder", systemImage: "photo.on.rectangle.angled") {
            QuickSetView()
                .environment(store)
                .preferredColorScheme(store.appearance.colorScheme)
        }
        .menuBarExtraStyle(.window)
    }
}

struct WalderCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        CommandMenu("Wallpaper") {
            Button("Shuffle Now") { NotificationCenter.default.post(name: .walderShuffle, object: nil) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Reload Results") { NotificationCenter.default.post(name: .walderReload, object: nil) }
                .keyboardShortcut("r")
        }
    }
}

extension Notification.Name {
    static let walderShuffle = Notification.Name("walder.shuffle")
    static let walderReload = Notification.Name("walder.reload")
}
