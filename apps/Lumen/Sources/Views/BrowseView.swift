import SwiftUI

struct BrowseView: View {
    @Environment(Store.self) private var store
    let section: Section
    @Binding var selection: Wallpaper?
    @State private var hovered: String?
    /// Drives .scrollPosition, so leaving and returning lands in the same spot.
    @State private var scrolledTo: String?

    private var items: [Wallpaper] {
        store.visible(section == .favorites ? store.favorites : store.wallpapers)
    }

    /// What the resolution rule is holding back, so it is never silent.
    private var hidden: Int {
        store.hiddenCount(in: section == .favorites ? store.favorites : store.wallpapers)
    }
    private var theme: GridTheme { store.gridTheme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s4) {
                if let message = store.errorMessage { notice(message) }
                if hidden > 0 {
                    HStack(spacing: Tokens.s2) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("\(hidden) hidden — below \(Int(WallpaperFitter.mainPixelSize.width)) × \(Int(WallpaperFitter.mainPixelSize.height))")
                        Button("Show them") { store.hideBelowDisplay = false }
                            .controlSize(.small)
                        Spacer()
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }

                // Re-laying out hundreds of tiles is not something to
                // interpolate; the tiles themselves cross-fade instead.
                Group {
                    if theme == .masonry {
                        MasonryGrid(items: items,
                                    aspect: { $0.ratio > 0 ? $0.ratio : 16.0 / 10 },
                                    columnWidth: theme.minTileWidth,
                                    spacing: theme.spacing) { tile($0) }
                    } else if theme == .natural {
                        JustifiedGrid(items: items,
                                      aspect: { $0.ratio > 0 ? $0.ratio : 16.0 / 10 },
                                      targetRowHeight: theme.minTileWidth,
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

                if store.isLoading { loadingRow }
                if items.isEmpty && !store.isLoading { emptyState }
            }
            .padding(Tokens.s4)
            // Animating on `items.map(\.id)` rebuilt an array of every id on
            // each render and animated the whole grid; count is enough to
            // catch an append, and layout changes animate on `theme` alone.
            .animation(Tokens.normal, value: items.count)
        }
        .scrollPosition(id: $scrolledTo, anchor: .top)
        .onAppear { scrolledTo = store.scrollAnchor(for: "browse") }
        .onChange(of: scrolledTo) { _, id in store.rememberScroll(id, for: "browse") }
        .scrollContentBackground(.hidden)
        .searchable(text: Binding(get: { store.filters.query }, set: { store.filters.query = $0 }),
                    placement: .toolbar, prompt: "Search wallpapers or #tag")
        .onSubmit(of: .search) { Task { await store.search() } }
    }

    private func tile(_ wallpaper: Wallpaper) -> some View {
        WallpaperTile(wallpaper: wallpaper,
                      theme: theme,
                      isHovered: hovered == wallpaper.id,
                      isFavorite: store.isFavorite(wallpaper),
                      isSelecting: store.isSelecting,
                      isSelected: store.isSelected(wallpaper),
                      isDownloaded: store.isDownloaded(wallpaper),
                      open: {
                          // In select mode the whole tile is a checkbox.
                          if store.isSelecting {
                              store.toggleSelection(wallpaper)
                          } else {
                              open(wallpaper)
                          }
                      })
            .onHover { inside in
                withAnimation(Tokens.quick) { hovered = inside ? wallpaper.id : (hovered == wallpaper.id ? nil : hovered) }
            }
            .onDrag {
                // Only a real file can be dropped into Finder; otherwise hand
                // over the Wallhaven page, which is still useful in a browser.
                if let local = wallpaper.localFile, FileManager.default.fileExists(atPath: local.path) {
                    return NSItemProvider(contentsOf: local) ?? NSItemProvider()
                }
                return NSItemProvider(object: (wallpaper.url ?? wallpaper.path) as NSURL)
            }
            .contextMenu {
                Button("Set as Wallpaper") { store.setWallpaper(wallpaper) }
                Button(store.isFavorite(wallpaper) ? "Remove from Favorites" : "Add to Favorites") {
                    store.toggleFavorite(wallpaper)
                }
                Button("Download") { store.download(wallpaper) }
                Divider()
                ForEach(store.displays) { display in
                    Button("Set on \(display.name)") { store.setWallpaper(wallpaper, on: display) }
                }
                if let url = wallpaper.url {
                    Divider()
                    Link("Open on Wallhaven", destination: url)
                }
            }
            .task {
                prefetchAhead(of: wallpaper)
                await store.loadNextPageIfNeeded(after: wallpaper)
            }
    }

    private func open(_ wallpaper: Wallpaper) {
        withAnimation(Tokens.normal) { selection = wallpaper }
        Task { await store.loadDetails(for: wallpaper) }
    }

    /// Decodes the next screenful while the user is still looking at this one.
    private func prefetchAhead(of wallpaper: Wallpaper) {
        guard let index = items.firstIndex(where: { $0.id == wallpaper.id }) else { return }
        let upcoming = items[index..<min(index + 12, items.count)].map(\.thumb)
        ImageCache.shared.prefetch(upcoming)
    }

    private func notice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.captionMono)
        }
        .foregroundStyle(Tokens.warning)
        .padding(Tokens.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.warning.opacity(0.12), in: .rect(cornerRadius: Tokens.control))
        .transition(.move(edge: .top).combined(with: .opacity))
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
            Label(section == .favorites ? "No favorites yet" : "Search for wallpapers",
                  systemImage: section == .favorites ? "heart" : "magnifyingglass")
        } description: {
            Text(section == .favorites
                 ? "Click the heart on any tile to save it here."
                 : "Try a tag, or open Filters and pick a resolution.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.s6)
    }
}

struct WallpaperTile: View {
    @Environment(Store.self) private var store
    let wallpaper: Wallpaper
    let theme: GridTheme
    let isHovered: Bool
    let isFavorite: Bool
    var isSelecting = false
    var isSelected = false
    var isDownloaded = false
    let open: () -> Void

    /// Masonry and Natural both draw the picture at its own shape, so the tile
    /// takes its size from the layout rather than imposing one.
    private var aspect: Double {
        theme == .masonry || theme == .natural
            ? wallpaper.ratio
            : (theme == .cinema ? 16.0 / 9 : 16.0 / 10)
    }

    var body: some View {
        CachedImage(url: wallpaper.thumb) { image in
            image
                .resizable()
                .scaledToFill()
                .scaleEffect(isHovered ? 1.05 : 1)
                .transition(.opacity)
        } placeholder: {
            Rectangle().fill(.quaternary).shimmer()
        } failure: {
            Rectangle().fill(.quaternary)
                .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
        }
        .aspectRatio(theme == .masonry || theme == .natural ? nil : aspect, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay { if isHovered { hoverLayer } }
        .overlay { purityBorder }
        .overlay { selectionLayer }
        .overlay { downloadedBadge }
        .clipShape(.rect(cornerRadius: theme.cornerRadius))
        .overlay {
            if isSelecting && isSelected {
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .strokeBorder(Tokens.accent, lineWidth: 3)
            }
        }
        // Only the hovered tile gets a shadow. A shadow is an offscreen pass,
        // and paying for one per tile is what made a full grid scroll badly.
        .compositingGroup()
        .shadow(color: .black.opacity(isHovered ? 0.4 : 0),
                radius: isHovered ? 14 : 0, y: isHovered ? 7 : 0)
        .scaleEffect(isHovered ? 1.014 : 1)
        .zIndex(isHovered ? 1 : 0)
        .animation(Tokens.normal, value: isHovered)
        // Opening is the tile's own gesture. The controls in the hover layer
        // are Buttons and consume their clicks first, so long as each declares
        // a hit area — see TileButton.
        .contentShape(.rect)
        .onTapGesture(perform: open)
    }

    private var hoverLayer: some View {
        ZStack {
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
                    Button { store.toggleFavorite(wallpaper) } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 25, height: 25)
                            .background(.black.opacity(0.45), in: .circle)
                            .foregroundStyle(isFavorite ? Tokens.brand : .white)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(isFavorite ? 1.08 : 1)
                    .animation(Tokens.bouncy, value: isFavorite)
                }
                Spacer()
                HStack(spacing: Tokens.s2) {
                    Button("Set") { store.setWallpaper(wallpaper) }
                        .buttonStyle(TileButton(prominent: true))
                    Button("Download") { store.download(wallpaper) }
                        .buttonStyle(TileButton())
                    Spacer()
                    Text("\(wallpaper.favorites.formatted()) favs")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                }
                .offset(y: isHovered ? 0 : 8)
            }
            .padding(Tokens.s3)
            .foregroundStyle(.white)
        }
        .opacity(isSelecting ? 0 : 1)
        .allowsHitTesting(!isSelecting)
        .transition(.opacity)
    }

    /// Marks a wallpaper already sitting in the download directory, so you can
    /// see what you have without opening it.
    @ViewBuilder
    private var downloadedBadge: some View {
        if isDownloaded && !isSelecting {
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, Tokens.success)
                        .padding(Tokens.s2)
                }
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }

    /// A checkbox in the corner while selecting, so the state is visible
    /// without hovering.
    @ViewBuilder
    private var selectionLayer: some View {
        if isSelecting {
            VStack {
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.85))
                        .background {
                            Circle()
                                .fill(isSelected ? Tokens.accent : .black.opacity(0.35))
                                .padding(1)
                        }
                        .padding(Tokens.s2)
                    Spacer()
                }
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var purityBorder: some View {
        if store.showPurityBorders, wallpaper.purity != .sfw {
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(wallpaper.purity == .nsfw ? Tokens.danger : Tokens.warning, lineWidth: 2)
        }
    }
}

struct TileButton: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .medium))
            .padding(.horizontal, 12).frame(height: 27)
            .foregroundStyle(.white)
            .background {
                if prominent {
                    Capsule().fill(Tokens.brand)
                        .shadow(color: Tokens.brand.opacity(0.5), radius: 10, y: 3)
                } else {
                    Capsule().fill(.white.opacity(0.24)).background(.ultraThinMaterial, in: .capsule)
                }
            }
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Tokens.bouncy, value: configuration.isPressed)
    }
}

/// Height-preserving masonry — keeps every thumbnail's true aspect ratio.
struct MasonryLayout: Layout {
    var columnWidth: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? columnWidth
        let columns = max(1, Int((width + spacing) / (columnWidth + spacing)))
        var heights = [CGFloat](repeating: 0, count: columns)
        let tileWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        for subview in subviews {
            let index = heights.firstIndex(of: heights.min()!) ?? 0
            let size = subview.sizeThatFits(.init(width: tileWidth, height: nil))
            heights[index] += size.height + spacing
        }
        return CGSize(width: width, height: max(0, (heights.max() ?? 0) - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = max(1, Int((bounds.width + spacing) / (columnWidth + spacing)))
        let tileWidth = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = [CGFloat](repeating: 0, count: columns)
        for subview in subviews {
            let index = heights.firstIndex(of: heights.min()!) ?? 0
            let size = subview.sizeThatFits(.init(width: tileWidth, height: nil))
            let x = bounds.minX + CGFloat(index) * (tileWidth + spacing)
            subview.place(at: CGPoint(x: x, y: bounds.minY + heights[index]),
                          proposal: .init(width: tileWidth, height: size.height))
            heights[index] += size.height + spacing
        }
    }
}

/// Loading shimmer for tiles that haven't decoded yet.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content.overlay {
            LinearGradient(colors: [.clear, .white.opacity(0.12), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .offset(x: phase * 400)
                .blendMode(.plusLighter)
        }
        // One offscreen layer for the gradient sweep, so the repeating
        // animation stays on the GPU instead of re-compositing each frame.
        .drawingGroup()
        .task {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

extension View { func shimmer() -> some View { modifier(Shimmer()) } }
