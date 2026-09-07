import SwiftUI
import Combine

enum Section: String, Hashable, CaseIterable, Identifiable {
    case browse, toplist, favorites, downloads, collections, folders, displays, schedule, settings
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .browse: "square.grid.2x2"
        case .toplist: "chart.bar"
        case .favorites: "heart"
        case .downloads: "arrow.down.circle"
        case .collections: "rectangle.stack"
        case .folders: "folder"
        case .displays: "display.2"
        case .schedule: "clock.arrow.2.circlepath"
        case .settings: "gearshape"
        }
    }
    var isGrid: Bool { self == .browse || self == .toplist || self == .favorites }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @State private var section: Section = .browse
    @State private var showFilters = false
    @State private var selection: Wallpaper?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        ZStack {
            splitView

            // The preview takes over the whole window rather than opening a
            // sheet, so the image gets every pixel available when deciding
            // whether to keep it.
            if let wallpaper = selection {
                PreviewPane(items: viewerItems, selected: wallpaper) {
                    withAnimation(Tokens.normal) { selection = nil }
                }
                .environment(store)
                // No ignoresSafeArea here: it let the pane lay out against the
                // screen rather than the window, so the inspector ran off the
                // right edge and the chrome off the left. The title bar area is
                // handled by hiding the toolbar instead.
                .clipped()
                .transition(.opacity)
                .zIndex(1)
            }
        }
        // The toolbar is an NSToolbar living in the window's title bar, so it
        // renders above any SwiftUI overlay whatever its zIndex — it has to be
        // hidden, not covered. The content is dropped as well as the bar: a
        // hidden bar that still holds items left it half-drawn.
        .toolbar(selection == nil ? .automatic : .hidden, for: .windowToolbar)
        // Previewing collapses the sidebar so a zoomed image gets the whole
        // window instead of running into it.
        .onChange(of: selection?.id) { _, id in
            withAnimation(Tokens.normal) {
                columnVisibility = id == nil ? .automatic : .detailOnly
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
                .background(.background.opacity(0.35))
                .background(.ultraThinMaterial)     // vibrancy behind the content pane
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if store.isSelecting { selectionBar }
                        statusBar
                    }
                }
                .overlay(alignment: .top) { errorBanner }
        }
        .background(WindowBackdrop(wallpaper: store.current))
        .animation(Tokens.normal, value: section)
        .onReceive(NotificationCenter.default.publisher(for: .lumenShuffle)) { _ in store.shuffleNow() }
        .onReceive(NotificationCenter.default.publisher(for: .lumenReload)) { _ in
            Task { await store.search() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumenUndo)) { _ in
            store.undoWallpaper()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumenBack)) { _ in
            guard let previous = store.goBack(from: here) else { return }
            apply(previous)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lumenForward)) { _ in
            guard let next = store.goForward(from: here) else { return }
            apply(next)
        }
        // Opening an author or tag page is a place too, not just a pane change.
        .onChange(of: store.focus) { old, new in
            guard old == nil, new != nil else { return }
            store.recordDestination(.init(pane: section.rawValue, focus: nil))
        }
        .onChange(of: section) { old, new in
            store.recordDestination(.init(pane: old.rawValue, focus: store.focus))
            // Picking a sidebar item means leaving whatever was in focus, and
            // a selection made against a list you can no longer see.
            if store.focus != nil { store.closeFocus() }
            if store.isSelecting { store.setSelecting(false) }
            // Toplist is the same grid with a different sort — ask the core for it.
            guard new == .toplist, store.filters.sorting != .toplist else { return }
            store.filters.sorting = .toplist
            Task { await store.search() }
        }
    }

    /// Where the app is right now, for the navigation stack.
    private var here: Store.Destination {
        .init(pane: section.rawValue, focus: store.focus)
    }

    private func apply(_ destination: Store.Destination) {
        guard let pane = Section(rawValue: destination.pane) else { return }
        withAnimation(Tokens.normal) { section = pane }
    }

    /// What ← and → step through, which depends on the pane in view.
    private var viewerItems: [Wallpaper] {
        if store.focus != nil { return store.focusWallpapers }
        return section == .favorites ? store.favorites : store.wallpapers
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            SwiftUI.Section("Library") {
                row(.browse); row(.toplist)
                row(.favorites, badge: store.favorites.count)
            }
            SwiftUI.Section("Local") {
                row(.downloads, badge: store.downloads.count)
                row(.collections, badge: store.collections.count)
                row(.folders, badge: store.libraryFolders.count)
            }
            SwiftUI.Section("System") {
                row(.displays, badge: store.displays.count)
                row(.schedule, badge: store.unseenMatches)
                row(.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 196, ideal: 216, max: 260)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    /// Menu-bar switch above the appearance picker, as the canvas draws it.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: Tokens.s2) {
            Divider()
            Toggle("Menu bar quick-set", isOn: Binding(
                get: { store.menuBarEnabled }, set: { store.menuBarEnabled = $0 }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))
                .padding(.horizontal, Tokens.s3)
            appearancePicker
        }
    }

    private func row(_ item: Section, badge: Int = 0) -> some View {
        NavigationLink(value: item) {
            Label(item.label, systemImage: item.symbol)
                .badge(badge > 0 ? badge : 0)
        }
    }

    private var appearancePicker: some View {
        Picker("", selection: Binding(get: { store.appearance }, set: { store.appearance = $0 })) {
            ForEach(Appearance.allCases) { appearance in
                Text(appearance.label).tag(appearance)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(Tokens.s3)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var content: some View {
        // An uploader, tag or uploader collection takes over the detail pane
        // and keeps its own results, so the search underneath is untouched.
        if store.focus != nil {
            FocusView(selection: $selection)
                .transition(.opacity.combined(with: .offset(y: 10)))
        } else {
            paneContent
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch section {
        case .browse, .toplist, .favorites:
            BrowseView(section: section, selection: $selection)
                .transition(.opacity.combined(with: .offset(y: 10)))
        case .collections: CollectionsView()
        case .folders: LibraryFolderView()
        case .downloads: DownloadsView()
        case .displays: DisplaysView()
        case .schedule: ScheduleView()
        case .settings: SettingsView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The title bar is reserved on every pane, and `showsTitle: false`
        // left it blank on the ones with no controls. The canvas draws the
        // title and subtitle there, so put them back.
        if selection == nil {
            ToolbarItem(placement: .navigation) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.barTitle)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // macOS draws a capsule behind a toolbar item; without this the
                // text sits hard against its edges.
                .padding(.horizontal, Tokens.s2)
                .padding(.vertical, 2)
            }
        }

        if section.isGrid && selection == nil {
            ToolbarItem(placement: .principal) {
                Picker("Layout", selection: Binding(get: { store.gridTheme }, set: { store.gridTheme = $0 })) {
                    ForEach(GridTheme.allCases) { theme in Text(theme.label).tag(theme) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }
            ToolbarItem {
                Button {
                    store.setSelecting(!store.isSelecting)
                } label: {
                    Label("Select", systemImage: store.isSelecting
                          ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help("Select several wallpapers to download or save at once")
            }
            ToolbarItem {
                Button { showFilters.toggle() } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                        .badge(store.filters.activeCount)
                }
                .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                    FiltersPopover { showFilters = false }
                        .environment(store)
                }
            }
        }
    }

    /// Failures used to be a single word in the status bar, so a Set or
    /// Download that did not work looked like nothing happening.
    @ViewBuilder
    private var errorBanner: some View {
        if let message = store.errorMessage {
            HStack(alignment: .top, spacing: Tokens.s2) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Tokens.s2)
                Button {
                    withAnimation(Tokens.quick) { store.errorMessage = nil }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Tokens.warning)
            .padding(.horizontal, Tokens.s3)
            .padding(.vertical, Tokens.s2)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: .rect(cornerRadius: Tokens.control))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.control)
                    .strokeBorder(Tokens.warning.opacity(0.35), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(Tokens.s3)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// What you can do with a selection. Sits above the status bar so it does
    /// not move the grid when it appears.
    private var selectionBar: some View {
        HStack(spacing: Tokens.s2) {
            Text(store.selectionCount == 0
                 ? "Select wallpapers"
                 : "\(store.selectionCount) selected")
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 96, alignment: .leading)

            Button("Select All") { store.selectAll(viewerItems) }
                .keyboardShortcut("a", modifiers: .command)
            Button("Deselect") { store.clearSelection() }
                .disabled(store.selectionCount == 0)

            Divider().frame(height: 16)

            Button {
                store.downloadSelected(from: viewerItems)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(store.selectionCount == 0)

            Button {
                store.favoriteSelected(from: viewerItems)
            } label: {
                Label("Favorite", systemImage: "heart")
            }
            .disabled(store.selectionCount == 0)

            if !store.collections.isEmpty {
                Menu {
                    ForEach(store.collections) { collection in
                        Button(collection.name) {
                            store.addSelectedToCollection(collection, from: viewerItems)
                        }
                    }
                } label: {
                    Label("Add to Collection", systemImage: "rectangle.stack.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(store.selectionCount == 0)
            }

            Spacer()

            Button("Done") { store.setSelecting(false) }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .controlSize(.small)
        .padding(.horizontal, Tokens.s3)
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var statusBar: some View {
        HStack(spacing: Tokens.s4) {
            Text(section == .favorites
                 ? "\(store.favorites.count) saved"
                 : "\(store.wallpapers.count) results · page \(store.page) of \(store.lastPage)")
            Text(store.errorMessage == nil ? "wallhaven v1" : "offline")
                .foregroundStyle(store.errorMessage == nil ? .secondary : Tokens.warning)
            Spacer()
            Text(store.rotationEnabled ? "rotating every \(store.rotationMinutes)m" : "rotation paused")
        }
        .font(.caption2Mono)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.s3)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var title: String {
        switch section {
        case .browse: "Browse"
        case .toplist: "Toplist"
        case .folders: "Folders"
        default: section.label
        }
    }

    private var subtitle: String {
        switch section {
        case .browse:
            store.filters.query.isEmpty ? "Wallhaven · all wallpapers" : "“\(store.filters.query)”"
        case .toplist: "Most favorited · past \(store.filters.topRange)"
        case .favorites: "\(store.favorites.count) saved"
        case .downloads: "\(store.downloads.filter { $0.state == .active }.count) active"
        case .collections: "\(store.collections.count) local collections"
        case .folders: store.libraryFolders.isEmpty
            ? "Wallpapers already on disk"
            : "\(store.libraryWallpapers.count) in \(store.libraryFolders.count) folders"
        case .displays: "\(store.displays.count) connected"
        case .schedule: store.rotationEnabled ? "Rotating automatically" : "Paused"
        case .settings: "Local preferences and API access"
        }
    }
}

/// The blurred current wallpaper behind the window — the app's own vibrancy layer.
struct WindowBackdrop: View {
    let wallpaper: Wallpaper?
    var body: some View {
        ZStack {
            if let wallpaper {
                CachedImage(url: wallpaper.thumb) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.clear }
                .blur(radius: 60)
                .saturation(1.2)
                .opacity(0.55)
                .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                .id(wallpaper.id)
            }
            Rectangle().fill(.background.opacity(0.4))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
