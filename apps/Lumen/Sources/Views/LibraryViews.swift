import SwiftUI

// MARK: - Downloads

struct DownloadsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s3) {
                HStack(spacing: Tokens.s2) {
                    Button("Clear Finished") { store.clearFinished() }
                        .disabled(!store.downloads.contains { $0.state == .done })
                    Button("Retry Failed") { store.retryFailed() }
                        .disabled(!store.downloads.contains { $0.state == .failed })
                }
                .controlSize(.small)

                ForEach(store.downloads) { task in
                    row(task)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if store.downloads.isEmpty {
                    ContentUnavailableView("No downloads yet",
                                           systemImage: "arrow.down.circle",
                                           description: Text("Hover a wallpaper and choose Download."))
                        .padding(.vertical, Tokens.s6)
                }
            }
            .padding(Tokens.s4)
            .frame(maxWidth: 900, alignment: .leading)
            .animation(Tokens.normal, value: store.downloads.map(\.id))
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ task: DownloadTask) -> some View {
        let wallpaper = store.wallpaper(for: task)
        return HStack(spacing: Tokens.s3) {
            Group {
                if let wallpaper {
                    CachedImage(url: wallpaper.thumb) { $0.resizable().scaledToFill() }
                        placeholder: { Rectangle().fill(.quaternary) }
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 76, height: 47)
            .clipShape(.rect(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Tokens.s2) {
                    Text(task.filename).font(.captionMono)
                    Chip(text: task.state.rawValue, tint: tint(task.state))
                    if let wallpaper {
                        Text(wallpaper.sizeMB).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !task.speedLabel.isEmpty {
                        Text(task.speedLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .tint(tint(task.state))
                if let error = task.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(Tokens.danger).lineLimit(1)
                }
            }

            Button("Set") {
                if let wallpaper { store.setWallpaper(wallpaper) }
            }
            .disabled(task.state != .done || wallpaper == nil)
            .controlSize(.small)
        }
        .padding(Tokens.s3)
        .card()
    }

    private func tint(_ state: DownloadTask.State) -> Color {
        switch state {
        case .done: Tokens.success
        case .failed: Tokens.danger
        case .active: Tokens.accent
        case .queued, .cancelled: .secondary
        }
    }
}

// MARK: - Collections

struct CollectionsView: View {
    @Environment(Store.self) private var store
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s4) {
                HStack(spacing: Tokens.s2) {
                    TextField("New collection name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Button("Create") {
                        store.createCollection(named: name, seeding: true)
                        name = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: Tokens.s4)], spacing: Tokens.s4) {
                    ForEach(store.collections) { collection in
                        card(collection)
                    }
                }

                if store.collections.isEmpty {
                    ContentUnavailableView("No collections",
                                           systemImage: "rectangle.stack",
                                           description: Text("Create one to group downloads and shuffle them on a schedule."))
                        .padding(.vertical, Tokens.s6)
                }
            }
            .padding(Tokens.s4)
            .animation(Tokens.normal, value: store.collections.map(\.id))
        }
        .scrollContentBackground(.hidden)
    }

    private func card(_ collection: Collection) -> some View {
        let items = collection.items.isEmpty ? Array(store.wallpapers.prefix(3)) : collection.items
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                thumb(items.first)
                VStack(spacing: 2) {
                    thumb(items.dropFirst().first)
                    thumb(items.dropFirst(2).first)
                }
                .frame(width: 74)
            }
            .frame(height: 128)
            .clipped()

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(collection.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(items.count) wallpapers").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Shuffle") {
                    if let pick = items.randomElement() { store.setWallpaper(pick) }
                }
                .controlSize(.small)
            }
            .padding(Tokens.s3)
        }
        .card()
        .contentShape(.rect)
    }

    private func thumb(_ wallpaper: Wallpaper?) -> some View {
        Group {
            if let wallpaper {
                CachedImage(url: wallpaper.thumb) { $0.resizable().scaledToFill() }
                    placeholder: { Rectangle().fill(.quaternary) }
            } else {
                Rectangle().fill(.quaternary.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

// MARK: - Displays

struct DisplaysView: View {
    @Environment(Store.self) private var store

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Tokens.s4)], spacing: Tokens.s4) {
                ForEach(store.displays) { display in
                    VStack(alignment: .leading, spacing: Tokens.s3) {
                        ZStack(alignment: .top) {
                            Group {
                                if let wallpaper = display.wallpaper {
                                    CachedImage(url: wallpaper.thumb) { $0.resizable().scaledToFill() }
                                        placeholder: { Rectangle().fill(.quaternary) }
                                } else {
                                    Rectangle().fill(.quaternary.opacity(0.6))
                                        .overlay { Text("No wallpaper set").font(.captionMono).foregroundStyle(.secondary) }
                                }
                            }
                            .aspectRatio(display.aspect, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipped()

                            Rectangle().fill(.black.opacity(0.25)).frame(height: 12)   // menu bar
                        }
                        .clipShape(.rect(cornerRadius: 9))

                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(display.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(display.resolution).font(.captionMono).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Assign current") {
                                if let current = store.current { store.setWallpaper(current, on: display) }
                            }
                            .controlSize(.small)
                            .disabled(store.current == nil)
                        }

                        Picker("", selection: fit(for: display)) {
                            ForEach(DisplayTarget.Fit.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    }
                    .padding(Tokens.s3)
                    .card()
                }
            }
            .padding(Tokens.s4)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .onAppear { store.displays = mergeLiveDisplays() }
    }

    private func fit(for display: DisplayTarget) -> Binding<DisplayTarget.Fit> {
        Binding(get: { display.fit },
                set: { newValue in
                    guard let index = store.displays.firstIndex(of: display) else { return }
                    store.displays[index].fit = newValue
                })
    }

    /// Keeps assignments when a screen is unplugged and plugged back in.
    private func mergeLiveDisplays() -> [DisplayTarget] {
        WallpaperSetter.connectedDisplays().map { live in
            var merged = live
            merged.wallpaper = store.displays.first { $0.id == live.id }?.wallpaper
            merged.fit = store.displays.first { $0.id == live.id }?.fit ?? .fill
            return merged
        }
    }
}
