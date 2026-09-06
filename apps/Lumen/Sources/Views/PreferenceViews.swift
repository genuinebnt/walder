import SwiftUI

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
                    ForEach(["Favorites", "Collection", "Downloads"], id: \.self) { Text($0).tag($0) }
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
