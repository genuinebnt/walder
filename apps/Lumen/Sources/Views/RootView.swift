import SwiftUI
import Combine

enum Section: String, Hashable, CaseIterable, Identifiable {
    case browse, toplist, favorites, downloads, collections, displays, schedule, settings
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .browse: "square.grid.2x2"
        case .toplist: "chart.bar"
        case .favorites: "heart"
        case .downloads: "arrow.down.circle"
        case .collections: "rectangle.stack"
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
                // The sidebar is a vibrancy region the split view draws itself,
                // so an overlay alone does not cover it — hence the collapse
                // below. This covers the title bar area the same way.
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(1)
            }
        }
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
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
                .overlay(alignment: .top) { errorBanner }
        }
        .background(WindowBackdrop(wallpaper: store.current))
        .animation(Tokens.normal, value: section)
        .onReceive(NotificationCenter.default.publisher(for: .lumenShuffle)) { _ in store.shuffleNow() }
        .onReceive(NotificationCenter.default.publisher(for: .lumenReload)) { _ in
            Task { await store.search() }
        }
        .onChange(of: section) { _, new in
            // Toplist is the same grid with a different sort — ask the core for it.
            guard new == .toplist, store.filters.sorting != .toplist else { return }
            store.filters.sorting = .toplist
            Task { await store.search() }
        }
    }

    /// What ← and → step through, which depends on the pane in view.
    private var viewerItems: [Wallpaper] {
        section == .favorites ? store.favorites : store.wallpapers
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
            }
            SwiftUI.Section("System") {
                row(.displays, badge: store.displays.count)
                row(.schedule); row(.settings)
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
        switch section {
        case .browse, .toplist, .favorites:
            BrowseView(section: section, selection: $selection)
                .transition(.opacity.combined(with: .offset(y: 10)))
        case .collections: CollectionsView()
        case .downloads: DownloadsView()
        case .displays: DisplaysView()
        case .schedule: ScheduleView()
        case .settings: SettingsView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if section.isGrid {
            ToolbarItem(placement: .principal) {
                Picker("Layout", selection: Binding(get: { store.gridTheme }, set: { store.gridTheme = $0 })) {
                    ForEach(GridTheme.allCases) { theme in Text(theme.label).tag(theme) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
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
