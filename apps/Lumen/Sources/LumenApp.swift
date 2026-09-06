import SwiftUI
import AppKit

@main
struct LumenApp: App {
    @State private var store = Store()

    var body: some Scene {
        Window("Lumen", id: "main") {
            RootView()
                .environment(store)
                .preferredColorScheme(store.appearance.colorScheme)
                .frame(minWidth: 880, minHeight: 560)
                .task {
                    store.boot()
                    await store.search()
                }
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
        CommandMenu("Wallpaper") {
            Button("Shuffle Now") { NotificationCenter.default.post(name: .lumenShuffle, object: nil) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Reload Results") { NotificationCenter.default.post(name: .lumenReload, object: nil) }
                .keyboardShortcut("r")
        }
    }
}

extension Notification.Name {
    static let lumenShuffle = Notification.Name("lumen.shuffle")
    static let lumenReload = Notification.Name("lumen.reload")
}
