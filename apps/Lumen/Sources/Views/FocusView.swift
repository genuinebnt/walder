import SwiftUI

/// One uploader, one tag, or one of an uploader's collections.
///
/// All three are the same shape — a header saying what you are looking at, then
/// that thing's wallpapers — so they share a pane rather than three near-copies.
/// It keeps its own results, so opening an author page does not discard the
/// search you were in the middle of.
struct FocusView: View {
    @Environment(Store.self) private var store
    @Binding var selection: Wallpaper?

    @State private var scrolledTo: String?

    private var items: [Wallpaper] { store.focusWallpapers }
    private var theme: GridTheme { store.gridTheme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s4) {
                header
                scopeControls

                if let stats = store.uploaderStats { uploaderStats(stats) }

                if case .uploader(let name) = store.focus, !store.uploaderCollections.isEmpty {
                    collections(of: name)
                }

                if case .tag = store.focus, let info = store.tagInfo {
                    tagRecord(info)
                }

                grid

                if store.isLoadingFocus { loadingRow }
                if items.isEmpty && !store.isLoadingFocus { emptyState }
            }
            .padding(Tokens.s4)
        }
        .scrollPosition(id: $scrolledTo, anchor: .top)
        .onAppear { scrolledTo = store.scrollAnchor(for: "focus") }
        .onChange(of: scrolledTo) { _, id in store.rememberScroll(id, for: "focus") }
        .scrollContentBackground(.hidden)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let focus = store.focus {
            HStack(alignment: .center, spacing: Tokens.s3) {
                Button {
                    store.closeFocus()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                Image(systemName: symbol(for: focus))
                    .font(.system(size: 22))
                    .foregroundStyle(Tokens.accent)
                    .frame(width: 40, height: 40)
                    .background(Tokens.accent.opacity(0.14), in: .circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(focus.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle(for: focus))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Watching is offered where you already are: on the tag or
                // uploader you are looking at.
                if let query = watchQuery(for: focus) {
                    Button {
                        store.subscribe(to: query, label: focus.title)
                    } label: {
                        Label(isWatched(query) ? "Watching" : "Watch",
                              systemImage: isWatched(query) ? "bell.fill" : "bell")
                    }
                    .controlSize(.small)
                    .disabled(isWatched(query))
                    .help("Notice new wallpapers matching this in the background")
                }

                if case .uploader(let name) = focus {
                    Link("Open on Wallhaven",
                         destination: URL(string: "https://wallhaven.cc/user/\(name)")!)
                        .font(.system(size: 11.5))
                }
            }
            .padding(.bottom, Tokens.s1)
        }
    }

    /// The query a subscription would run. A collection is a snapshot rather
    /// than a search, so it is not watchable.
    private func watchQuery(for focus: Store.Focus) -> String? {
        switch focus {
        case .uploader(let name): "@\(name)"
        case .tag(let ref): "id:\(ref.id)"
        case .uploaderCollection: nil
        }
    }

    private func isWatched(_ query: String) -> Bool {
        store.subscriptions.contains { $0.query == query }
    }

    private func symbol(for focus: Store.Focus) -> String {
        switch focus {
        case .uploader: "person.crop.circle"
        case .tag: "number"
        case .uploaderCollection: "rectangle.stack"
        }
    }

    /// How this page is scoped and ordered.
    ///
    /// On the page rather than in Settings: it is only meaningful here, and the
    /// effect is visible the moment it changes. A collection is somebody else's
    /// fixed list, so neither control applies to one.
    @ViewBuilder
    private var scopeControls: some View {
        if case .uploaderCollection = store.focus {
            EmptyView()
        } else {
            HStack(spacing: Tokens.s3) {
                Toggle(isOn: Binding(get: { store.focusUsesFilters },
                                     set: { store.focusUsesFilters = $0 })) {
                    Text("Use my filters").font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .help("Off shows everything here. On narrows it by the categories "
                      + "you browse with — which can hide most of what you came to see.")

                Divider().frame(height: 14)

                Picker("", selection: Binding(get: { store.focusSorting },
                                              set: { store.focusSorting = $0 })) {
                    ForEach(Sorting.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("How this page is ordered")

                Spacer()
            }
            .padding(.horizontal, Tokens.s3).padding(.vertical, Tokens.s2)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: Tokens.control))
        }
    }

    private func subtitle(for focus: Store.Focus) -> String {
        let counted = store.focusTotal > 0
            ? "\(store.focusTotal) wallpapers"
            : "\(items.count) loaded"
        switch focus {
        case .uploader: return "Uploader · \(counted)"
        case .tag: return "Tag · \(counted)"
        case .uploaderCollection(let username, _): return "\(username)'s collection · \(counted)"
        }
    }

    /// What can be said about an uploader from their uploads.
    ///
    /// Wallhaven has no profile endpoint, so the counts below are derived and
    /// the wording says which are complete and which are only over what has
    /// loaded so far.
    private func uploaderStats(_ stats: Store.UploaderStats) -> some View {
        HStack(spacing: Tokens.s5) {
            stat("\(stats.uploads)", "uploads")
            stat(stats.views.formatted(), "views · first \(stats.loaded)")
            stat(stats.favorites.formatted(), "favorites · first \(stats.loaded)")
            stat("\(stats.averageFavorites)", "average per wallpaper")
            Spacer()
        }
        .padding(Tokens.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .help("Wallhaven publishes no profile, so these come from the uploads "
              + "themselves — totals are across what has loaded, not everything.")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 14, weight: .medium))
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Uploader collections

    private func collections(of username: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            Text("COLLECTIONS").font(.sectionLabel).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(store.uploaderCollections) { collection in
                    Button {
                        Task { await store.showUploaderCollection(collection, of: username) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(collection.label).lineLimit(1)
                            Text("\(collection.count)")
                                .font(.caption2Mono)
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary.opacity(0.45), in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Tag record

    private func tagRecord(_ info: TagInfo) -> some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            Text("ABOUT THIS TAG").font(.sectionLabel).foregroundStyle(.secondary)
            HStack(spacing: Tokens.s2) {
                Chip(text: info.category, tint: Tokens.accent)
                Chip(text: info.purity.rawValue.uppercased(),
                     tint: info.purity == .nsfw ? Tokens.danger
                         : info.purity == .sketchy ? Tokens.warning : Tokens.success)
                if let created = info.createdAt {
                    Text("added \(created.prefix(10))")
                        .font(.caption2Mono).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !info.aliases.isEmpty {
                Text("Also known as \(info.aliases.joined(separator: ", "))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Tokens.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Results

    private var grid: some View {
        Group {
            if theme == .masonry {
                MasonryGrid(items: items,
                            aspect: { $0.ratio > 0 ? $0.ratio : 16.0 / 10 },
                            columnWidth: theme.minTileWidth,
                            spacing: theme.spacing) { tile($0) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: theme.minTileWidth),
                                             spacing: theme.spacing)],
                          spacing: theme.spacing) {
                    ForEach(items) { tile($0) }
                }
            }
        }
        .scrollTargetLayout()
        .transaction { $0.animation = nil }
    }

    private func tile(_ wallpaper: Wallpaper) -> some View {
        WallpaperTile(wallpaper: wallpaper,
                      theme: theme,
                      isHovered: false,
                      isFavorite: store.isFavorite(wallpaper),
                      isSelecting: store.isSelecting,
                      isSelected: store.isSelected(wallpaper),
                      isDownloaded: store.isDownloaded(wallpaper),
                      open: {
                          if store.isSelecting {
                              store.toggleSelection(wallpaper)
                              return
                          }
                          withAnimation(Tokens.normal) { selection = wallpaper }
                          Task { await store.loadDetails(for: wallpaper) }
                      })
            .contextMenu {
                Button("Set as Wallpaper") { store.setWallpaper(wallpaper) }
                Button(store.isFavorite(wallpaper) ? "Remove from Favorites" : "Add to Favorites") {
                    store.toggleFavorite(wallpaper)
                }
                Button("Download") { store.download(wallpaper) }
            }
            .task { await store.loadFocusNextPageIfNeeded(after: wallpaper) }
    }

    private var loadingRow: some View {
        HStack(spacing: Tokens.s2) {
            ProgressView().controlSize(.small)
            Text("Loading more wallpapers").font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.s5)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing here", systemImage: "tray")
        } description: {
            Text("Wallhaven returned no wallpapers for this.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.s6)
    }
}
