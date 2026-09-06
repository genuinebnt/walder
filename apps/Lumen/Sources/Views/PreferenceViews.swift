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
                    Spacer()
                    if let current = store.current {
                        Text("Current: wallhaven-\(current.id)").font(.captionMono).foregroundStyle(.secondary)
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
