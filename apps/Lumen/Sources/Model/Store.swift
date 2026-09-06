import SwiftUI
import Observation
import IOKit.ps

/// App state. Every network, disk and database operation is delegated to the
/// Rust core through `LumenCore`; this type holds only what the views render.
@Observable
final class Store {
    // Browsing
    var filters: SearchFilters { didSet { rememberFilters() } }
    var wallpapers: [Wallpaper] = []
    var page = 1
    var lastPage = 1
    var isLoading = false
    var errorMessage: String?

    /// Wallhaven's pagination seed from the first page of a random sort. Later
    /// pages must carry it, or they re-roll and repeat results.
    private var searchSeed: String?

    // Library
    var favorites: [Wallpaper] = []
    var collections: [Collection] = []
    var downloads: [DownloadTask] = []

    // System
    var displays: [DisplayTarget] = WallpaperSetter.connectedDisplays()
    var current: Wallpaper?
    var recents: [Wallpaper] = []

    /// Every wallpaper the session has seen, so a download row can render its
    /// thumbnail without the core having to carry the whole record.
    private var known: [String: Wallpaper] = [:]

    // MARK: Preferences
    //
    // Plain stored properties, not @AppStorage. @AppStorage is a view-level
    // DynamicProperty and does not notify @Observable, so changing one of these
    // used to re-render nothing — the appearance picker needed a relaunch to
    // take effect. They persist through didSet instead.

    @ObservationIgnored private let defaults: UserDefaults

    var apiKey: String { didSet { save(apiKey, "apiKey"); pushPreferences() } }
    var downloadDirectory: String { didSet { save(downloadDirectory, "downloadDirectory"); pushPreferences() } }
    var maxParallel: Int { didSet { save(maxParallel, "maxParallel"); pushPreferences() } }
    var gridTheme: GridTheme { didSet { save(gridTheme.rawValue, "gridTheme") } }
    var appearance: Appearance { didSet { save(appearance.rawValue, "appearance") } }
    var rotationEnabled: Bool { didSet { save(rotationEnabled, "rotationEnabled"); rearmRotation() } }
    var rotationMinutes: Int { didSet { save(rotationMinutes, "rotationMinutes"); rearmRotation() } }
    var rotationSource: String { didSet { save(rotationSource, "rotationSource") } }
    var shuffle: Bool { didSet { save(shuffle, "shuffle") } }
    var preferLocalPreview: Bool { didSet { save(preferLocalPreview, "preferLocalPreview") } }
    var menuBarEnabled: Bool { didSet { save(menuBarEnabled, "menuBarEnabled") } }
    var wallpaperScope: WallpaperScope { didSet { save(wallpaperScope.rawValue, "wallpaperScope") } }
    var showPurityBorders: Bool { didSet { save(showPurityBorders, "showPurityBorders") } }
    var pauseOnBattery: Bool { didSet { save(pauseOnBattery, "pauseOnBattery"); rearmRotation() } }

    /// Saved filter sets, most recently created last.
    var presets: [FilterPreset] { didSet { saveJSON(presets, "filterPresets") } }

    private func save(_ value: Any?, _ key: String) { defaults.set(value, forKey: key) }

    private func saveJSON<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, _ key: String,
                                               from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // `object(forKey:)` distinguishes "never set" from "set to false", which
        // bool(forKey:) cannot — the defaults below are not all false.
        func bool(_ key: String, default fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        func int(_ key: String, default fallback: Int) -> Int {
            defaults.object(forKey: key) as? Int ?? fallback
        }

        apiKey = defaults.string(forKey: "apiKey") ?? ""
        downloadDirectory = defaults.string(forKey: "downloadDirectory") ?? ""
        maxParallel = int("maxParallel", default: 4)
        gridTheme = GridTheme(rawValue: defaults.string(forKey: "gridTheme") ?? "") ?? .comfortable
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        rotationEnabled = bool("rotationEnabled", default: true)
        rotationMinutes = int("rotationMinutes", default: 60)
        rotationSource = defaults.string(forKey: "rotationSource") ?? "Favorites"
        shuffle = bool("shuffle", default: true)
        preferLocalPreview = bool("preferLocalPreview", default: true)
        menuBarEnabled = bool("menuBarEnabled", default: true)
        wallpaperScope = WallpaperScope(rawValue: defaults.string(forKey: "wallpaperScope") ?? "")
            ?? .thisSpace
        showPurityBorders = bool("showPurityBorders", default: true)
        pauseOnBattery = bool("pauseOnBattery", default: false)
        presets = Self.loadJSON([FilterPreset].self, "filterPresets", from: defaults) ?? []

        // The filter set from last launch, so a tuned search survives a restart.
        filters = Self.loadJSON(SearchFilters.self, "lastFilters", from: defaults) ?? SearchFilters()
        didFinishInit = true
    }

    /// Records the current filters as the ones to restore next launch. Called
    /// from `filters.didSet`, so an edit survives even if no search follows.
    func rememberFilters() {
        guard didFinishInit else { return }
        saveJSON(filters, "lastFilters")
    }

    /// `didSet` does not fire during `init`, but `filters` is assigned there and
    /// this guards any future ordering change.
    @ObservationIgnored private var didFinishInit = false

    // MARK: Filter presets

    @MainActor
    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        withAnimation(Tokens.normal) {
            if let index = presets.firstIndex(where: { $0.name == trimmed }) {
                presets[index].filters = filters      // overwrite by name
            } else {
                presets.append(FilterPreset(name: trimmed, filters: filters))
            }
        }
    }

    @MainActor
    func applyPreset(_ preset: FilterPreset) {
        withAnimation(Tokens.normal) { filters = preset.filters }
        rememberFilters()
    }

    @MainActor
    func deletePreset(_ preset: FilterPreset) {
        withAnimation(Tokens.normal) { presets.removeAll { $0.id == preset.id } }
    }

    /// True once the Rust core has booted; the UI shows the reason if not.
    private(set) var coreReady = false

    // MARK: Boot

    @MainActor
    func boot() {
        coreReady = LumenCore.shared.start(apiKey: apiKey,
                                           downloadDirectory: downloadDirectory,
                                           maxParallel: maxParallel)
        if !coreReady {
            errorMessage = "Core did not start: \(LumenCore.shared.status)"
            return
        }
        LumenCore.shared.onDownloads = { [weak self] tasks in
            Task { @MainActor in self?.applyDownloads(tasks) }
        }
        downloads = LumenCore.shared.downloadsSnapshot()
        reloadFavorites()
        reloadCollections()
        rearmRotation()
    }

    private func pushPreferences() {
        guard coreReady else { return }
        LumenCore.shared.setPreferences(apiKey: apiKey,
                                        downloadDirectory: downloadDirectory,
                                        maxParallel: maxParallel)
    }

    @MainActor
    private func applyDownloads(_ tasks: [DownloadTask]) {
        withAnimation(Tokens.quick) { downloads = tasks }
        // A finished download becomes the preferred preview source.
        for task in tasks where task.state == .done {
            guard let local = task.localFile else { continue }
            attachLocalFile(local, to: task.wallpaperId)
        }
    }

    private func attachLocalFile(_ local: URL, to wallpaperId: String) {
        if let index = wallpapers.firstIndex(where: { $0.id == wallpaperId }) {
            wallpapers[index].localFile = local
        }
        if let index = favorites.firstIndex(where: { $0.id == wallpaperId }) {
            favorites[index].localFile = local
        }
        known[wallpaperId]?.localFile = local
    }

    /// The wallpaper behind a download row, if the session has seen it.
    func wallpaper(for task: DownloadTask) -> Wallpaper? { known[task.wallpaperId] }

    private func remember(_ list: [Wallpaper]) {
        for wallpaper in list { known[wallpaper.id] = wallpaper }
    }

    // MARK: Search

    @MainActor
    func search(reset: Bool = true) async {
        guard coreReady else { return }
        if reset {
            page = 1
            searchSeed = nil
            rememberFilters()
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await LumenCore.shared.search(filters, page: page, seed: searchSeed)
            lastPage = max(result.lastPage, 1)
            if let seed = result.seed, !seed.isEmpty { searchSeed = seed }
            wallpapers = reset ? result.wallpapers : wallpapers + result.wallpapers
            remember(result.wallpapers)
            errorMessage = nil
            if current == nil { current = wallpapers.first }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func loadNextPageIfNeeded(after wallpaper: Wallpaper) async {
        guard !isLoading, page < lastPage,
              wallpapers.suffix(6).contains(wallpaper) else { return }
        page += 1
        await search(reset: false)
    }

    /// Fills in what only the detail endpoint returns.
    ///
    /// `/search` omits `uploader` entirely and carries no tags, so the preview
    /// has to ask for the single wallpaper before it can show either.
    @MainActor
    func loadDetails(for wallpaper: Wallpaper) async {
        guard wallpaper.tags.isEmpty || wallpaper.uploader == nil else { return }
        guard let detailed = try? await LumenCore.shared.details(id: wallpaper.id) else { return }

        func merge(into target: inout Wallpaper) {
            if !detailed.tags.isEmpty { target.tags = detailed.tags }
            if let uploader = detailed.uploader { target.uploader = uploader }
            if !detailed.colors.isEmpty { target.colors = detailed.colors }
        }

        if let index = wallpapers.firstIndex(where: { $0.id == wallpaper.id }) {
            merge(into: &wallpapers[index])
        }
        if let index = favorites.firstIndex(where: { $0.id == wallpaper.id }) {
            merge(into: &favorites[index])
        }
        if var cached = known[wallpaper.id] {
            merge(into: &cached)
            known[wallpaper.id] = cached
        }
    }

    // MARK: Favorites

    func isFavorite(_ wallpaper: Wallpaper) -> Bool { favorites.contains { $0.id == wallpaper.id } }

    @MainActor
    func toggleFavorite(_ wallpaper: Wallpaper) {
        guard let nowFavorited = LumenCore.shared.toggleFavorite(wallpaper) else {
            errorMessage = "Could not save that wallpaper."
            return
        }
        withAnimation(Tokens.bouncy) {
            if nowFavorited {
                if !isFavorite(wallpaper) { favorites.append(wallpaper) }
            } else {
                favorites.removeAll { $0.id == wallpaper.id }
            }
        }
    }

    @MainActor
    func reloadFavorites() {
        let saved = LumenCore.shared.favorites()
        remember(saved)
        withAnimation(Tokens.normal) { favorites = saved }
    }

    // MARK: Collections

    @MainActor
    func reloadCollections() {
        let stored = LumenCore.shared.collections()
        for collection in stored { remember(collection.wallpapers) }
        withAnimation(Tokens.normal) { collections = stored }
    }

    @MainActor
    func createCollection(named name: String, seeding seedFromFavorites: Bool = false) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let created = LumenCore.shared.createCollection(named: name) else {
            errorMessage = "Could not create that collection."
            return
        }
        if seedFromFavorites {
            for wallpaper in favorites {
                _ = LumenCore.shared.setCollectionMember(collectionID: created.id,
                                                         wallpaperID: wallpaper.id,
                                                         member: true)
            }
        }
        reloadCollections()
    }

    @MainActor
    func deleteCollection(_ collection: Collection) {
        LumenCore.shared.deleteCollection(id: collection.id)
        reloadCollections()
    }

    func isMember(_ wallpaper: Wallpaper, of collection: Collection) -> Bool {
        collection.wallpapers.contains { $0.id == wallpaper.id }
    }

    @MainActor
    func setMembership(_ wallpaper: Wallpaper, of collection: Collection, member: Bool) {
        // Membership joins against the wallpaper cache, which every searched
        // wallpaper is already in; the core rejects anything it cannot resolve.
        guard LumenCore.shared.setCollectionMember(collectionID: collection.id,
                                                   wallpaperID: wallpaper.id,
                                                   member: member) else {
            errorMessage = "Could not update \(collection.name)."
            return
        }
        reloadCollections()
    }

    // MARK: Downloads

    @MainActor
    func download(_ wallpaper: Wallpaper) {
        guard coreReady else { return }
        guard !downloads.contains(where: { $0.wallpaperId == wallpaper.id }) else { return }
        known[wallpaper.id] = wallpaper
        Task {
            do {
                try await LumenCore.shared.download(id: wallpaper.id,
                                                    url: wallpaper.path.absoluteString,
                                                    filename: wallpaper.filename)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    func clearFinished() { LumenCore.shared.clearFinishedDownloads() }

    @MainActor
    func retryFailed() {
        let failed = downloads.filter { $0.state == .failed }
        for task in failed {
            guard let wallpaper = known[task.wallpaperId] else { continue }
            Task {
                try? await LumenCore.shared.download(id: wallpaper.id,
                                                     url: wallpaper.path.absoluteString,
                                                     filename: wallpaper.filename)
            }
        }
    }

    // MARK: Applying

    /// The core materialises the file first — `NSWorkspace` only takes local URLs.
    @MainActor
    func setWallpaper(_ wallpaper: Wallpaper,
                      on display: DisplayTarget? = nil,
                      scope: WallpaperScope? = nil) {
        withAnimation(Tokens.normal) {
            current = wallpaper
            recents = ([wallpaper] + recents.filter { $0.id != wallpaper.id }).prefix(6).map { $0 }
            if let display, let index = displays.firstIndex(of: display) {
                displays[index].wallpaper = wallpaper
            } else {
                for index in displays.indices { displays[index].wallpaper = wallpaper }
            }
        }
        known[wallpaper.id] = wallpaper

        Task {
            let fit = display?.fit ?? .fill
            let screen = display.flatMap { target in
                NSScreen.screens.first { $0.localizedName == target.name }
            }
            do {
                let local = try await LumenCore.shared.ensureLocal(
                    url: wallpaper.path.absoluteString,
                    filename: wallpaper.filename)
                attachLocalFile(local, to: wallpaper.id)

                // The visible Space is always set through the supported API;
                // "All Spaces" additionally rewrites the system store, and
                // falls back to the single-Space result if that is refused.
                try WallpaperSetter.apply(fileURL: local, to: screen, fit: fit)

                // Sending to one display is a per-display choice, so it stays
                // on the current Space regardless of the default scope.
                let effective = scope ?? (display == nil ? wallpaperScope : .thisSpace)
                if effective == .allSpaces {
                    do {
                        try SpacesWallpaper.applyEverywhere(fileURL: local)
                    } catch {
                        errorMessage = "Set on this Space only — \(error.localizedDescription)"
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    func shuffleNow() {
        let pool: [Wallpaper]
        switch rotationSource {
        case "Downloads": pool = downloads.filter { $0.state == .done }.compactMap { known[$0.wallpaperId] }
        case "Collection": pool = collections.flatMap(\.wallpapers)
        default: pool = favorites.isEmpty ? wallpapers : favorites
        }
        guard let pick = shuffle ? pool.randomElement() : pool.first else { return }
        setWallpaper(pick)
    }

    // MARK: Rotation

    @ObservationIgnored private var rotationTimer: Timer?

    /// Re-arms the rotation timer. Every schedule control calls into this, so
    /// changing an interval or pausing takes effect immediately.
    func rearmRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard rotationEnabled else { return }

        let interval = TimeInterval(max(rotationMinutes, 1) * 60)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.rotationEnabled else { return }
                if self.pauseOnBattery && Self.onBattery { return }
                self.shuffleNow()
            }
        }
    }

    /// True when the machine is running from the internal battery.
    private static var onBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { entry in
            guard let info = IOPSGetPowerSourceDescription(blob, entry)?
                .takeUnretainedValue() as? [String: Any],
                  let state = info[kIOPSPowerSourceStateKey] as? String
            else { return false }
            return state == kIOPSBatteryPowerValue
        }
    }

    // MARK: Preferences

    /// Set for a few seconds after an explicit save, so Settings can confirm.
    var savedConfirmation = false

    @MainActor
    func savePreferences() {
        LumenCore.shared.setPreferences(apiKey: apiKey,
                                        downloadDirectory: downloadDirectory,
                                        maxParallel: maxParallel)
        rearmRotation()
        withAnimation(Tokens.quick) { savedConfirmation = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(Tokens.normal) { savedConfirmation = false }
        }
    }

    // MARK: Selection
    //
    // Bulk actions run through the core in one transaction rather than a call
    // per wallpaper, so filing a page of results is one commit, not twenty-four.

    /// True while the grid is in select mode; tiles then select rather than open.
    var isSelecting = false
    /// Ids of the selected wallpapers.
    var selected: Set<String> = []

    var selectionCount: Int { selected.count }

    @MainActor
    func setSelecting(_ on: Bool) {
        withAnimation(Tokens.quick) {
            isSelecting = on
            if !on { selected.removeAll() }
        }
    }

    func isSelected(_ wallpaper: Wallpaper) -> Bool { selected.contains(wallpaper.id) }

    @MainActor
    func toggleSelection(_ wallpaper: Wallpaper) {
        withAnimation(Tokens.quick) {
            if selected.contains(wallpaper.id) {
                selected.remove(wallpaper.id)
            } else {
                selected.insert(wallpaper.id)
                known[wallpaper.id] = wallpaper
            }
        }
    }

    @MainActor
    func selectAll(_ wallpapers: [Wallpaper]) {
        remember(wallpapers)
        withAnimation(Tokens.quick) { selected = Set(wallpapers.map(\.id)) }
    }

    @MainActor
    func clearSelection() {
        withAnimation(Tokens.quick) { selected.removeAll() }
    }

    /// The selected wallpapers, in the order they appear in `list`.
    func selectedWallpapers(from list: [Wallpaper]) -> [Wallpaper] {
        let inList = list.filter { selected.contains($0.id) }
        guard inList.count < selected.count else { return inList }
        // Something selected in another pane is still worth acting on.
        let missing = selected.subtracting(inList.map(\.id))
        return inList + missing.compactMap { known[$0] }
    }

    @MainActor
    func downloadSelected(from list: [Wallpaper]) {
        let picked = selectedWallpapers(from: list)
        guard !picked.isEmpty else { return }
        remember(picked)
        let items = picked
            .filter { wallpaper in !downloads.contains { $0.wallpaperId == wallpaper.id } }
            .map { (id: $0.id, url: $0.path.absoluteString, filename: $0.filename) }
        guard !items.isEmpty else { return }
        Task {
            do {
                try await LumenCore.shared.download(items)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    func favoriteSelected(from list: [Wallpaper], favorited: Bool = true) {
        let picked = selectedWallpapers(from: list)
        guard !picked.isEmpty else { return }
        let changed = LumenCore.shared.setFavorites(ids: picked.map(\.id), favorited: favorited)
        if changed == 0 && favorited {
            errorMessage = "Those wallpapers are already saved."
        }
        reloadFavorites()
    }

    @MainActor
    func addSelectedToCollection(_ collection: Collection, from list: [Wallpaper]) {
        let picked = selectedWallpapers(from: list)
        guard !picked.isEmpty else { return }
        let changed = LumenCore.shared.addToCollection(id: collection.id, ids: picked.map(\.id))
        if changed == 0 {
            errorMessage = "Nothing was added to \(collection.name)."
        }
        reloadCollections()
    }

    // MARK: Fitting

    /// How this wallpaper sits on a display, in that display's real pixels.
    func fit(_ wallpaper: Wallpaper, on display: DisplayTarget? = nil) -> DisplayFit {
        let parts = wallpaper.resolution.split(separator: "x")
        let image = CGSize(width: Double(parts.first ?? "0") ?? 0,
                           height: Double(parts.last ?? "0") ?? 0)
        let screen = display.flatMap { target in
            NSScreen.screens.first { $0.localizedName == target.name }
        }
        let size = screen.map(WallpaperFitter.pixelSize) ?? WallpaperFitter.mainPixelSize
        return DisplayFit(image: image, display: size)
    }

    /// Crops and scales a copy to the display's exact pixels, then sets it.
    ///
    /// Wallhaven has no alternate-resolution download, so this is the only way
    /// to get a pixel-exact wallpaper out of a file whose shape does not match.
    @MainActor
    func setFittedWallpaper(_ wallpaper: Wallpaper, on display: DisplayTarget? = nil) {
        let screen = display.flatMap { target in
            NSScreen.screens.first { $0.localizedName == target.name }
        }
        let size = screen.map(WallpaperFitter.pixelSize) ?? WallpaperFitter.mainPixelSize

        Task {
            do {
                let source = try await LumenCore.shared.ensureLocal(
                    url: wallpaper.path.absoluteString,
                    filename: wallpaper.filename)
                let directory = URL(filePath: LumenCore.shared.downloadDirectory)
                    .appending(path: "Fitted")
                let fitted = try WallpaperFitter.render(source, to: size, in: directory)

                withAnimation(Tokens.normal) {
                    current = wallpaper
                    recents = ([wallpaper] + recents.filter { $0.id != wallpaper.id })
                        .prefix(6).map { $0 }
                    if let display, let index = displays.firstIndex(of: display) {
                        displays[index].wallpaper = wallpaper
                    } else {
                        for index in displays.indices { displays[index].wallpaper = wallpaper }
                    }
                }
                try WallpaperSetter.apply(fileURL: fitted, to: screen, fit: .fill)
                if wallpaperScope == .allSpaces, display == nil {
                    try? SpacesWallpaper.applyEverywhere(fileURL: fitted)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Searches for wallpapers that actually fit this display: the same subject
    /// as `wallpaper`, at or above the display's native resolution.
    @MainActor
    func findFittingWallpapers(like wallpaper: Wallpaper) {
        let size = WallpaperFitter.mainPixelSize
        let names = wallpaper.tagRefs.isEmpty ? wallpaper.tags : wallpaper.tagRefs.map(\.name)

        var next = SearchFilters()
        next.categories = filters.categories
        next.purity = filters.purity
        next.sorting = names.isEmpty ? .toplist : .relevance
        next.query = names.prefix(2).map { "+\($0)" }.joined(separator: " ")
        next.mode = .atLeast
        next.resolution = "\(Int(size.width))x\(Int(size.height))"
        // Ratio is what actually removes the black bars; resolution alone does
        // not stop a 21:9 image being cropped on a 16:10 screen.
        next.ratios = [ratioLabel(for: size)]
        filters = next
        Task { await search() }
    }

    /// Nearest ratio Wallhaven understands for a display of this shape.
    private func ratioLabel(for size: CGSize) -> String {
        let target = size.width / max(size.height, 1)
        let known: [(String, Double)] = [
            ("16x9", 16.0 / 9), ("16x10", 16.0 / 10), ("21x9", 21.0 / 9),
            ("4x3", 4.0 / 3), ("1x1", 1), ("9x16", 9.0 / 16), ("10x16", 10.0 / 16)
        ]
        return known.min { abs($0.1 - target) < abs($1.1 - target) }?.0 ?? "16x9"
    }

    /// Searches for wallpapers like this one, from its own tags and palette.
    ///
    /// Wallhaven has no similarity endpoint, so this is the closest thing it
    /// supports: an AND of the strongest tags, narrowed to the dominant colour.
    /// Category and purity carry over so results stay inside what the user
    /// already said they want to see.
    @MainActor
    func findSimilar(to wallpaper: Wallpaper) {
        let names = wallpaper.tagRefs.isEmpty ? wallpaper.tags : wallpaper.tagRefs.map(\.name)
        var next = SearchFilters()
        next.categories = filters.categories
        next.purity = filters.purity
        next.resolution = filters.resolution
        next.sorting = names.isEmpty ? .toplist : .relevance
        // Three tags is enough to be specific without returning nothing.
        next.query = names.prefix(3).map { "+\($0)" }.joined(separator: " ")
        next.color = wallpaper.colors.first
        filters = next
        Task { await search() }
    }

    // MARK: Focused browsing
    //
    // An uploader's work, one tag, or one of an uploader's collections. These
    // keep their own results so opening an author page does not throw away the
    // search the user was in the middle of.

    enum Focus: Equatable {
        case uploader(String)
        case tag(TagRef)
        case uploaderCollection(username: String, collection: UploaderCollection)

        var title: String {
            switch self {
            case .uploader(let name): name
            case .tag(let ref): "#\(ref.name)"
            case .uploaderCollection(_, let collection): collection.label
            }
        }
    }

    var focus: Focus?
    var focusWallpapers: [Wallpaper] = []
    var focusPage = 1
    var focusLastPage = 1
    var isLoadingFocus = false
    var focusTotal = 0

    /// Extra context for the pane: an uploader's collections, or a tag's record.
    var uploaderCollections: [UploaderCollection] = []
    var tagInfo: TagInfo?

    @MainActor
    func showUploader(_ name: String) async {
        beginFocus(.uploader(name))
        // Public collections are a bonus; a failure there must not hold up the
        // wallpapers, so it runs alongside rather than before.
        async let collections = try? await LumenCore.shared.uploaderCollections(username: name)
        await loadFocus(reset: true)
        uploaderCollections = await collections ?? []
    }

    @MainActor
    func showTag(_ ref: TagRef) async {
        beginFocus(.tag(ref))
        async let record = try? await LumenCore.shared.tagInfo(id: ref.id)
        await loadFocus(reset: true)
        tagInfo = await record
    }

    @MainActor
    func showUploaderCollection(_ collection: UploaderCollection, of username: String) async {
        beginFocus(.uploaderCollection(username: username, collection: collection))
        await loadFocus(reset: true)
    }

    /// Clears the pane and records what is now in focus. The caller loads.
    @MainActor
    private func beginFocus(_ next: Focus) {
        withAnimation(Tokens.normal) {
            focus = next
            focusWallpapers = []
            focusPage = 1
            focusLastPage = 1
            focusTotal = 0
            if case .uploader = next {} else { uploaderCollections = [] }
            if case .tag = next {} else { tagInfo = nil }
        }
    }

    @MainActor
    func closeFocus() {
        withAnimation(Tokens.normal) {
            focus = nil
            focusWallpapers = []
            uploaderCollections = []
            tagInfo = nil
        }
    }

    @MainActor
    func loadFocus(reset: Bool = false) async {
        guard coreReady, let focus else { return }
        if reset { focusPage = 1 }
        isLoadingFocus = true
        defer { isLoadingFocus = false }

        do {
            let page: SearchPage
            switch focus {
            case .uploader(let name):
                page = try await LumenCore.shared.search(query(prefix: "@", name), page: focusPage)
            case .tag(let ref):
                page = try await LumenCore.shared.search(query(prefix: "#", ref.name), page: focusPage)
            case .uploaderCollection(let username, let collection):
                page = try await LumenCore.shared.uploaderCollection(
                    username: username, id: collection.id, page: focusPage)
            }
            focusLastPage = max(page.lastPage, 1)
            focusTotal = page.total
            focusWallpapers = reset ? page.wallpapers : focusWallpapers + page.wallpapers
            remember(page.wallpapers)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Filters for a focused page.
    ///
    /// Only category and purity carry over — those are about what the user is
    /// willing to see. Resolution, ratio and colour do not: an uploader page
    /// should show that uploader's work, and inheriting a 4K-and-21:9 filter
    /// from the last search silently emptied it.
    private func query(prefix: String, _ value: String) -> SearchFilters {
        var scoped = SearchFilters()
        scoped.categories = filters.categories
        scoped.purity = filters.purity
        scoped.query = prefix + value
        scoped.sorting = .dateAdded
        return scoped
    }

    @MainActor
    func loadFocusNextPageIfNeeded(after wallpaper: Wallpaper) async {
        guard !isLoadingFocus, focusPage < focusLastPage,
              focusWallpapers.suffix(6).contains(wallpaper) else { return }
        focusPage += 1
        await loadFocus()
    }
}
