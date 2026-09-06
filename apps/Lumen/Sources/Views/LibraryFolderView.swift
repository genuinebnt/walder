import SwiftUI
import AppKit

/// Wallpapers already on disk: Lumen's own downloads, or any folder the user
/// points it at.
///
/// These have no Wallhaven identity — no tags, no uploader, no id — so they get
/// their own grid rather than being forced through `Wallpaper`. What they do
/// support is what matters here: look at them, favourite them, set them.
struct LibraryFolderView: View {
    @Environment(Store.self) private var store

    @State private var hovered: String?
    @State private var previewing: LocalWallpaper?

    private var items: [LocalWallpaper] { store.libraryWallpapers }
    private var theme: GridTheme { store.gridTheme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s4) {
                folders
                if items.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .padding(Tokens.s4)
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $previewing) { wallpaper in
            LocalPreview(wallpaper: wallpaper) { previewing = nil }
                .environment(store)
        }
    }

    // MARK: Folders

    private var folders: some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            HStack(spacing: Tokens.s2) {
                Button {
                    chooseFolder()
                } label: {
                    Label("Import Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await store.rescanLibrary() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(store.libraryFolders.isEmpty || store.isScanningLibrary)

                Toggle("Favourites only", isOn: Binding(
                    get: { store.libraryFavoritesOnly },
                    set: { store.setLibraryFavoritesOnly($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11.5))

                if store.isScanningLibrary {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("\(items.count) wallpapers")
                    .font(.caption2Mono).foregroundStyle(.secondary)
            }
            .controlSize(.small)

            if !store.libraryFolders.isEmpty {
                FlowLayout(spacing: 6) {
                    chip(title: "All folders", isOn: store.selectedFolder == nil) {
                        store.selectFolder(nil)
                    }
                    ForEach(store.libraryFolders) { folder in
                        chip(title: "\(folder.name) · \(folder.count)",
                             isOn: store.selectedFolder == folder.id) {
                            store.selectFolder(folder.id)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([folder.url])
                            }
                            Divider()
                            // Only the index goes; the files are left alone.
                            Button("Forget This Folder", role: .destructive) {
                                store.forgetFolder(folder)
                            }
                        }
                    }
                }
            }
        }
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(isOn ? Tokens.accent : .secondary)
                .background(isOn ? Tokens.accent.opacity(0.18) : Color.secondary.opacity(0.12),
                            in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        let chosen = panel.urls
        Task {
            for url in chosen {
                await store.importFolder(at: url.path(percentEncoded: false))
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: theme.minTileWidth),
                                     spacing: theme.spacing)],
                  spacing: theme.spacing) {
            ForEach(items) { tile($0) }
        }
    }

    private func tile(_ wallpaper: LocalWallpaper) -> some View {
        CachedImage(url: wallpaper.url) { image in
            image.resizable().scaledToFill()
                .scaleEffect(hovered == wallpaper.id ? 1.05 : 1)
        } placeholder: {
            Rectangle().fill(.quaternary).shimmer()
        } failure: {
            Rectangle().fill(.quaternary)
                .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
        }
        .aspectRatio(16.0 / 10, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay { hoverLayer(wallpaper) }
        .clipShape(.rect(cornerRadius: theme.cornerRadius))
        .compositingGroup()
        .shadow(color: .black.opacity(hovered == wallpaper.id ? 0.4 : 0.16),
                radius: hovered == wallpaper.id ? 14 : 5, y: hovered == wallpaper.id ? 7 : 2)
        .scaleEffect(hovered == wallpaper.id ? 1.014 : 1)
        .zIndex(hovered == wallpaper.id ? 1 : 0)
        .animation(Tokens.normal, value: hovered)
        .onHover { inside in
            withAnimation(Tokens.quick) {
                hovered = inside ? wallpaper.id : (hovered == wallpaper.id ? nil : hovered)
            }
        }
        .contentShape(.rect)
        .onTapGesture { previewing = wallpaper }
        .onDrag { NSItemProvider(contentsOf: wallpaper.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Set as Wallpaper") { store.setLocalWallpaper(wallpaper) }
            Button(wallpaper.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
                store.toggleLibraryFavorite(wallpaper)
            }
            Divider()
            ForEach(store.displays) { display in
                Button("Set on \(display.name)") {
                    store.setLocalWallpaper(wallpaper, on: display)
                }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([wallpaper.url])
            }
        }
    }

    private func hoverLayer(_ wallpaper: LocalWallpaper) -> some View {
        let isHovered = hovered == wallpaper.id
        return ZStack {
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack {
                HStack(alignment: .top) {
                    Text(wallpaper.displayResolution)
                        .font(.caption2Mono)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: .rect(cornerRadius: 6))
                    Spacer()
                    Button { store.toggleLibraryFavorite(wallpaper) } label: {
                        Image(systemName: wallpaper.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 25, height: 25)
                            .background(.black.opacity(0.45), in: .circle)
                            .foregroundStyle(wallpaper.isFavorite ? Tokens.brand : .white)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: Tokens.s2) {
                    Button("Set") { store.setLocalWallpaper(wallpaper) }
                        .buttonStyle(TileButton(prominent: true))
                    Spacer()
                    Text(wallpaper.filename)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(Tokens.s3)
            .foregroundStyle(.white)
        }
        .opacity(isHovered ? 1 : 0)
        .animation(Tokens.quick, value: isHovered)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(store.libraryFolders.isEmpty ? "No folders imported" : "Nothing here",
                  systemImage: "folder")
        } description: {
            Text(store.libraryFolders.isEmpty
                 ? "Import a folder of wallpapers — Lumen's downloads, or any folder you already keep them in."
                 : store.libraryFavoritesOnly
                   ? "Nothing in this folder is a favourite yet."
                   : "That folder has no images in it.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.s6)
    }
}

/// Full-size look at a local file, with the same actions the grid offers.
struct LocalPreview: View {
    @Environment(Store.self) private var store
    let wallpaper: LocalWallpaper
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CachedImage(url: wallpaper.url, maxPixels: ImageDetail.preview) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView().controlSize(.large)
            } failure: {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)

            HStack(spacing: Tokens.s3) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(wallpaper.filename).font(.rowTitle.weight(.medium)).lineLimit(1)
                    Text("\(wallpaper.displayResolution) · \(wallpaper.sizeMB)")
                        .font(.caption2Mono).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.toggleLibraryFavorite(wallpaper)
                } label: {
                    Label(wallpaper.isFavorite ? "Saved" : "Favourite",
                          systemImage: wallpaper.isFavorite ? "heart.fill" : "heart")
                }
                Button {
                    store.setLocalWallpaper(wallpaper)
                    close()
                } label: {
                    Label("Set as Wallpaper", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Tokens.s3)
            .background(.bar)
        }
        .frame(minWidth: 820, idealWidth: 1080, minHeight: 520, idealHeight: 700)
    }
}
