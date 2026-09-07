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

    private var items: [LocalWallpaper] { store.libraryWallpapers }
    private var theme: GridTheme { store.gridTheme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s4) {
                folders

                if !store.duplicateGroups.isEmpty {
                    duplicates
                } else if !store.similarToSelection.isEmpty {
                    similar
                } else if items.isEmpty {
                    emptyState
                } else {
                    // A file browser rather than one flat list: subfolders
                    // first, then the images at this level.
                    breadcrumb
                    if !store.currentSubfolders.isEmpty { subfolders }
                    if store.currentFiles.isEmpty && !store.currentSubfolders.isEmpty {
                        Text("No images directly in this folder.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    } else {
                        grid
                    }
                }
            }
            .padding(Tokens.s4)
        }
        .scrollContentBackground(.hidden)
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

                Button {
                    Task { await store.findDuplicates() }
                } label: {
                    Label("Find Duplicates", systemImage: "square.on.square")
                }
                .disabled(store.libraryWallpapers.isEmpty || store.isIndexingPrints)
                .help("Finds the same picture at another resolution or re-encoded, "
                      + "which a file comparison would miss")

                if !store.duplicateGroups.isEmpty || !store.similarToSelection.isEmpty {
                    Button("Clear") { store.clearSimilarity() }
                }

                layoutPicker

                if store.isScanningLibrary || store.isIndexingPrints {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if store.indexProgress.total > 0 {
                    Text("indexing \(store.indexProgress.done) of \(store.indexProgress.total)")
                        .font(.caption2Mono).foregroundStyle(.secondary)
                }
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

    // MARK: Browsing

    /// Where you are inside the imported folder, and the way back up.
    @ViewBuilder
    private var breadcrumb: some View {
        if !store.libraryFolders.isEmpty {
            HStack(spacing: 4) {
                Button {
                    store.selectFolder(nil)
                } label: {
                    Label("All folders", systemImage: "folder")
                        .font(.system(size: 12, weight: store.browsePath.isEmpty ? .medium : .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.selectedFolder == nil ? .primary : Color.accentColor)

                if store.selectedFolder != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Button {
                        store.browse(to: "")
                    } label: {
                        Text(rootName)
                            .font(.system(size: 12,
                                          weight: store.browsePath.isEmpty ? .medium : .regular))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(store.browsePath.isEmpty ? .primary : Color.accentColor)
                }

                ForEach(store.breadcrumb, id: \.path) { crumb in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Button {
                        store.browse(to: crumb.path)
                    } label: {
                        Text(crumb.name)
                            .font(.system(size: 12,
                                          weight: crumb.path == store.browsePath ? .medium : .regular))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(crumb.path == store.browsePath ? .primary : Color.accentColor)
                }
                Spacer()
            }
        }
    }

    private var rootName: String {
        store.libraryFolders.first { $0.id == store.selectedFolder }?.name ?? "All folders"
    }

    private var subfolders: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Tokens.s3)],
                  spacing: Tokens.s3) {
            ForEach(store.currentSubfolders, id: \.path) { folder in
                Button {
                    store.browse(to: folder.path)
                } label: {
                    HStack(spacing: Tokens.s2) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Tokens.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.name).font(.system(size: 12.5)).lineLimit(1)
                            Text("\(folder.count) wallpapers")
                                .font(.caption2Mono).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(Tokens.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Similarity

    /// Groups of files that look like the same picture.
    private var duplicates: some View {
        VStack(alignment: .leading, spacing: Tokens.s4) {
            Text("\(store.duplicateGroups.count) SETS OF DUPLICATES")
                .font(.sectionLabel).foregroundStyle(.secondary)
            ForEach(Array(store.duplicateGroups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: Tokens.s2) {
                    Text("\(group.count) copies · keep the largest and delete the rest in Finder")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Tokens.s3)],
                              spacing: Tokens.s3) {
                        ForEach(group) { tile($0) }
                    }
                }
                .padding(Tokens.s3)
                .card()
            }
        }
    }

    private var similar: some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            Text("SIMILAR IN YOUR LIBRARY").font(.sectionLabel).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: theme.minTileWidth),
                                         spacing: theme.spacing)],
                      spacing: theme.spacing) {
                ForEach(store.similarToSelection) { tile($0) }
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        // Only what is at this level; subfolders are their own tiles above.
        let shown = store.currentFiles
        return Group {
            if theme == .masonry {
                // Masonry keeps each image's real shape, which is the layout
                // that never crops.
                MasonryLayout(columnWidth: theme.minTileWidth, spacing: theme.spacing) {
                    ForEach(shown) { tile($0) }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: theme.minTileWidth),
                                             spacing: theme.spacing)],
                          spacing: theme.spacing) {
                    ForEach(shown) { tile($0) }
                }
            }
        }
        .transaction { $0.animation = nil }
        .task(id: shown.map(\.id)) { await store.loadAspectRatios(for: shown) }
    }

    /// The layout picker, matching the one the Wallhaven grid has.
    private var layoutPicker: some View {
        Picker("", selection: Binding(get: { store.gridTheme },
                                      set: { store.gridTheme = $0 })) {
            ForEach(GridTheme.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
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
        .aspectRatio(tileAspect(for: wallpaper), contentMode: .fill)
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
        .onTapGesture { withAnimation(Tokens.normal) { store.localPreview = wallpaper } }
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
            Button("Find Similar in Library") {
                Task { await store.findSimilarInLibrary(to: wallpaper) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([wallpaper.url])
            }
        }
    }

    /// Masonry uses the image's real shape; the fixed layouts use their own,
    /// which is what crops a portrait wallpaper into a strip of its middle.
    private func tileAspect(for wallpaper: LocalWallpaper) -> Double {
        switch theme {
        case .masonry: store.aspectRatio(of: wallpaper)
        case .cinema: 16.0 / 9
        default: 16.0 / 10
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

/// Full-size look at a local file, laid out like the Wallhaven preview: image
/// on the left, everything you can do with it on the right.
struct LocalPreview: View {
    @Environment(Store.self) private var store
    let wallpaper: LocalWallpaper
    var close: () -> Void

    @State private var zoomed = false

    var body: some View {
        HStack(spacing: 0) {
            preview
            Divider()
            inspector
        }
        .frame(minWidth: 880, idealWidth: 1180, minHeight: 540, idealHeight: 720)
        .background(.regularMaterial)
    }

    private var preview: some View {
        ZStack {
            Color.black
            CachedImage(url: wallpaper.url, maxPixels: ImageDetail.preview) { image in
                image.resizable().aspectRatio(contentMode: zoomed ? .fill : .fit)
            } placeholder: {
                ProgressView().controlSize(.large)
            } failure: {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            VStack {
                HStack {
                    Button(action: close) {
                        Label("Back", systemImage: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Text(wallpaper.displayResolution)
                        .font(.captionMono)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: .rect(cornerRadius: 7))
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(Tokens.s3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(.rect)
        .onTapGesture { withAnimation(Tokens.normal) { zoomed.toggle() } }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(wallpaper.filename)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Text(wallpaper.subpath.isEmpty ? "Top level" : wallpaper.subpath)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }

                actions
                fitReport
                metadata
                displays
            }
            .padding(Tokens.s4)
        }
        .frame(width: 316)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var actions: some View {
        VStack(spacing: Tokens.s2) {
            if SpacesWallpaper.isAvailable {
                Picker("", selection: Binding(get: { store.wallpaperScope },
                                              set: { store.wallpaperScope = $0 })) {
                    ForEach(WallpaperScope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }

            Button {
                store.setLocalWallpaper(wallpaper)
            } label: {
                Label("Set as Wallpaper", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            HStack(spacing: Tokens.s2) {
                Button {
                    store.toggleLibraryFavorite(wallpaper)
                } label: {
                    Label(wallpaper.isFavorite ? "Saved" : "Favourite",
                          systemImage: wallpaper.isFavorite ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity)
                }
                .tint(wallpaper.isFavorite ? Tokens.brand : nil)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([wallpaper.url])
                } label: {
                    Label("Reveal", systemImage: "folder").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)

            Button {
                close()
                Task { await store.findSimilarInLibrary(to: wallpaper) }
            } label: {
                Label("Find Similar in Library", systemImage: "square.on.square.dashed")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    /// Same question the Wallhaven preview answers: does this suit the screen?
    @ViewBuilder
    private var fitReport: some View {
        if let size = wallpaper.pixelSize {
            let fit = DisplayFit(image: size, display: WallpaperFitter.mainPixelSize)
            VStack(alignment: .leading, spacing: Tokens.s2) {
                Text("ON THIS DISPLAY").font(.sectionLabel).foregroundStyle(.secondary)
                HStack(spacing: Tokens.s2) {
                    Image(systemName: fit.isPerfect ? "checkmark.circle.fill"
                            : fit.isGood ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(fit.isPerfect || fit.isGood ? Tokens.success : Tokens.warning)
                    Text(fit.summary).font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Tokens.control))
            }
        }
    }

    private var metadata: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).font(.captionMono)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 11).padding(.vertical, 8)
                .rowDivider(index > 0)
            }
        }
        .card(radius: 10)
    }

    private var rows: [(String, String)] {
        [("Resolution", wallpaper.displayResolution),
         ("File", (wallpaper.url.pathExtension.uppercased()) + " · " + wallpaper.sizeMB),
         ("Folder", wallpaper.subpath.isEmpty ? "—" : wallpaper.subpath),
         ("Path", wallpaper.url.deletingLastPathComponent().path)]
    }

    private var displays: some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            Text("SEND TO DISPLAY").font(.sectionLabel).foregroundStyle(.secondary)
            ForEach(store.displays) { display in
                Button {
                    store.setLocalWallpaper(wallpaper, on: display)
                } label: {
                    HStack {
                        Text(display.name).lineLimit(1)
                        Spacer()
                        Image(systemName: "arrow.right.circle").foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Tokens.control))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
