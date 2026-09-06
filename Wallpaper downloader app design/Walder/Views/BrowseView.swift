import SwiftUI

struct BrowseView: View {
    @Environment(Store.self) private var store
    let section: Section
    @Binding var selection: Wallpaper?
    @State private var hovered: String?
    @Namespace private var zoom

    private var items: [Wallpaper] { section == .favorites ? store.favorites : store.wallpapers }
    private var theme: GridTheme { store.gridTheme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s4) {
                if let message = store.errorMessage { notice(message) }

                if theme == .masonry {
                    MasonryLayout(columnWidth: theme.minTileWidth, spacing: theme.spacing) {
                        ForEach(items) { tile($0) }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: theme.minTileWidth), spacing: theme.spacing)],
                              spacing: theme.spacing) {
                        ForEach(items) { tile($0) }
                    }
                }

                if store.isLoading { loadingRow }
                if items.isEmpty && !store.isLoading { emptyState }
            }
            .padding(Tokens.s4)
            .animation(theme == .masonry ? nil : Tokens.normal, value: theme)
            .animation(Tokens.normal, value: items.map(\.id))
        }
        .scrollContentBackground(.hidden)
        .searchable(text: Binding(get: { store.filters.query }, set: { store.filters.query = $0 }),
                    placement: .toolbar, prompt: "Search wallpapers or tag")
        .onSubmit(of: .search) { Task { await store.search() } }
    }

    private func tile(_ wallpaper: Wallpaper) -> some View {
        WallpaperTile(wallpaper: wallpaper,
                      theme: theme,
                      isHovered: hovered == wallpaper.id,
                      isFavorite: store.isFavorite(wallpaper))
            .matchedGeometryEffect(id: wallpaper.id, in: zoom, isSource: selection?.id != wallpaper.id)
            .onHover { inside in
                withAnimation(Tokens.quick) { hovered = inside ? wallpaper.id : (hovered == wallpaper.id ? nil : hovered) }
            }
            .onTapGesture {
                withAnimation(Tokens.sheetIn) { selection = wallpaper }
                Task { await store.loadTags(for: wallpaper) }
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
            .task { await store.loadNextPageIfNeeded(after: wallpaper) }
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

    private var aspect: Double { theme == .masonry ? wallpaper.ratio : (theme == .cinema ? 16.0/9 : 16.0/10) }

    var body: some View {
        AsyncImage(url: wallpaper.thumb, transaction: .init(animation: .easeOut(duration: 0.35))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill().scaleEffect(isHovered ? 1.05 : 1)
            case .failure:
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
            default:
                Rectangle().fill(.quaternary).shimmer()
            }
        }
        .aspectRatio(aspect, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay { hoverLayer }
        .overlay { purityBorder }
        .clipShape(.rect(cornerRadius: theme.cornerRadius))
        .shadow(color: .black.opacity(isHovered ? 0.45 : 0.18),
                radius: isHovered ? 20 : 6, y: isHovered ? 10 : 2)
        .scaleEffect(isHovered ? 1.014 : 1)
        .zIndex(isHovered ? 1 : 0)
        .animation(Tokens.normal, value: isHovered)
    }

    private var hoverLayer: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
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
                            .foregroundStyle(isFavorite ? Tokens.wallhavenBlue : .white)
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
        .opacity(isHovered ? 1 : 0)
        .animation(Tokens.quick, value: isHovered)
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
                    Capsule().fill(Tokens.wallhavenBlue)
                        .shadow(color: Tokens.wallhavenBlue.opacity(0.5), radius: 10, y: 3)
                } else {
                    Capsule().fill(.white.opacity(0.24)).background(.ultraThinMaterial, in: .capsule)
                }
            }
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
        .task {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

extension View { func shimmer() -> some View { modifier(Shimmer()) } }
