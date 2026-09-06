import SwiftUI

/// Full preview. Steps through the list that was being browsed with the arrow
/// keys, and carries every action that applies to one wallpaper.
///
/// The inspector can be collapsed for a full-bleed look; the keyboard works the
/// same either way.
struct DetailSheet: View {
    @Environment(Store.self) private var store

    /// The list being browsed, so ← and → have somewhere to go.
    let items: [Wallpaper]
    var close: () -> Void

    @State private var index: Int
    @State private var showInspector = true
    @State private var zoomed = false

    init(items: [Wallpaper], selected: Wallpaper, close: @escaping () -> Void) {
        self.items = items
        self.close = close
        _index = State(initialValue: items.firstIndex(where: { $0.id == selected.id }) ?? 0)
    }

    /// Convenience for a single wallpaper with nothing to page through.
    init(wallpaper: Wallpaper, close: @escaping () -> Void) {
        self.init(items: [wallpaper], selected: wallpaper, close: close)
    }

    private var wallpaper: Wallpaper {
        items.indices.contains(index) ? items[index] : items[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            preview
            if showInspector {
                Divider()
                inspector
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: 860, idealWidth: 1180, minHeight: 520, idealHeight: 720)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: Tokens.sheet))
        .animation(Tokens.normal, value: showInspector)
        // Arrow keys page through the list; Escape closes; Space toggles zoom.
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) {
            withAnimation(Tokens.normal) { zoomed.toggle() }
            return .handled
        }
        .task(id: wallpaper.id) {
            await store.loadTags(for: wallpaper)
            prefetchNeighbours()
            await store.loadNextPageIfNeeded(after: wallpaper)
        }
    }

    // MARK: Navigation

    private func step(_ delta: Int) {
        let next = index + delta
        guard items.indices.contains(next) else { return }
        withAnimation(Tokens.quick) {
            index = next
            zoomed = false
        }
    }

    /// Keeps the neighbours warm so paging is instant.
    private func prefetchNeighbours() {
        let neighbours = [index - 2, index - 1, index + 1, index + 2]
            .filter { items.indices.contains($0) }
            .map { items[$0].previewSource }
        ImageCache.shared.prefetch(neighbours, maxPixels: ImageDetail.preview)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Color.black

            CachedImage(url: store.preferLocalPreview ? wallpaper.previewSource : wallpaper.path,
                        maxPixels: ImageDetail.preview) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: zoomed ? .fill : .fit)
                    .transition(.opacity)
            } placeholder: {
                ProgressView().controlSize(.large)
            } failure: {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            .id(wallpaper.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            overlayChrome
        }
        .frame(minWidth: 420)
        .contentShape(.rect)
        .onTapGesture { withAnimation(Tokens.normal) { zoomed.toggle() } }
    }

    private var overlayChrome: some View {
        VStack {
            HStack(alignment: .top) {
                Text(wallpaper.displayResolution)
                    .font(.captionMono)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 7))
                Spacer()
                Text("\(index + 1) of \(items.count)")
                    .font(.captionMono)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 7))
                Button {
                    withAnimation(Tokens.normal) { showInspector.toggle() }
                } label: {
                    Image(systemName: showInspector ? "sidebar.trailing" : "sidebar.leading")
                        .frame(width: 26, height: 26)
                        .background(.black.opacity(0.5), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Show or hide the inspector")
            }

            Spacer()

            HStack {
                stepButton("chevron.left", enabled: index > 0) { step(-1) }
                Spacer()
                stepButton("chevron.right", enabled: index < items.count - 1) { step(1) }
            }
        }
        .foregroundStyle(.white)
        .padding(Tokens.s3)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.45), in: .circle)
                .overlay { Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }

    // MARK: Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("wallhaven-\(wallpaper.id)").font(.system(size: 15, weight: .semibold))
                    Text("\(wallpaper.category) · \(wallpaper.purity.rawValue)")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }

                actions
                uploader
                metadata
                palette
                tags
                displays
            }
            .padding(Tokens.s4)
        }
        .frame(width: 316)
        .scrollContentBackground(.hidden)
    }

    private var actions: some View {
        VStack(spacing: Tokens.s2) {
            Button {
                store.setWallpaper(wallpaper)
                close()
            } label: {
                Label("Set as Wallpaper", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            HStack(spacing: Tokens.s2) {
                Button { store.download(wallpaper) } label: {
                    Label("Download", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                }
                Button { store.toggleFavorite(wallpaper) } label: {
                    Label(store.isFavorite(wallpaper) ? "Saved" : "Favorite",
                          systemImage: store.isFavorite(wallpaper) ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity)
                }
                .tint(store.isFavorite(wallpaper) ? Tokens.brand : nil)
            }
            .controlSize(.large)

            if let url = wallpaper.url {
                Link("Open on Wallhaven", destination: url)
                    .font(.system(size: 11.5))
            }
        }
    }

    /// Uploader, and a way to see the rest of their uploads. Wallhaven treats
    /// `@name` in a query as an uploader search.
    @ViewBuilder
    private var uploader: some View {
        if let name = wallpaper.uploader {
            VStack(alignment: .leading, spacing: Tokens.s2) {
                Text("UPLOADED BY").font(.sectionLabel).foregroundStyle(.secondary)
                Button {
                    search("@\(name)")
                } label: {
                    HStack(spacing: Tokens.s2) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(.system(size: 13, weight: .medium))
                            Text("See all uploads").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right.circle").foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Tokens.control))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var metadata: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).font(.captionMono)
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
         ("Ratio", String(format: "%.2f", wallpaper.ratio)),
         ("File", wallpaper.fileType.replacingOccurrences(of: "image/", with: "").uppercased() + " · " + wallpaper.sizeMB),
         ("Views", wallpaper.views.formatted()),
         ("Favorites", wallpaper.favorites.formatted()),
         ("Added", wallpaper.createdAt)]
    }

    /// The image's own palette, each swatch a colour search.
    @ViewBuilder
    private var palette: some View {
        if !wallpaper.colors.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.s2) {
                Text("PALETTE").font(.sectionLabel).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    ForEach(wallpaper.colors, id: \.self) { hex in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(hex: hex))
                            .frame(height: 24)
                            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5) }
                            .onTapGesture {
                                store.filters.color = hex
                                runSearch()
                            }
                            .help("#\(hex)")
                    }
                }
            }
        }
    }

    /// Every tag on the image; tapping one runs a real tag search.
    @ViewBuilder
    private var tags: some View {
        if !wallpaper.tags.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.s2) {
                Text("IMAGE TAGS").font(.sectionLabel).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(wallpaper.tags, id: \.self) { tag in
                        // The "#" is what makes this a tag search rather than a
                        // keyword search.
                        Button(tag) { search("#\(tag)") }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.quaternary.opacity(0.5), in: .capsule)
                    }
                }
            }
        }
    }

    private var displays: some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            Text("SEND TO DISPLAY").font(.sectionLabel).foregroundStyle(.secondary)
            ForEach(store.displays) { display in
                Button {
                    store.setWallpaper(wallpaper, on: display)
                } label: {
                    HStack {
                        Text(display.name).lineLimit(1)
                        Spacer()
                        if display.wallpaper?.id == wallpaper.id {
                            Text("Current").foregroundStyle(Tokens.success)
                        } else {
                            Image(systemName: "arrow.right.circle").foregroundStyle(.tertiary)
                        }
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

    private func search(_ query: String) {
        store.filters.query = query
        runSearch()
    }

    private func runSearch() {
        close()
        Task { await store.search() }
    }
}
