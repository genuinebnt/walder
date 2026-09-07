import SwiftUI

/// Full-window preview. Takes over the whole app rather than opening a sheet,
/// so the image is as large as the window allows when deciding whether to keep
/// it. Steps through the browsed list with the arrow keys, and carries every
/// action that applies to one wallpaper.
///
/// The inspector collapses for a full-bleed look; the keyboard works either way.
struct PreviewPane: View {
    @Environment(Store.self) private var store

    /// The list being browsed, so ← and → have somewhere to go.
    let items: [Wallpaper]
    var close: () -> Void

    /// What the sheet was opened on. SwiftUI re-creates this view whenever the
    /// browsed list changes, and searching from the inspector replaces that
    /// list underneath — so `items` can be shorter than `index`, or empty. This
    /// is what stays on screen when that happens.
    let opened: Wallpaper

    @State private var index: Int
    /// Briefly true after a set, so the button can confirm without the pane
    /// closing out from under you.
    @State private var justSet = false
    /// Whether the menu bar will read over this wallpaper. Computed from the
    /// decoded image, so it arrives once the preview has loaded.
    @State private var menuBar: MenuBarLegibility.Verdict?

    init(items: [Wallpaper], selected: Wallpaper, close: @escaping () -> Void) {
        self.items = items
        self.opened = selected
        self.close = close
        _index = State(initialValue: items.firstIndex(where: { $0.id == selected.id }) ?? 0)
    }

    @FocusState private var focused: Bool

    /// Convenience for a single wallpaper with nothing to page through.
    init(wallpaper: Wallpaper, close: @escaping () -> Void) {
        self.init(items: [wallpaper], selected: wallpaper, close: close)
    }

    private var wallpaper: Wallpaper {
        guard !items.isEmpty else { return opened }
        return items[min(max(index, 0), items.count - 1)]
    }

    /// Position shown in the chrome, clamped to whatever the list holds now.
    private var position: (current: Int, total: Int) {
        guard !items.isEmpty else { return (1, 1) }
        return (min(max(index, 0), items.count - 1) + 1, items.count)
    }

    var body: some View {
        HStack(spacing: 0) {
            preview
            if store.previewShowsInspector {
                Divider()
                inspector
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The inspector gets out of the way when the window cannot hold both
        // it and a readable image column — which is most of the time once the
        // image is expanded.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in
                        store.reconcilePreviewInspector(windowWidth: width,
                                                        expanded: store.previewZoomed)
                    }
                    .onChange(of: store.previewZoomed) { _, expanded in
                        store.reconcilePreviewInspector(windowWidth: proxy.size.width,
                                                        expanded: expanded)
                    }
            }
        }
        .background(.background)
        .animation(Tokens.normal, value: store.previewShowsInspector)
        // As an overlay rather than a sheet, this has to ask for key focus.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        // Arrow keys page through the list; Escape closes; Space toggles zoom.
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) {
            store.togglePreviewZoom()
            return .handled
        }
        .task(id: wallpaper.id) {
            // Order matters: the image you are looking at should not be
            // competing for bandwidth with the ones you might look at next.
            // Details are a small JSON call, so they run alongside.
            async let details: Void = store.loadDetails(for: wallpaper)
            _ = await ImageCache.shared.image(for: currentSource,
                                              maxPixels: ImageDetail.preview)
            await details
            // The strip under the menu bar can only be judged once there is a
            // decoded image to judge.
            menuBar = ImageCache.shared.cached(currentSource, maxPixels: ImageDetail.preview)
                .flatMap { MenuBarLegibility.assess($0, displaySize: WallpaperFitter.mainPixelSize) }
            // The visible image is decoded; now warm what ← and → will need.
            prefetchNeighbours()
            await store.loadNextPageIfNeeded(after: wallpaper)
        }
    }

    // MARK: Navigation

    /// Drives the same stepping the arrow keys do, for the verify harness.
    func stepForVerification(_ delta: Int) { step(delta) }

    private func step(_ delta: Int) {
        let next = index + delta
        guard items.indices.contains(next) else { return }
        // Deliberately leaves the zoom alone: stepping through images in
        // full-bleed used to drop back to the fitted view every time.
        withAnimation(Tokens.quick) { index = next }
    }

    /// What the preview is actually showing.
    private var currentSource: URL {
        store.preferLocalPreview ? wallpaper.previewSource : wallpaper.path
    }

    /// Keeps the neighbours warm so paging is instant. Runs only once the
    /// visible image has finished decoding.
    private func prefetchNeighbours() {
        let neighbours = [index - 3, index - 2, index - 1, index + 1, index + 2, index + 3]
            .filter { items.indices.contains($0) }
            .map { items[$0].previewSource }
        ImageCache.shared.prefetch(neighbours, maxPixels: ImageDetail.preview)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Color.black

            CachedImage(url: currentSource, maxPixels: ImageDetail.preview) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: store.previewZoomed ? .fill : .fit)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A zoomed image is larger than its column by definition; without this
        // it spills under the inspector.
        .clipped()
        .contentShape(.rect)
        .onTapGesture { store.togglePreviewZoom() }
    }

    private var overlayChrome: some View {
        VStack {
            HStack(alignment: .top) {
                Button(action: close) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: .capsule)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Back to the grid (Escape)")

                Text(wallpaper.displayResolution)
                    .font(.captionMono)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 7))
                Spacer()
                Text("\(position.current) of \(position.total)")
                    .font(.captionMono)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: .rect(cornerRadius: 7))
                Button {
                    store.togglePreviewInspector()
                } label: {
                    Image(systemName: store.previewShowsInspector
                          ? "sidebar.trailing" : "sidebar.leading")
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
                stepButton("chevron.right", enabled: index + 1 < items.count) { step(1) }
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
                fitReport
                appearancePair
                accentMatch
                collections
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
        // Opaque on purpose: the material alone let the wallpaper show through
        // and made every label hard to read.
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
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .help("macOS gives each Space its own desktop picture")
            }

            Button {
                store.setWallpaper(wallpaper)
                confirmSet()
            } label: {
                Label(justSet ? "Set" : "Set as Wallpaper",
                      systemImage: justSet ? "checkmark" : "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .tint(justSet ? Tokens.success : nil)
            .animation(Tokens.quick, value: justSet)

            HStack(spacing: Tokens.s2) {
                Menu {
                    Button("Download Original") { store.download(wallpaper) }
                    Divider()
                    // Wallhaven serves one file per wallpaper, so anything
                    // other than the original is produced here.
                    ForEach(store.fittedSizes(for: wallpaper), id: \.label) { option in
                        Button("Resized · \(option.label)") {
                            store.downloadFitted(wallpaper, to: option.size)
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                } primaryAction: {
                    store.download(wallpaper)
                }
                .menuStyle(.button)
                Button { store.toggleFavorite(wallpaper) } label: {
                    Label(store.isFavorite(wallpaper) ? "Saved" : "Favorite",
                          systemImage: store.isFavorite(wallpaper) ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity)
                }
                .tint(store.isFavorite(wallpaper) ? Tokens.brand : nil)
            }
            .controlSize(.large)

            Button {
                close()
                store.findSimilar(to: wallpaper)
            } label: {
                Label("Find Similar", systemImage: "square.on.square.dashed")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help("Search this wallpaper's strongest tags and dominant colour")

            if let url = wallpaper.url {
                Link("Open on Wallhaven", destination: url)
                    .font(.system(size: 11.5))
            }
        }
    }

    /// Whether this wallpaper actually suits the screen, and what to do when it
    /// does not. Wallhaven has one file per wallpaper, so the choices are a
    /// better-matching wallpaper or a local resize — there is no bigger
    /// download to fetch.
    private var fitReport: some View {
        let fit = store.fit(wallpaper)
        return VStack(alignment: .leading, spacing: Tokens.s2) {
            Text("ON THIS DISPLAY").font(.sectionLabel).foregroundStyle(.secondary)

            HStack(spacing: Tokens.s2) {
                Image(systemName: fit.isPerfect ? "checkmark.circle.fill"
                        : fit.isGood ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(fit.isPerfect ? Tokens.success
                                     : fit.isGood ? Tokens.success : Tokens.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(fit.summary).font(.system(size: 12))
                    Text("\(Int(fit.display.width)) × \(Int(fit.display.height)) native")
                        .font(.caption2Mono).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Tokens.control))

            if let menuBar {
                HStack(spacing: Tokens.s2) {
                    Image(systemName: menuBar.isRisky
                          ? "menubar.rectangle" : "checkmark.circle")
                        .foregroundStyle(menuBar.isRisky ? Tokens.warning : Tokens.success)
                    Text(menuBar.summary).font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Tokens.control))
                .help("macOS picks the menu bar's text colour from the whole "
                      + "image, so a bright or busy strip at the top can leave it unreadable")
            }

            if !fit.isPerfect {
                HStack(spacing: Tokens.s2) {
                    Button {
                        store.setFittedWallpaper(wallpaper)
                        confirmSet()
                    } label: {
                        Label("Resize to Fit", systemImage: "crop")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Crop and scale a copy to this display's exact pixels, then set it")

                    Button {
                        close()
                        store.findFittingWallpapers(like: wallpaper)
                    } label: {
                        Label("Find This Size", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Search similar wallpapers at your display's resolution and shape")
                }
                .controlSize(.small)

                Button {
                    close()
                    store.editCrop(for: wallpaper)
                } label: {
                    Label("Choose the Crop…", systemImage: "crop.rotate")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .help("Pick which part of the image survives, rather than the "
                      + "centre crop macOS would make")
            }
        }
    }

    /// Offer to set the system accent to the nearest match. Deliberately
    /// explicit that it is a system setting and that it snaps to one of seven.
    @ViewBuilder
    private var accentMatch: some View {
        if let accent = store.suggestedAccent(for: wallpaper) {
            VStack(alignment: .leading, spacing: Tokens.s2) {
                Text("SYSTEM ACCENT").font(.sectionLabel).foregroundStyle(.secondary)
                HStack(spacing: Tokens.s2) {
                    Circle().fill(accent.color).frame(width: 18, height: 18)
                        .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Closest match: \(accent.label)").font(.system(size: 12))
                        Text("macOS offers seven accents, so this is nearest, not exact")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: Tokens.s2) {
                    Button("Match Accent") { store.matchSystemAccent(to: wallpaper) }
                    if store.canRestoreAccent {
                        Button("Restore") { store.restoreSystemAccent() }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// Bind this wallpaper to light or dark, so the desktop follows the system.
    private var appearancePair: some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            Text("APPEARANCE PAIR").font(.sectionLabel).foregroundStyle(.secondary)
            HStack(spacing: Tokens.s2) {
                ForEach([false, true], id: \.self) { dark in
                    let isThis = dark
                        ? store.darkWallpaper?.id == wallpaper.id
                        : store.lightWallpaper?.id == wallpaper.id
                    Button {
                        // Tapping the current one unbinds it.
                        store.setPaired(isThis ? nil : wallpaper, dark: dark)
                    } label: {
                        Label(dark ? "Dark" : "Light",
                              systemImage: dark ? "moon" : "sun.max")
                            .font(.system(size: 12))
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(isThis ? Tokens.accent.opacity(0.2)
                                        : Color.secondary.opacity(0.12),
                                        in: .rect(cornerRadius: Tokens.control))
                            .foregroundStyle(isThis ? Tokens.accent : .secondary)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle("Follow system appearance", isOn: Binding(
                get: { store.followsAppearance },
                set: { store.followsAppearance = $0 }))
                .font(.system(size: 11.5))
                .controlSize(.small)
                .disabled(store.lightWallpaper == nil && store.darkWallpaper == nil)
        }
    }

    /// Which collections hold this wallpaper, and a switch for each.
    @ViewBuilder
    private var collections: some View {
        if !store.collections.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.s2) {
                Text("COLLECTIONS").font(.sectionLabel).foregroundStyle(.secondary)
                ForEach(store.collections) { collection in
                    let member = store.isMember(wallpaper, of: collection)
                    Button {
                        store.setMembership(wallpaper, of: collection, member: !member)
                    } label: {
                        HStack {
                            Image(systemName: member ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(member ? Tokens.accent : Color.secondary.opacity(0.5))
                            Text(collection.name).lineLimit(1)
                            Spacer()
                            Text("\(collection.wallpapers.count)")
                                .font(.caption2Mono).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Tokens.control))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
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
                    close()
                    Task { await store.showUploader(name) }
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
                            .overlay {
                                if store.filters.color == hex {
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(Tokens.accent, lineWidth: 2)
                                }
                            }
                            .contentShape(.rect)
                            .onTapGesture {
                                // Tapping the active colour clears it, so the
                                // palette works as a filter rather than a
                                // one-way trip.
                                store.filters.color = store.filters.color == hex ? nil : hex
                                runSearch()
                            }
                            .help(store.filters.color == hex
                                  ? "Clear the #\(hex) filter"
                                  : "Search wallpapers in #\(hex)")
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
                    // A tag with an id opens its own page; without one, fall
                    // back to a "#tag" search, which is what the grid gives us
                    // before the detail endpoint has answered.
                    ForEach(tagChips, id: \.name) { chip in
                        Button(chip.name) {
                            close()
                            if let ref = chip.ref {
                                Task { await store.showTag(ref) }
                            } else {
                                store.filters.query = "#\(chip.name)"
                                Task { await store.search() }
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: .capsule)
                        .contentShape(.capsule)
                    }
                }
            }
        }
    }

    /// Tag names paired with their record when the detail endpoint has supplied
    /// one.
    private var tagChips: [(name: String, ref: TagRef?)] {
        guard wallpaper.tagRefs.isEmpty else {
            return wallpaper.tagRefs.map { ($0.name, $0) }
        }
        return wallpaper.tags.map { ($0, nil) }
    }

    private var displays: some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            Text("SEND TO DISPLAY").font(.sectionLabel).foregroundStyle(.secondary)
            ForEach(store.displays) { display in
                Button {
                    store.setWallpaper(wallpaper, on: display)
                    confirmSet()
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

    /// Flashes the confirmation on the Set button. Deliberately does not close
    /// the pane: setting is something you do while comparing wallpapers, so
    /// dropping back to the grid each time made the pane useless for that.
    private func confirmSet() {
        withAnimation(Tokens.quick) { justSet = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(Tokens.normal) { justSet = false }
        }
    }

    private func runSearch() {
        close()
        Task { await store.search() }
    }
}
