import SwiftUI

struct DetailSheet: View {
    @Environment(Store.self) private var store
    let wallpaper: Wallpaper
    var close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            preview
            Divider()
            inspector
        }
        .frame(minWidth: 860, idealWidth: 1080, minHeight: 520, idealHeight: 660)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: Tokens.sheet))
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            AsyncImage(url: store.preferLocalPreview ? wallpaper.previewSource : wallpaper.path,
                       transaction: .init(animation: .easeOut(duration: 0.4))) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit().transition(.opacity)
                case .failure: Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                default: ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(wallpaper.displayResolution)
                .font(.captionMono)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.black.opacity(0.5), in: .rect(cornerRadius: 7))
                .foregroundStyle(.white)
                .padding(Tokens.s3)
        }
        .frame(minWidth: 420)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.s4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("wallhaven-\(wallpaper.id)").font(.system(size: 15, weight: .semibold))
                    Text("\(wallpaper.category) · \(wallpaper.purity.rawValue)")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }

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
                }

                metadata
                tags
                displays
            }
            .padding(Tokens.s4)
        }
        .frame(width: 304)
        .scrollContentBackground(.hidden)
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

    @ViewBuilder
    private var tags: some View {
        if !wallpaper.tags.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.s2) {
                Text("IMAGE TAGS").font(.sectionLabel).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(wallpaper.tags, id: \.self) { tag in
                        Button(tag) {
                            store.filters.query = tag
                            close()
                            Task { await store.search() }
                        }
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
}
