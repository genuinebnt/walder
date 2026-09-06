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
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
                .background(.background.opacity(0.35))
                .background(.ultraThinMaterial)     // vibrancy behind the content pane
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        }
        .background(WindowBackdrop(wallpaper: store.current))
        .animation(Tokens.normal, value: section)
        .sheet(item: $selection) { wallpaper in
            DetailSheet(wallpaper: wallpaper) { selection = nil }
                .environment(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .walderShuffle)) { _ in store.shuffleNow() }
        .onReceive(NotificationCenter.default.publisher(for: .walderReload)) { _ in
            Task { await store.search() }
        }
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
        .safeAreaInset(edge: .bottom) { appearancePicker }
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
                AsyncImage(url: wallpaper.thumb) { image in
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

extension View {
    /// Sugar for menu-command notifications.
    func onReceive(_ name: Notification.Name, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
    }
}

// note: `onReceive(_:perform:)` above resolves to SwiftUI's built-in overload.
