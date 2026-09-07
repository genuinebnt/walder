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
                    ContentUnavailableView {
                        Label("No downloads in progress", systemImage: "arrow.down.circle")
                    } description: {
                        // This pane is transfers, which do not outlive the app.
                        // Everything already on disk lives in Folders.
                        Text("This list shows transfers. Wallpapers you have already "
                             + "downloaded are in Folders, under Lumen downloads.")
                    } actions: {
                        Button("Open Folders") {
                            NotificationCenter.default.post(name: .lumenShowFolders, object: nil)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.s6)
                }
            }
            .padding(Tokens.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// Order and direction for lists of Wallhaven wallpapers.
///
/// Shared between collections and downloads so the two panes behave the same;
/// the direction is its own button because "most favourited" and "least" are
/// both reasonable things to want.
struct RemoteSortControls: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(Store.RemoteSort.allCases) { option in
                    Button {
                        store.remoteSort = option
                    } label: {
                        Label(option.label, systemImage: option.symbol)
                    }
                }
            } label: {
                Label(store.remoteSort.label, systemImage: store.remoteSort.symbol)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                store.remoteSortAscending.toggle()
            } label: {
                Image(systemName: store.remoteSortAscending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(store.remoteSortAscending ? "Ascending" : "Descending")
        }
    }
}

struct CollectionsView: View {
    @Environment(Store.self) private var store
    @State private var name = ""
    /// nil shows the collections; a value shows one collection's wallpapers.
    @State private var opened: Collection?
    @State private var hovered: String?

    private var theme: GridTheme { store.gridTheme }

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

                if let opened, let live = store.collections.first(where: { $0.id == opened.id }) {
                    // Inside a collection: the same grid and layouts the rest
                    // of the app uses, rather than a card that only shuffles.
                    contents(of: live)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: Tokens.s4)],
                              spacing: Tokens.s4) {
                        ForEach(store.collections) { collection in
                            card(collection)
                                .onTapGesture { withAnimation(Tokens.quick) { self.opened = collection } }
                        }
                    }
                }

                if store.collections.isEmpty {
                    ContentUnavailableView("No collections",
                                           systemImage: "rectangle.stack",
                                           description: Text("Create one to group downloads and shuffle them on a schedule."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Tokens.s6)
                }
            }
            .padding(Tokens.s4)
            .animation(Tokens.normal, value: store.collections.map(\.id))
        }
        .scrollContentBackground(.hidden)
    }

    /// One collection's wallpapers, with the layout picker and a way back.
    private func contents(of collection: Collection) -> some View {
        VStack(alignment: .leading, spacing: Tokens.s3) {
            HStack(spacing: Tokens.s3) {
                Button {
                    withAnimation(Tokens.quick) { opened = nil }
                } label: {
                    Label("Collections", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                Text(collection.name).font(.system(size: 15, weight: .semibold))
                Text("\(shown(collection).count) of \(collection.wallpapers.count)")
                    .font(.caption2Mono).foregroundStyle(.secondary)
                Spacer()

                TextField("Filter", text: Binding(get: { store.remoteSearch },
                                                  set: { store.remoteSearch = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                RemoteSortControls()

                Picker("", selection: Binding(get: { store.gridTheme },
                                              set: { store.gridTheme = $0 })) {
                    ForEach(GridTheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
            }

            if collection.wallpapers.isEmpty {
                ContentUnavailableView("Nothing in here yet",
                                       systemImage: "rectangle.stack",
                                       description: Text("Add wallpapers from a preview."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.s6)
            } else if shown(collection).isEmpty {
                ContentUnavailableView("Nothing matches",
                                       systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Try a different filter."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.s6)
            } else {
                Group {
                    if theme == .natural {
                JustifiedGrid(items: shown(collection),
                              aspect: { $0.ratio > 0 ? $0.ratio : 16.0 / 10 },
                              targetRowHeight: theme.minTileWidth,
                              spacing: theme.spacing) { tile($0, in: collection) }
            } else if theme == .masonry {
                        MasonryGrid(items: shown(collection),
                                    aspect: { $0.ratio > 0 ? $0.ratio : 16.0 / 10 },
                                    columnWidth: theme.minTileWidth,
                                    spacing: theme.spacing) { tile($0, in: collection) }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: theme.minTileWidth),
                                                     spacing: theme.spacing)],
                                  spacing: theme.spacing) {
                            ForEach(shown(collection)) { tile($0, in: collection) }
                        }
                    }
                }
                .transaction { $0.animation = nil }
            }
        }
    }

    /// What the grid shows: the collection through the sort and filter.
    private func shown(_ collection: Collection) -> [Wallpaper] {
        store.arranged(collection.wallpapers)
    }

    private func tile(_ wallpaper: Wallpaper, in collection: Collection) -> some View {
        WallpaperTile(wallpaper: wallpaper,
                      theme: theme,
                      isHovered: hovered == wallpaper.id,
                      isFavorite: store.isFavorite(wallpaper),
                      isSelecting: store.isSelecting,
                      isSelected: store.isSelected(wallpaper),
                      isDownloaded: store.isDownloaded(wallpaper),
                      open: {
                          if store.isSelecting {
                              store.toggleSelection(wallpaper)
                              return
                          }
                          store.openCollectionPreview(wallpaper, in: collection)
                      })
            .onHover { inside in
                withAnimation(Tokens.quick) {
                    hovered = inside ? wallpaper.id : (hovered == wallpaper.id ? nil : hovered)
                }
            }
            .contextMenu {
                Button("Set as Wallpaper") { store.setWallpaper(wallpaper) }
                Button("Download") { store.download(wallpaper) }
                Divider()
                Button("Remove from \(collection.name)", role: .destructive) {
                    store.setMembership(wallpaper, of: collection, member: false)
                }
            }
    }

    private func card(_ collection: Collection) -> some View {
        let items = collection.wallpapers
        return VStack(spacing: 0) {
            Group {
                if items.isEmpty {
                    Rectangle().fill(.quaternary.opacity(0.5))
                        .overlay {
                            Text("Empty — add wallpapers from the preview")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(Tokens.s3)
                        }
                } else {
                    HStack(spacing: 2) {
                        thumb(items.first)
                        VStack(spacing: 2) {
                            thumb(items.dropFirst().first)
                            thumb(items.dropFirst(2).first)
                        }
                        .frame(width: 74)
                    }
                }
            }
            .frame(height: 128)
            .clipped()

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(collection.name).font(.rowTitle.weight(.medium)).lineLimit(1)
                    Text("\(items.count) wallpapers").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Shuffle") {
                    if let pick = items.randomElement() { store.setWallpaper(pick) }
                }
                .controlSize(.small)
                .disabled(items.isEmpty)
            }
            .padding(Tokens.s3)
        }
        .card()
        .contentShape(.rect)
        .contextMenu {
            Button("Shuffle") {
                if let pick = items.randomElement() { store.setWallpaper(pick) }
            }
            .disabled(items.isEmpty)
            Divider()
            Button("Delete Collection", role: .destructive) { store.deleteCollection(collection) }
        }
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
            VStack(alignment: .leading, spacing: Tokens.s4) {
                if !store.spaces.isEmpty { spacesSection }
                displayGrid
            }
            .padding(Tokens.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            store.displays = mergeLiveDisplays()
            store.reloadSpaces()
        }
    }

    /// Each Space, and a way to give it its own wallpaper.
    ///
    /// macOS keeps a separate desktop picture per Space and offers no API for
    /// it; the window server's own record names them, and the wallpaper store
    /// is keyed by the same ids.
    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            HStack {
                Text("SPACES").font(.sectionLabel).foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.reloadSpaces()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text("Each Space keeps its own wallpaper. Assign the one showing now "
                 + "to any of them.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)

            // Shown as thumbnails of what each Space is actually displaying:
            // "Desktop 3" means nothing on its own, but the picture is
            // recognisable at a glance.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Tokens.s3)],
                      spacing: Tokens.s3) {
                ForEach(store.spaces) { space in
                    Button {
                        if let current = store.current {
                            store.setWallpaper(current, onSpace: space)
                        }
                    } label: {
                        spaceCard(space)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.current == nil)
                    .help(store.current == nil
                          ? "Set a wallpaper first, then assign it to a Space"
                          : "Put the current wallpaper on \(space.label)")
                }
            }
        }
        .padding(Tokens.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// One Space, shown as its own wallpaper.
    ///
    /// A separate function because the type-checker could not handle it inline
    /// inside the grid's button label.
    private func spaceCard(_ space: SpacesWallpaper.Space) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            spaceThumbnail(space)
                .frame(height: 76)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.control)
                        .strokeBorder(space.isCurrent ? Tokens.accent : Color.clear,
                                      lineWidth: 2)
                }

            HStack(spacing: 5) {
                Text(space.label).font(.system(size: 12, weight: .medium))
                if space.isCurrent {
                    Text("current").font(.caption2Mono).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private func spaceThumbnail(_ space: SpacesWallpaper.Space) -> some View {
        if let url = store.wallpaper(onSpace: space) {
            CachedImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary.opacity(0.4))
            } failure: {
                // A wallpaper Lumen cannot read — a dynamic one, or a file
                // that has moved since it was set.
                ZStack {
                    Rectangle().fill(.quaternary.opacity(0.4))
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        } else {
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.4))
                Image(systemName: "questionmark").foregroundStyle(.tertiary)
            }
        }
    }

    private var displayGrid: some View {
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
