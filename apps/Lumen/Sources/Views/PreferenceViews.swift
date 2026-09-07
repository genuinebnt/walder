import SwiftUI
import UniformTypeIdentifiers

struct ScheduleView: View {
    @Environment(Store.self) private var store

    var body: some View {
        Form {
            SwiftUI.Section("Rotation") {
                Toggle("Change wallpaper automatically", isOn: Binding(
                    get: { store.rotationEnabled }, set: { store.rotationEnabled = $0 }))
                Picker("Interval", selection: Binding(
                    get: { store.rotationMinutes }, set: { store.rotationMinutes = $0 })) {
                    Text("15 minutes").tag(15)
                    Text("Hourly").tag(60)
                    Text("Every 6 hours").tag(360)
                    Text("Daily").tag(1440)
                }
                Picker("Source", selection: Binding(
                    get: { store.rotationSource }, set: { store.rotationSource = $0 })) {
                    ForEach(store.rotationSources, id: \.self) { source in
                        Text(label(for: source)).tag(source)
                    }
                }

                // A saved filter is a live search, so how deep to draw from is
                // part of the schedule: "top 100 of this, pick one".
                if case .savedFilter = store.rotationSource {
                    Picker("Draw from the top", selection: Binding(
                        get: { store.rotationPoolSize },
                        set: { store.rotationPoolSize = $0 })) {
                        Text("24 results").tag(24)
                        Text("50 results").tag(50)
                        Text("100 results").tag(100)
                        Text("250 results").tag(250)
                        Text("500 results").tag(500)
                    }
                    .help("Keeps the filter's own sorting, so this is the top N "
                          + "of that search rather than anything at random")
                }
                Toggle("Shuffle wallpapers", isOn: Binding(
                    get: { store.shuffle }, set: { store.shuffle = $0 }))
                Toggle("Pause while on battery", isOn: Binding(
                    get: { store.pauseOnBattery }, set: { store.pauseOnBattery = $0 }))
            }

            SwiftUI.Section {
                HStack {
                    Button("Shuffle Now") { store.shuffleNow() }
                        .buttonStyle(.borderedProminent)
                    Button("Undo Last Set") { store.undoWallpaper() }
                        .disabled(!store.canUndoWallpaper)
                    Spacer()
                    if let current = store.current {
                        Text("Current: wallhaven-\(current.id)").font(.captionMono).foregroundStyle(.secondary)
                    }
                }
            }

            SwiftUI.Section("Tag Radar") {
                Toggle("Watch saved searches in the background", isOn: Binding(
                    get: { store.radarEnabled }, set: { store.radarEnabled = $0 }))
                Picker("Check every", selection: Binding(
                    get: { store.radarMinutes }, set: { store.radarMinutes = $0 })) {
                    Text("30 minutes").tag(30)
                    Text("Hourly").tag(60)
                    Text("Every 3 hours").tag(180)
                    Text("Daily").tag(1440)
                }
                .disabled(!store.radarEnabled)

                if store.subscriptions.isEmpty {
                    Text("Nothing watched yet. Open a tag or uploader and choose Watch.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    ForEach(store.subscriptions) { subscription in
                        HStack(spacing: Tokens.s3) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(subscription.label).font(.system(size: 12)).lineLimit(1)
                                Text(subscription.minFavorites > 0
                                     ? "\(subscription.query) · at least \(subscription.minFavorites) favourites"
                                     : subscription.query)
                                    .font(.caption2Mono).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if subscription.unseen > 0 {
                                Chip(text: "\(subscription.unseen) new", tint: Tokens.accent)
                            }
                            Button("Open") { store.openSubscription(subscription) }
                                .controlSize(.small)
                            Button {
                                store.unsubscribe(subscription)
                            } label: {
                                Image(systemName: "trash").font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button("Check Now") { Task { await store.checkRadar() } }
                            .controlSize(.small)
                            .disabled(store.isCheckingRadar)
                        if store.isCheckingRadar { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                }
            }

            SwiftUI.Section("Recently Set") {
                if store.history.isEmpty {
                    Text("Nothing yet. Wallpapers you set are listed here.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    ForEach(store.history.prefix(12)) { entry in
                        HStack(spacing: Tokens.s3) {
                            CachedImage(url: entry.url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(.quaternary)
                            }
                            .frame(width: 64, height: 40)
                            .clipShape(.rect(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.label).font(.system(size: 12)).lineLimit(1)
                                Text(entry.when)
                                    .font(.caption2Mono).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Set Again") { store.restore(entry) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// What each rotation source is called. Kept here rather than in the store
    /// so every word the user reads lives with the rest of the UI text.
    private func label(for source: RotationSource) -> String {
        switch source {
        case .favorites: "Favorites"
        case .downloads: "Downloads"
        case .collection: "Collection · \(store.name(of: source))"
        case .folder: "Folder · \(store.name(of: source))"
        case .savedFilter: "Filter · \(store.name(of: source))"
        }
    }

}

struct SettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        Form {
            SwiftUI.Section("Wallhaven") {
                SecureField("API key", text: Binding(get: { store.apiKey }, set: { store.apiKey = $0 }))
                    .help("Required for NSFW results and a higher rate limit.")
                LabeledContent("Download directory") {
                    HStack {
                        Text(store.downloadDirectory.isEmpty ? "~/Pictures/Lumen" : store.downloadDirectory)
                            .font(.captionMono).lineLimit(1).truncationMode(.head)
                        Button("Choose…") { chooseDirectory() }
                            .controlSize(.small)
                    }
                }
                Stepper("Max parallel downloads: \(store.maxParallel)",
                        value: Binding(get: { store.maxParallel }, set: { store.maxParallel = $0 }),
                        in: 1...12)

                Picker("Save downloads to", selection: Binding(
                    get: { store.downloadDestination },
                    set: { store.downloadDestination = $0 })) {
                    Text("Download folder").tag(Store.DownloadDestination.downloadFolder)
                    if !store.libraryFolders.isEmpty {
                        SwiftUI.Section("Imported folders") {
                            ForEach(store.libraryFolders) { folder in
                                Text(folder.name)
                                    .tag(Store.DownloadDestination.importedFolder(id: folder.id))
                            }
                        }
                    }
                    if !store.collections.isEmpty {
                        SwiftUI.Section("Collections") {
                            ForEach(store.collections) { collection in
                                Text(collection.name)
                                    .tag(Store.DownloadDestination.collection(id: collection.id))
                            }
                        }
                    }
                }
                .help("An imported folder is a real directory, so the file lands there. "
                      + "A collection is a grouping, so the file goes to the download "
                      + "folder and is filed into it.")

                Toggle("Skip wallpapers already in your library", isOn: Binding(
                    get: { store.skipDuplicateDownloads },
                    set: { store.skipDuplicateDownloads = $0 }))
                    .help("Compares what you are about to download against the library "
                          + "by look, not by name — so the same picture at another "
                          + "resolution is caught too.")
            }

            SwiftUI.Section("Appearance") {
                Picker("Theme", selection: Binding(get: { store.appearance }, set: { store.appearance = $0 })) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Grid", selection: Binding(get: { store.gridTheme }, set: { store.gridTheme = $0 })) {
                    ForEach(GridTheme.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show purity borders", isOn: Binding(
                    get: { store.showPurityBorders }, set: { store.showPurityBorders = $0 }))
                    .help("Red border for NSFW, amber for sketchy.")
                Toggle("Hide results below my display", isOn: Binding(
                    get: { store.hideBelowDisplay }, set: { store.hideBelowDisplay = $0 }))
                    .help("Hides anything that would have to be upscaled. Filtered "
                          + "here rather than in the query, since Wallhaven's own "
                          + "minimum also excludes differently shaped wallpapers.")
            }

            SwiftUI.Section("Behaviour") {
                Toggle("Prefer downloaded file in preview", isOn: Binding(
                    get: { store.preferLocalPreview }, set: { store.preferLocalPreview = $0 }))
                if SpacesWallpaper.isAvailable {
                    Picker("Apply wallpaper to", selection: Binding(
                        get: { store.wallpaperScope }, set: { store.wallpaperScope = $0 })) {
                        ForEach(WallpaperScope.allCases) { Text($0.label).tag($0) }
                    }
                    .help("Each Space keeps its own desktop picture. All Spaces writes them all.")
                }
            }

            SwiftUI.Section("Backup") {
                LabeledContent("Favorites, collections, filters and watches") {
                    HStack(spacing: Tokens.s2) {
                        Button("Export…") { exportBackup() }
                        Button("Import…") { importBackup() }
                    }
                    .controlSize(.small)
                }
                .help("A JSON file carrying the records themselves, so a restore "
                      + "works on a fresh install with an empty cache.")
            }

            SwiftUI.Section {
                HStack(spacing: Tokens.s3) {
                    Button("Save Preferences") { store.savePreferences() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    Text("Saved to local store")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.success)
                        .opacity(store.savedConfirmation ? 1 : 0)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lumen backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportBackup(to: url)
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importBackup(from: url)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.downloadDirectory = url.path(percentEncoded: false)
        }
    }
}
