import SwiftUI
import Observation
import IOKit.ps
import Vision

/// App state. Every network, disk and database operation is delegated to the
/// Rust core through `LumenCore`; this type holds only what the views render.
@Observable
final class Store {
    // Browsing
    var filters: SearchFilters { didSet { rememberFilters() } }
    var wallpapers: [Wallpaper] = []
    var page = 1
    var lastPage = 1
    /// What Wallhaven says the search matches in total.
    var totalResults = 0
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

    /// Wallpapers already on disk, so results can say so before you re-download
    /// something you have. Refreshed from the download directory rather than a
    /// table, so it stays right when files are moved or deleted outside the app.
    private(set) var downloadedIDs: Set<String> = []

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
    var rotationSource: RotationSource { didSet { save(rotationSource.key, "rotationSourceKey") } }
    /// How many results a saved filter draws from before picking one.
    var rotationPoolSize: Int { didSet { save(rotationPoolSize, "rotationPoolSize") } }
    var shuffle: Bool { didSet { save(shuffle, "shuffle") } }
    var preferLocalPreview: Bool { didSet { save(preferLocalPreview, "preferLocalPreview") } }
    var menuBarEnabled: Bool { didSet { save(menuBarEnabled, "menuBarEnabled") } }
    var wallpaperScope: WallpaperScope { didSet { save(wallpaperScope.rawValue, "wallpaperScope") } }
    var showPurityBorders: Bool { didSet { save(showPurityBorders, "showPurityBorders") } }
    /// Hides results that would have to be upscaled on this display.
    var hideBelowDisplay: Bool { didSet { save(hideBelowDisplay, "hideBelowDisplay") } }
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
        rotationPoolSize = int("rotationPoolSize", default: 100)
        // Falls back to the old three-choice string so an existing setting is
        // not silently reset to Favorites.
        rotationSource = (defaults.string(forKey: "rotationSourceKey").flatMap(RotationSource.init(key:)))
            ?? RotationSource.fromLegacy(defaults.string(forKey: "rotationSource") ?? "Favorites")
        shuffle = bool("shuffle", default: true)
        preferLocalPreview = bool("preferLocalPreview", default: true)
        menuBarEnabled = bool("menuBarEnabled", default: true)
        wallpaperScope = WallpaperScope(rawValue: defaults.string(forKey: "wallpaperScope") ?? "")
            ?? .thisSpace
        showPurityBorders = bool("showPurityBorders", default: true)
        hideBelowDisplay = bool("hideBelowDisplay", default: false)
        pauseOnBattery = bool("pauseOnBattery", default: false)
        presets = Self.loadJSON([FilterPreset].self, "filterPresets", from: defaults) ?? []
        radarMinutes = int("radarMinutes", default: 180)
        radarEnabled = bool("radarEnabled", default: false)
        followsAppearance = bool("followsAppearance", default: false)
        lightWallpaper = Self.loadJSON(Wallpaper?.self, "lightWallpaper", from: defaults) ?? nil
        darkWallpaper = Self.loadJSON(Wallpaper?.self, "darkWallpaper", from: defaults) ?? nil

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
        refreshDownloadedIDs()
        reloadLibrary()
        reloadHistory()
        reloadSubscriptions()
        rearmRadar()
        reloadSpaces()
        Task { await backfillSidecars() }
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
        // A finished download becomes the preferred preview source, and adds
        // to what the grid marks as already held.
        for task in tasks where task.state == .done {
            guard let local = task.localFile else { continue }
            let isNew = !downloadedIDs.contains(task.wallpaperId)
            attachLocalFile(local, to: task.wallpaperId)
            downloadedIDs.insert(task.wallpaperId)
            if isNew { Task { await tagOnDisk(task.wallpaperId, at: local) } }
        }
        // A finished download should be browsable in Folders straight away,
        // not only after a relaunch.
        if tasks.contains(where: { $0.state == .done }) { scheduleDownloadRefresh() }
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

    @ObservationIgnored private var downloadRefresh: Task<Void, Never>?

    /// Re-indexes the download folder shortly after downloads settle, rather
    /// than once per finished file in a batch.
    @MainActor
    private func scheduleDownloadRefresh() {
        downloadRefresh?.cancel()
        downloadRefresh = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            try? await LumenCore.shared.refreshDownloads()
            reloadLibrary()
        }
    }

    /// Re-reads what is on disk. Cheap: one directory listing.
    @MainActor
    func refreshDownloadedIDs() {
        guard coreReady else { return }
        downloadedIDs = LumenCore.shared.downloadedIDs()
    }

    /// True when this wallpaper is already in the download directory.
    func isDownloaded(_ wallpaper: Wallpaper) -> Bool { downloadedIDs.contains(wallpaper.id) }

    /// Writes the wallpaper's tags and origin into the file, so Spotlight and
    /// Finder can find it without Lumen running.
    ///
    /// Tags only come from the detail endpoint, so a wallpaper downloaded
    /// straight from search results has none yet and is asked for here.
    @MainActor
    private func tagOnDisk(_ wallpaperId: String, at file: URL) async {
        guard var wallpaper = known[wallpaperId] else { return }
        if wallpaper.tags.isEmpty,
           let detailed = try? await LumenCore.shared.details(id: wallpaperId) {
            wallpaper.tags = detailed.tags
            known[wallpaperId] = wallpaper
        }
        WallpaperMetadata.write(tags: wallpaper.tags,
                                source: wallpaper.path,
                                pageURL: wallpaper.url,
                                to: file)
        // The full record too, so the file can still say what it is once it has
        // left this database — or this machine.
        var recorded = wallpaper
        recorded.localFile = file
        WallpaperMetadata.writeSidecar(recorded, for: file)
    }

    /// Writes records beside downloads that predate sidecars.
    ///
    /// A file downloaded by an earlier build has nothing to read, and its id is
    /// recoverable from the name Lumen gave it — so the record can be restored
    /// from the cache rather than re-fetched.
    @MainActor
    func backfillSidecars() async {
        let downloads = libraryWallpapers.filter {
            $0.filename.hasPrefix("wallhaven-")
                && WallpaperMetadata.sidecar(for: $0.url) == nil
        }
        guard !downloads.isEmpty else { return }

        let byID = Dictionary(grouping: downloads) { local in
            local.filename
                .replacingOccurrences(of: "wallhaven-", with: "")
                .split(separator: ".").first.map(String.init) ?? ""
        }
        let records = LumenCore.shared.cachedWallpapers(ids: Array(byID.keys).filter { !$0.isEmpty })
        guard !records.isEmpty else { return }

        await Task.detached(priority: .utility) {
            for record in records {
                for local in byID[record.id] ?? [] {
                    var stamped = record
                    stamped.localFile = local.url
                    WallpaperMetadata.writeSidecar(stamped, for: local.url)
                }
            }
        }.value
    }

    /// Wallhaven's record for a local file, when it was downloaded by Lumen.
    func origin(of wallpaper: LocalWallpaper) -> Wallpaper? {
        WallpaperMetadata.sidecar(for: wallpaper.url)
    }

    /// Searches from a local file's recorded metadata, switching to Browse.
    @MainActor
    func searchFromLocal(_ query: String) {
        localPreview = nil
        var next = SearchFilters()
        next.categories = filters.categories
        next.purity = filters.purity
        next.query = query
        filters = next
        requestedSection = "browse"
        Task { await search() }
    }

    /// A pane asking the shell to switch panes.
    var requestedSection: String?

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
            forgetScroll(for: "browse")
            // A new search is a new set of results; any taste ordering is gone.
            tasteRanked = false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await LumenCore.shared.search(filters, page: page, seed: searchSeed)
            lastPage = max(result.lastPage, 1)
            totalResults = result.total
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

    /// Ids of the favourites, so a grid of tiles is a set lookup each rather
    /// than a scan of the whole list each.
    @ObservationIgnored private var favoriteIDs: Set<String> = []

    func isFavorite(_ wallpaper: Wallpaper) -> Bool { favoriteIDs.contains(wallpaper.id) }

    @MainActor
    func toggleFavorite(_ wallpaper: Wallpaper) {
        guard let nowFavorited = LumenCore.shared.toggleFavorite(wallpaper) else {
            errorMessage = "Could not save that wallpaper."
            return
        }
        withAnimation(Tokens.bouncy) {
            if nowFavorited {
                if !isFavorite(wallpaper) { favorites.append(wallpaper) }
                favoriteIDs.insert(wallpaper.id)
            } else {
                favorites.removeAll { $0.id == wallpaper.id }
                favoriteIDs.remove(wallpaper.id)
            }
        }
    }

    @MainActor
    func reloadFavorites() {
        let saved = LumenCore.shared.favorites()
        remember(saved)
        favoriteIDs = Set(saved.map(\.id))
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
                recordHistory(local, id: wallpaper.id, label: "wallhaven-\(wallpaper.id)")

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

    /// Sets the next wallpaper from whatever the rotation source names.
    ///
    /// Async because a saved filter re-queries Wallhaven, and local folders
    /// take a different set path from Wallhaven wallpapers.
    @MainActor
    func shuffleNow() {
        Task { await rotate() }
    }

    @MainActor
    func rotate() async {
        switch rotationSource {
        case .folder(let id):
            let pool = libraryWallpapers.filter { id.isEmpty || $0.folderId == id }
            guard let pick = pickLocal(from: pool) else {
                errorMessage = "That folder has no wallpapers to rotate."
                return
            }
            setLocalWallpaper(pick)

        case .savedFilter(let id):
            guard let preset = presets.first(where: { $0.id == id }) else {
                errorMessage = "That saved filter no longer exists."
                return
            }
            let pool = await filterPool(preset.filters)
            guard let pick = pick(from: pool) else {
                errorMessage = "That saved filter returned nothing."
                return
            }
            remember(pool)
            setWallpaper(pick)

        default:
            guard let pick = pick(from: rotationPool()) else { return }
            setWallpaper(pick)
        }
    }

    /// The top `rotationPoolSize` results a filter matches, in its own order.
    ///
    /// Keeping the filter's sorting is the point: "top 100 of this search, pick
    /// one" is a different thing from "any result at random". Pages are fetched
    /// only until the pool is full, and never past the real last page.
    private func filterPool(_ filters: SearchFilters) async -> [Wallpaper] {
        var collected: [Wallpaper] = []
        var page = 1
        var lastPage = 1
        var seed: String?

        while collected.count < rotationPoolSize && page <= lastPage {
            guard let result = try? await LumenCore.shared.search(filters, page: page, seed: seed)
            else { break }
            lastPage = max(result.lastPage, 1)
            if let found = result.seed, !found.isEmpty { seed = found }
            guard !result.wallpapers.isEmpty else { break }
            collected += result.wallpapers
            page += 1
        }
        return Array(collected.prefix(rotationPoolSize))
    }

    /// Wallhaven wallpapers the current source offers.
    private func rotationPool() -> [Wallpaper] {
        switch rotationSource {
        case .downloads:
            downloads.filter { $0.state == .done }.compactMap { known[$0.wallpaperId] }
        case .collection(let id):
            id.isEmpty
                ? collections.flatMap(\.wallpapers)
                : collections.first { $0.id == id }?.wallpapers ?? []
        default:
            favorites.isEmpty ? wallpapers : favorites
        }
    }

    /// Picks the next wallpaper, avoiding what has been on the desktop lately.
    ///
    /// Without this a shuffle regularly lands on the wallpaper already showing,
    /// which reads as the rotation being broken.
    private func pick(from pool: [Wallpaper]) -> Wallpaper? {
        guard !pool.isEmpty else { return nil }
        guard shuffle else { return pool.first }
        let recent = Set(history.prefix(recentlyShownCount).compactMap(\.wallpaperId))
        let fresh = pool.filter { !recent.contains($0.id) }
        return (fresh.isEmpty ? pool : fresh).randomElement()
    }

    private func pickLocal(from pool: [LocalWallpaper]) -> LocalWallpaper? {
        guard !pool.isEmpty else { return nil }
        guard shuffle else { return pool.first }
        let recent = Set(history.prefix(recentlyShownCount).map(\.url.path))
        let fresh = pool.filter { !recent.contains($0.url.path) }
        return (fresh.isEmpty ? pool : fresh).randomElement()
    }

    /// How far back to look before repeating. Small enough that a short
    /// collection still rotates rather than running out of candidates.
    private var recentlyShownCount: Int { 8 }

    /// Every source the Schedule picker can offer. Naming them is the view's
    /// job, so the words a person reads live where the rest of the UI text does.
    var rotationSources: [RotationSource] {
        var options: [RotationSource] = [.favorites, .downloads]
        options += collections.map { .collection($0.id) }
        options += libraryFolders.map { .folder($0.id) }
        options += presets.map { .savedFilter($0.id) }
        return options
    }

    /// The name behind a source, for the view to label it with.
    func name(of source: RotationSource) -> String {
        switch source {
        case .collection(let id): collections.first { $0.id == id }?.name ?? "Collection"
        case .folder(let id): libraryFolders.first { $0.id == id }?.name ?? "Folder"
        case .savedFilter(let id): presets.first { $0.id == id }?.name ?? "Filter"
        default: ""
        }
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

    // MARK: Local aspect ratios
    //
    // The grid needs each image's shape to lay out honestly. Reading a header
    // is fast but not free, and doing it for two thousand tiles during layout
    // is not acceptable — so they are read once, off the main thread, and
    // cached.

    private var aspectRatios: [String: Double] = [:]

    /// Shape of a local wallpaper, 16:10 until its header has been read.
    func aspectRatio(of wallpaper: LocalWallpaper) -> Double {
        aspectRatios[wallpaper.path] ?? 16.0 / 10
    }

    /// Reads the shapes of whatever is on screen, in the background.
    @MainActor
    func loadAspectRatios(for wallpapers: [LocalWallpaper]) async {
        let missing = wallpapers.filter { aspectRatios[$0.path] == nil }
        guard !missing.isEmpty else { return }

        let measured = await Task.detached(priority: .utility) {
            missing.reduce(into: [String: Double]()) { found, wallpaper in
                guard let size = wallpaper.pixelSize, size.height > 0 else { return }
                found[wallpaper.path] = size.width / size.height
            }
        }.value

        guard !measured.isEmpty else { return }
        aspectRatios.merge(measured) { _, new in new }
    }

    // MARK: Library similarity
    //
    // Vision feature prints over the imported library. This is what finds the
    // same wallpaper at another resolution, and "more like this one" among
    // files you already have.

    /// What a duplicate scan looks at.
    enum DuplicateScope: String, CaseIterable, Identifiable {
        case thisFolder, includingNested, everything
        var id: String { rawValue }
        var label: String {
            switch self {
            case .thisFolder: "This folder"
            case .includingNested: "With nested"
            case .everything: "Everything"
            }
        }
    }

    var duplicateScope: DuplicateScope = .includingNested
    var isIndexingPrints = false
    var indexProgress: (done: Int, total: Int) = (0, 0)
    var duplicateGroups: [[LocalWallpaper]] = []
    var similarToSelection: [LocalWallpaper] = []

    /// The files a duplicate scan would consider, given the current scope.
    ///
    /// Scope matters because a nested import legitimately holds the same
    /// picture in a parent and a child folder, and whether that counts is the
    /// user's call, not ours.
    var duplicateCandidates: [LocalWallpaper] {
        switch duplicateScope {
        case .everything:
            libraryWallpapers
        case .includingNested:
            // This level and everything beneath it.
            libraryWallpapers.filter {
                browsePath.isEmpty || $0.subpath == browsePath
                    || $0.subpath.hasPrefix(browsePath + "/")
            }
        case .thisFolder:
            libraryWallpapers.filter { $0.subpath == browsePath }
        }
    }

    /// How many library files still have no print.
    var unindexedCount: Int {
        let known = LumenCore.shared.printedPaths()
        return libraryWallpapers.filter { !known.contains($0.path) }.count
    }

    /// Computes prints for anything in the library that lacks one.
    ///
    /// Off the main actor, in batches, so a large folder does not freeze the
    /// UI or hold every print in memory at once.
    @MainActor
    func indexLibrary(_ scope: [LocalWallpaper]? = nil) async {
        guard coreReady, !isIndexingPrints else { return }
        isIndexingPrints = true
        defer { isIndexingPrints = false; indexProgress = (0, 0) }

        LumenCore.shared.prunePrints()
        let known = LumenCore.shared.printedPaths()
        let pending = (scope ?? libraryWallpapers).filter { !known.contains($0.path) }
        guard !pending.isEmpty else { return }
        indexProgress = (0, pending.count)

        // Batched so progress is visible and memory stays flat.
        for batch in stride(from: 0, to: pending.count, by: 25) {
            let slice = Array(pending[batch..<min(batch + 25, pending.count)])
            let computed = await Task.detached(priority: .utility) {
                slice.compactMap { wallpaper -> (path: String, data: Data, fileSize: Int)? in
                    guard let observation = ImagePrints.print(of: wallpaper.url),
                          let data = ImagePrints.encode(observation) else { return nil }
                    return (wallpaper.path, data, wallpaper.fileSize)
                }
            }.value
            _ = LumenCore.shared.storePrints(computed)
            indexProgress = (min(batch + 25, pending.count), pending.count)
        }
    }

    /// Loads every stored print, decoded and paired with its path.
    private func loadedPrints() async -> [(path: String, print: VNFeaturePrintObservation)] {
        let stored = LumenCore.shared.allPrints()
        return await Task.detached(priority: .userInitiated) {
            stored.compactMap { entry in
                guard let data = Data(base64Encoded: entry.print),
                      let observation = ImagePrints.decode(data) else { return nil }
                return (entry.path, observation)
            }
        }.value
    }

    /// Finds files that look like the same picture.
    @MainActor
    func findDuplicates() async {
        guard coreReady else { return }
        let candidates = duplicateCandidates
        guard !candidates.isEmpty else { return }
        await indexLibrary(candidates)
        isIndexingPrints = true
        defer { isIndexingPrints = false }

        // Compare only within the chosen scope, not the whole library.
        let wanted = Set(candidates.map(\.path))
        let prints = await loadedPrints().filter { wanted.contains($0.path) }
        let groups = await Task.detached(priority: .userInitiated) {
            ImagePrints.duplicateGroups(in: prints)
        }.value

        // Map paths back to what the grid renders, dropping anything no longer
        // in the library.
        let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0) })
        withAnimation(Tokens.normal) {
            duplicateGroups = groups.compactMap { group in
                let found = group.compactMap { byPath[$0] }
                return found.count > 1 ? found : nil
            }
        }
    }

    /// Files in the library most like this one.
    @MainActor
    func findSimilarInLibrary(to wallpaper: LocalWallpaper) async {
        guard coreReady else { return }
        await indexLibrary()

        let prints = await loadedPrints()
        guard let target = prints.first(where: { $0.path == wallpaper.path })?.print else {
            similarToSelection = []
            return
        }
        let nearest = await Task.detached(priority: .userInitiated) {
            ImagePrints.nearest(to: target, in: prints, excluding: wallpaper.path)
        }.value

        let byPath = Dictionary(uniqueKeysWithValues: libraryWallpapers.map { ($0.path, $0) })
        withAnimation(Tokens.normal) {
            similarToSelection = nearest.compactMap { byPath[$0.path] }
        }
    }

    // MARK: Trash

    /// Files moved to the Trash, kept so they can be put back.
    ///
    /// Deleting goes through the Trash rather than removing the file: a
    /// wallpaper library is not something to destroy on a mis-click, and macOS
    /// already has a place for "gone but recoverable".
    struct TrashedFiles {
        var originals: [URL]
        var inTrash: [URL]
        var describedAs: String
    }

    private(set) var lastTrashed: TrashedFiles?

    var canRestoreTrashed: Bool { lastTrashed != nil }

    /// Moves local wallpapers to the Trash and offers to put them back.
    @MainActor
    func trash(_ wallpapers: [LocalWallpaper]) {
        guard !wallpapers.isEmpty else { return }
        var originals: [URL] = []
        var landed: [URL] = []

        for wallpaper in wallpapers {
            var destination: NSURL?
            do {
                try FileManager.default.trashItem(at: wallpaper.url,
                                                  resultingItemURL: &destination)
                originals.append(wallpaper.url)
                if let destination { landed.append(destination as URL) }
                // The record beside it goes too, or it is left orphaned.
                WallpaperMetadata.removeSidecar(for: wallpaper.url)
            } catch {
                errorMessage = "Could not move \(wallpaper.filename) to the Trash: "
                    + error.localizedDescription
            }
        }

        guard !originals.isEmpty else { return }
        lastTrashed = TrashedFiles(
            originals: originals,
            inTrash: landed,
            describedAs: originals.count == 1
                ? originals[0].lastPathComponent
                : "\(originals.count) wallpapers")

        Task {
            try? await LumenCore.shared.rescanLibrary()
            reloadLibrary()
        }
    }

    /// Puts the last trashed files back where they came from.
    @MainActor
    func restoreTrashed() {
        guard let trashed = lastTrashed else { return }
        guard trashed.inTrash.count == trashed.originals.count else {
            errorMessage = "Those files cannot be put back automatically — "
                + "they are in the Trash."
            lastTrashed = nil
            return
        }

        var restored = 0
        for (source, destination) in zip(trashed.inTrash, trashed.originals) {
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                restored += 1
            } catch {
                errorMessage = "Could not put back \(destination.lastPathComponent): "
                    + error.localizedDescription
            }
        }

        lastTrashed = nil
        guard restored > 0 else { return }
        Task {
            try? await LumenCore.shared.rescanLibrary()
            reloadLibrary()
        }
    }

    @MainActor
    func forgetTrashed() { lastTrashed = nil }

    // MARK: Spaces

    var spaces: [SpacesWallpaper.Space] = []

    @MainActor
    func reloadSpaces() {
        spaces = SpacesWallpaper.spaces()
    }

    /// Sets a wallpaper on one Space, leaving every other alone.
    @MainActor
    func setWallpaper(_ wallpaper: Wallpaper, onSpace space: SpacesWallpaper.Space) {
        Task {
            do {
                let local = try await LumenCore.shared.ensureLocal(
                    url: wallpaper.path.absoluteString, filename: wallpaper.filename)
                attachLocalFile(local, to: wallpaper.id)
                try SpacesWallpaper.apply(fileURL: local, toSpace: space.uuid)
                recordHistory(local, id: wallpaper.id,
                              label: "wallhaven-\(wallpaper.id) (\(space.label))")
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    func setLocalWallpaper(_ wallpaper: LocalWallpaper, onSpace space: SpacesWallpaper.Space) {
        guard FileManager.default.fileExists(atPath: wallpaper.url.path) else {
            errorMessage = "\(wallpaper.filename) is no longer on disk."
            return
        }
        do {
            try SpacesWallpaper.apply(fileURL: wallpaper.url, toSpace: space.uuid)
            recordHistory(wallpaper.url, id: nil,
                          label: "\(wallpaper.filename) (\(space.label))")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Colour search

    /// Dominant colour per local file, so the library can be filtered by colour
    /// the way Wallhaven's own search can.
    private var dominantColours: [String: SystemAccent] = [:]
    var colourFilter: SystemAccent?
    var isReadingColours = false

    /// Reads dominant colours for whatever is on screen, in the background.
    @MainActor
    func loadColours(for wallpapers: [LocalWallpaper]) async {
        let missing = wallpapers.filter { dominantColours[$0.path] == nil }
        guard !missing.isEmpty, !isReadingColours else { return }
        isReadingColours = true
        defer { isReadingColours = false }

        let found = await Task.detached(priority: .utility) {
            missing.reduce(into: [String: SystemAccent]()) { result, wallpaper in
                guard let accent = Self.dominantAccent(of: wallpaper.url) else { return }
                result[wallpaper.path] = accent
            }
        }.value
        dominantColours.merge(found) { _, new in new }
    }

    /// Reduces an image to one pixel and names the nearest accent to it.
    ///
    /// The same seven-colour vocabulary the accent matcher uses, so "show me
    /// the green ones" means the same thing in both places.
    private nonisolated static func dominantAccent(of url: URL) -> SystemAccent? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32
              ] as CFDictionary) else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let hex = String(format: "%02x%02x%02x", pixel[0], pixel[1], pixel[2])
        return SystemAccent.nearest(toHex: hex)
    }

    func colour(of wallpaper: LocalWallpaper) -> SystemAccent? {
        dominantColours[wallpaper.path]
    }

    /// Applies the colour filter to a list of local files.
    func byColour(_ list: [LocalWallpaper]) -> [LocalWallpaper] {
        guard let colourFilter else { return list }
        return list.filter { dominantColours[$0.path] == colourFilter }
    }

    @MainActor
    func setColourFilter(_ accent: SystemAccent?) {
        withAnimation(Tokens.quick) { colourFilter = accent }
    }

    // MARK: Dropped files

    /// Accepts files or folders dropped onto the app.
    ///
    /// A folder is imported; images are copied into the download directory and
    /// indexed, so a wallpaper dragged from a browser or Finder joins the
    /// library the same way a download does.
    @MainActor
    func accept(_ urls: [URL]) async {
        var imported = 0
        var copied = 0

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            else { continue }

            if isDirectory.boolValue {
                await importFolder(at: url.path(percentEncoded: false))
                imported += 1
                continue
            }

            let extensions = ["jpg", "jpeg", "png", "heic", "webp", "tif", "tiff"]
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }

            let directory = URL(filePath: LumenCore.shared.downloadDirectory)
            let target = uniqueName(for: url.lastPathComponent, in: directory)
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: target)
                copied += 1
            } catch {
                errorMessage = "Could not add \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }

        if copied > 0 {
            try? await LumenCore.shared.refreshDownloads()
        }
        if copied > 0 || imported > 0 {
            reloadLibrary()
            requestedSection = "folders"
        }
    }

    /// Avoids overwriting a file that is already there.
    private func uniqueName(for filename: String, in directory: URL) -> URL {
        var candidate = directory.appending(path: filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appending(path: next)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    // MARK: Export and backup

    /// Everything worth keeping if the database is lost: what you saved, what
    /// you grouped, and what you asked to be watched.
    struct Backup: Codable {
        var favorites: [Wallpaper] = []
        var collections: [BackedUpCollection] = []
        var presets: [FilterPreset] = []
        var subscriptions: [BackedUpSubscription] = []
        var exportedAt = Date()

        struct BackedUpCollection: Codable {
            var name: String
            var wallpapers: [Wallpaper]
        }
        struct BackedUpSubscription: Codable {
            var query: String
            var label: String
            var minFavorites: Int
        }
    }

    @MainActor
    func makeBackup() -> Backup {
        Backup(favorites: favorites,
               collections: collections.map {
                   .init(name: $0.name, wallpapers: $0.wallpapers)
               },
               presets: presets,
               subscriptions: subscriptions.map {
                   .init(query: $0.query, label: $0.label, minFavorites: $0.minFavorites)
               })
    }

    @MainActor
    func exportBackup(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(makeBackup()).write(to: url, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Restores a backup, adding to what is there rather than replacing it.
    @MainActor
    func importBackup(from url: URL) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let backup = try? decoder.decode(Backup.self, from: data) else {
            errorMessage = "That is not a Lumen backup."
            return
        }

        // Favourites and collection members need a cached wallpaper to point
        // at, so the records travel in the backup and are re-cached on the way
        // in — restoring on a fresh install would otherwise find nothing.
        LumenCore.shared.cacheWallpapers(backup.favorites)
        LumenCore.shared.setFavorites(ids: backup.favorites.map(\.id), favorited: true)

        for collection in backup.collections {
            LumenCore.shared.cacheWallpapers(collection.wallpapers)
            createCollection(named: collection.name)
            guard let created = collections.first(where: { $0.name == collection.name })
            else { continue }
            LumenCore.shared.addToCollection(id: created.id,
                                             ids: collection.wallpapers.map(\.id))
        }

        for preset in backup.presets where !presets.contains(where: { $0.name == preset.name }) {
            presets.append(preset)
        }
        for subscription in backup.subscriptions {
            subscribe(to: subscription.query, label: subscription.label,
                      minFavorites: subscription.minFavorites)
        }

        reloadFavorites()
        reloadCollections()
        reloadSubscriptions()
        errorMessage = nil
    }

    // MARK: Auto-collections

    struct ProposedCollection: Identifiable {
        let id = UUID()
        var wallpapers: [LocalWallpaper]
        /// Named by example, because a feature print knows what things look
        /// like, not what they are.
        var suggestedName: String
    }

    var proposals: [ProposedCollection] = []
    var isClustering = false

    /// Groups the library by look and proposes collections to accept or reject.
    @MainActor
    func proposeCollections() async {
        guard coreReady else { return }
        let candidates = duplicateCandidates
        guard !candidates.isEmpty else { return }
        await indexLibrary(candidates)

        isClustering = true
        defer { isClustering = false }

        let wanted = Set(candidates.map(\.path))
        let prints = await loadedPrints().filter { wanted.contains($0.path) }
        let groups = await Task.detached(priority: .userInitiated) {
            ImagePrints.cluster(prints)
        }.value

        let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0) })
        withAnimation(Tokens.normal) {
            proposals = groups.compactMap { group in
                let found = group.compactMap { byPath[$0] }
                guard found.count >= 6 else { return nil }
                return ProposedCollection(wallpapers: found,
                                          suggestedName: proposedName(for: found))
            }
        }
    }

    /// A name from what the group has in common on disk — its folder, or its
    /// size. Honest about being a guess.
    private func proposedName(for group: [LocalWallpaper]) -> String {
        let folders = Set(group.map(\.subpath).filter { !$0.isEmpty })
        if folders.count == 1, let only = folders.first {
            return only.split(separator: "/").last.map(String.init) ?? "Group"
        }
        return "Group of \(group.count)"
    }

    /// Turns a proposal into a real collection.
    @MainActor
    func acceptProposal(_ proposal: ProposedCollection, named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Local files have no Wallhaven identity, so the collection records
        // them the only way it can: by importing them as favourites first.
        createCollection(named: trimmed)
        guard let created = collections.first(where: { $0.name == trimmed }) else {
            errorMessage = "Could not create \(trimmed)."
            return
        }
        for wallpaper in proposal.wallpapers {
            LumenCore.shared.setLibraryFavorite(id: wallpaper.id, favorite: true)
        }
        _ = created
        reloadLibrary()
        dismissProposal(proposal)
    }

    @MainActor
    func dismissProposal(_ proposal: ProposedCollection) {
        withAnimation(Tokens.quick) { proposals.removeAll { $0.id == proposal.id } }
    }

    @MainActor
    func clearProposals() {
        withAnimation(Tokens.quick) { proposals = [] }
    }

    // MARK: Taste ranking

    /// Ranks the loaded results by how close they sit to your favourites.
    ///
    /// Only re-orders what has already been fetched: Wallhaven cannot be asked
    /// for "my taste", so this works within the pages you have, not the
    /// catalogue.
    var isRankingByTaste = false
    var tasteRanked = false

    @MainActor
    func rankByTaste() async {
        guard coreReady, !favorites.isEmpty, !wallpapers.isEmpty else {
            errorMessage = favorites.isEmpty
                ? "Favourite a few wallpapers first — that is what taste is measured against."
                : nil
            return
        }
        isRankingByTaste = true
        defer { isRankingByTaste = false }

        // Thumbnails are already decoded for the grid, so printing them is
        // nearly free compared with fetching anything new.
        let references = await prints(for: favorites.prefix(24).map(\.thumb))
        guard !references.isEmpty else { return }
        let candidates = await prints(for: wallpapers.map(\.thumb))
        guard !candidates.isEmpty else { return }

        let scored = await Task.detached(priority: .userInitiated) {
            candidates.compactMap { entry -> (String, Float)? in
                ImagePrints.affinity(of: entry.value, to: references.map(\.value))
                    .map { (entry.key, $0) }
            }
        }.value

        let ranking = Dictionary(uniqueKeysWithValues: scored)
        withAnimation(Tokens.normal) {
            wallpapers.sort { a, b in
                (ranking[a.thumb.absoluteString] ?? .greatestFiniteMagnitude)
                    < (ranking[b.thumb.absoluteString] ?? .greatestFiniteMagnitude)
            }
            tasteRanked = true
        }
    }

    /// Prints for a set of thumbnails, decoded through the shared cache.
    private func prints(for urls: [URL]) async -> [String: VNFeaturePrintObservation] {
        var images: [(String, NSImage)] = []
        for url in urls {
            guard let image = await ImageCache.shared.image(for: url) else { continue }
            images.append((url.absoluteString, image))
        }
        return await Task.detached(priority: .userInitiated) {
            images.reduce(into: [String: VNFeaturePrintObservation]()) { found, entry in
                guard let cgImage = entry.1.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return }
                let request = VNGenerateImageFeaturePrintRequest()
                try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                if let print = request.results?.first as? VNFeaturePrintObservation {
                    found[entry.0] = print
                }
            }
        }.value
    }

    @MainActor
    func clearSimilarity() {
        withAnimation(Tokens.quick) {
            duplicateGroups = []
            similarToSelection = []
        }
    }

    // MARK: System accent

    /// The accent macOS would be set to for the wallpaper in view, if asked.
    func suggestedAccent(for wallpaper: Wallpaper) -> SystemAccent? {
        SystemAccent.nearest(toPalette: wallpaper.colors)
    }

    var canRestoreAccent: Bool { SystemAccent.canRestore() }

    @MainActor
    func matchSystemAccent(to wallpaper: Wallpaper) {
        guard let accent = suggestedAccent(for: wallpaper) else {
            errorMessage = "That wallpaper has no palette to match."
            return
        }
        SystemAccent.apply(accent)
    }

    @MainActor
    func restoreSystemAccent() { SystemAccent.restore() }

    // MARK: Tag radar
    //
    // Saved searches re-run on a timer. Notification Center is the nice
    // delivery, but it needs permission that an ad-hoc signed build may not
    // get — so the in-app badge is what the feature actually rests on.

    var subscriptions: [Subscription] = []
    var radarFindings: [RadarResult] = []
    var isCheckingRadar = false
    var radarMinutes: Int { didSet { save(radarMinutes, "radarMinutes"); rearmRadar() } }
    var radarEnabled: Bool { didSet { save(radarEnabled, "radarEnabled"); rearmRadar() } }

    /// Total matches waiting across every subscription.
    var unseenMatches: Int { subscriptions.reduce(0) { $0 + $1.unseen } }

    @ObservationIgnored private var radarTimer: Timer?

    @MainActor
    func reloadSubscriptions() {
        guard coreReady else { return }
        subscriptions = LumenCore.shared.subscriptions()
    }

    @MainActor
    func subscribe(to query: String, label: String? = nil, minFavorites: Int = 0) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard LumenCore.shared.subscribe(query: trimmed,
                                         label: label ?? trimmed,
                                         minFavorites: max(0, minFavorites)) else {
            errorMessage = "Could not save that subscription."
            return
        }
        reloadSubscriptions()
        rearmRadar()
        reloadSpaces()
        Task { await backfillSidecars() }
    }

    @MainActor
    func unsubscribe(_ subscription: Subscription) {
        LumenCore.shared.unsubscribe(id: subscription.id)
        radarFindings.removeAll { $0.id == subscription.id }
        reloadSubscriptions()
    }

    /// Opens a subscription's results as a search, and clears its badge.
    @MainActor
    func openSubscription(_ subscription: Subscription) {
        LumenCore.shared.markSubscriptionSeen(id: subscription.id)
        radarFindings.removeAll { $0.id == subscription.id }
        reloadSubscriptions()

        var next = SearchFilters()
        next.query = subscription.query
        next.sorting = .dateAdded
        filters = next
        Task { await search() }
    }

    @MainActor
    func checkRadar() async {
        guard coreReady, !subscriptions.isEmpty, !isCheckingRadar else { return }
        isCheckingRadar = true
        defer { isCheckingRadar = false }
        do {
            let found = try await LumenCore.shared.checkRadar()
            radarFindings = found
            reloadSubscriptions()
            if !found.isEmpty { RadarNotifier.announce(found) }
        } catch {
            // A failed check is not worth interrupting the user for; the next
            // one will try again.
            radarFindings = []
        }
    }

    /// Re-arms the background check. Every radar setting calls into this.
    func rearmRadar() {
        radarTimer?.invalidate()
        radarTimer = nil
        guard radarEnabled, !subscriptions.isEmpty else { return }

        let interval = TimeInterval(max(radarMinutes, 15) * 60)
        radarTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkRadar() }
        }
    }

    // MARK: Navigation history
    //
    // Where you have been, so ⌘[ and ⌘] work the way they do in a browser.
    // A destination is a pane plus whatever was in focus, since an author page
    // and the Browse pane behind it are different places.

    struct Destination: Equatable {
        let pane: String
        let focus: Focus?
    }

    private(set) var backStack: [Destination] = []
    private(set) var forwardStack: [Destination] = []
    /// Set while a back or forward step is being applied, so restoring a
    /// destination does not record itself as a new one.
    @ObservationIgnored private var isNavigating = false

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Records the place being left. Going somewhere new clears the forward
    /// stack, as it does in every browser.
    @MainActor
    func recordDestination(_ leaving: Destination) {
        guard !isNavigating else { return }
        guard backStack.last != leaving else { return }
        backStack.append(leaving)
        if backStack.count > 50 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    /// Returns the destination to restore, having pushed `current` forward.
    @MainActor
    func goBack(from current: Destination) -> Destination? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        isNavigating = true
        defer { isNavigating = false }
        applyFocus(previous.focus)
        return previous
    }

    @MainActor
    func goForward(from current: Destination) -> Destination? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        isNavigating = true
        defer { isNavigating = false }
        applyFocus(next.focus)
        return next
    }

    /// Restores the focused page a destination carries, reloading its results.
    @MainActor
    private func applyFocus(_ wanted: Focus?) {
        guard let wanted else {
            if focus != nil { closeFocus() }
            return
        }
        guard focus != wanted else { return }
        Task {
            switch wanted {
            case .uploader(let name): await showUploader(name)
            case .tag(let ref): await showTag(ref)
            case .uploaderCollection(let username, let collection):
                await showUploaderCollection(collection, of: username)
            }
        }
    }

    // MARK: History
    //
    // What has actually been on the desktop, so a wallpaper set an hour ago
    // can be found again and the last set can be undone.

    var history: [HistoryEntry] = []

    @MainActor
    func reloadHistory() {
        guard coreReady else { return }
        history = LumenCore.shared.history()
    }

    /// Called after every successful set.
    @MainActor
    private func recordHistory(_ file: URL, id: String?, label: String) {
        LumenCore.shared.recordHistory(wallpaperID: id,
                                       path: file.path(percentEncoded: false),
                                       label: label)
        reloadHistory()
    }

    /// True when there is something to go back to.
    var canUndoWallpaper: Bool { history.count > 1 }

    /// Puts back whatever was on the desktop before the current one.
    @MainActor
    func undoWallpaper() {
        guard history.count > 1 else { return }
        let previous = history[1]
        guard FileManager.default.fileExists(atPath: previous.url.path) else {
            errorMessage = "\(previous.label) is no longer on disk."
            LumenCore.shared.dropLatestHistory()
            reloadHistory()
            return
        }
        do {
            try WallpaperSetter.apply(fileURL: previous.url, to: nil, fit: .fill)
            if wallpaperScope == .allSpaces {
                try? SpacesWallpaper.applyEverywhere(fileURL: previous.url)
            }
            // Drop the entry we just stepped off, so undo keeps walking back
            // rather than flipping between two wallpapers.
            LumenCore.shared.dropLatestHistory()
            reloadHistory()
            if let id = previous.wallpaperId { current = known[id] }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sets a wallpaper straight from the history list.
    @MainActor
    func restore(_ entry: HistoryEntry) {
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            errorMessage = "\(entry.label) is no longer on disk."
            return
        }
        do {
            try WallpaperSetter.apply(fileURL: entry.url, to: nil, fit: .fill)
            if wallpaperScope == .allSpaces {
                try? SpacesWallpaper.applyEverywhere(fileURL: entry.url)
            }
            recordHistory(entry.url, id: entry.wallpaperId, label: entry.label)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Imported library
    //
    // Wallpapers already on disk — Lumen's own downloads, or anything else the
    // user points it at. These have no Wallhaven identity, so they get their
    // own model and their own favourite flag.

    var libraryFolders: [ImportedFolder] = []
    var libraryWallpapers: [LocalWallpaper] = []
    /// nil means every folder.
    var selectedFolder: String?
    /// Directory being browsed inside the selected folder, "" at its root.
    var browsePath: String = ""
    var libraryFavoritesOnly = false
    var isScanningLibrary = false

    @MainActor
    func reloadLibrary() {
        guard coreReady else { return }
        libraryFolders = LumenCore.shared.libraryFolders()
        // A folder that has been forgotten should not stay selected.
        if let selected = selectedFolder,
           !libraryFolders.contains(where: { $0.id == selected }) {
            selectedFolder = nil
        }
        libraryWallpapers = LumenCore.shared.libraryWallpapers(
            folder: selectedFolder, favoritesOnly: libraryFavoritesOnly)
    }

    @MainActor
    func importFolder(at path: String) async {
        isScanningLibrary = true
        defer { isScanningLibrary = false }
        do {
            _ = try await LumenCore.shared.importFolder(at: path)
            reloadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func rescanLibrary() async {
        guard !libraryFolders.isEmpty else { return }
        isScanningLibrary = true
        defer { isScanningLibrary = false }
        do {
            _ = try await LumenCore.shared.rescanLibrary()
            reloadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func forgetFolder(_ folder: ImportedFolder) {
        // Only the index is dropped; the files stay where they are.
        LumenCore.shared.forgetFolder(id: folder.id)
        reloadLibrary()
    }

    @MainActor
    func selectFolder(_ id: String?) {
        selectedFolder = id
        browsePath = ""
        reloadLibrary()
    }

    /// Steps into a subfolder, or back to a level in the breadcrumb. A
    /// "folder:" path selects one of the imported folders instead.
    @MainActor
    func browse(to path: String) {
        if let id = path.split(separator: ":", maxSplits: 1).last.map(String.init),
           path.hasPrefix("folder:") {
            selectFolder(id)
            return
        }
        withAnimation(Tokens.quick) { browsePath = path }
    }

    /// The wallpaper being previewed full-window from a local pane.
    var localPreview: LocalWallpaper?
    /// The list that preview steps through with ← and →.
    var localPreviewItems: [LocalWallpaper] = []

    /// Opens a collection's wallpaper in the Wallhaven preview, stepping
    /// through that collection rather than the search behind it.
    var collectionPreview: [Wallpaper] = []

    @MainActor
    func openCollectionPreview(_ wallpaper: Wallpaper, in collection: Collection) {
        collectionPreview = collection.wallpapers
        remember(collection.wallpapers)
        withAnimation(Tokens.normal) { previewSelection = wallpaper }
        Task { await loadDetails(for: wallpaper) }
    }

    /// Set by a pane that wants the preview opened on something specific.
    var previewSelection: Wallpaper?

    /// Opens the full-window preview on `wallpaper`, stepping through `items`.
    @MainActor
    func openLocalPreview(_ wallpaper: LocalWallpaper, in items: [LocalWallpaper]) {
        localPreviewItems = items
        withAnimation(Tokens.normal) { localPreview = wallpaper }
    }

    /// Subdirectories directly inside the level being browsed, with a count of
    /// everything beneath each.
    var currentSubfolders: [(name: String, path: String, count: Int)] {
        // With no folder chosen, the top of the tree is the imported folders
        // themselves — otherwise everything from every folder piles into one
        // list and looks like duplicates.
        guard selectedFolder != nil else {
            return libraryFolders.map { (name: $0.name, path: "folder:\($0.id)", count: $0.count) }
        }
        let prefix = browsePath.isEmpty ? "" : browsePath + "/"
        var counts: [String: Int] = [:]
        for wallpaper in libraryWallpapers {
            let sub = wallpaper.subpath
            guard sub.hasPrefix(prefix), sub != browsePath else { continue }
            let remainder = String(sub.dropFirst(prefix.count))
            guard !remainder.isEmpty else { continue }
            // Only the next level down; anything deeper counts towards it.
            let child = remainder.split(separator: "/").first.map(String.init) ?? remainder
            counts[child, default: 0] += 1
        }
        return counts
            .map { (name: $0.key, path: prefix + $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Wallpapers sitting directly in the level being browsed.
    /// Files at the level being browsed.
    ///
    /// Cached rather than filtered on demand: this is read during layout, and
    /// filtering several thousand rows on every render is felt as scroll jank.
    @ObservationIgnored private var currentFilesCache: (key: String, files: [LocalWallpaper])?

    var currentFiles: [LocalWallpaper] {
        // Nothing sits at the very top; a folder has to be chosen first.
        guard selectedFolder != nil else { return [] }
        let key = "\(selectedFolder ?? "")|\(browsePath)|\(libraryWallpapers.count)"
        if let cached = currentFilesCache, cached.key == key { return cached.files }
        let files = libraryWallpapers.filter { $0.subpath == browsePath }
        currentFilesCache = (key, files)
        return files
    }

    /// Breadcrumb trail for the level being browsed.
    var breadcrumb: [(name: String, path: String)] {
        guard !browsePath.isEmpty else { return [] }
        var trail: [(String, String)] = []
        var built = ""
        for part in browsePath.split(separator: "/") {
            built = built.isEmpty ? String(part) : built + "/" + part
            trail.append((String(part), built))
        }
        return trail
    }

    @MainActor
    func setLibraryFavoritesOnly(_ on: Bool) {
        libraryFavoritesOnly = on
        reloadLibrary()
    }

    @MainActor
    func toggleLibraryFavorite(_ wallpaper: LocalWallpaper) {
        guard LumenCore.shared.setLibraryFavorite(id: wallpaper.id,
                                                  favorite: !wallpaper.isFavorite) else {
            errorMessage = "Could not save that wallpaper."
            return
        }
        if let index = libraryWallpapers.firstIndex(where: { $0.id == wallpaper.id }) {
            withAnimation(Tokens.bouncy) {
                libraryWallpapers[index].isFavorite.toggle()
            }
        }
        // Under "favourites only" an unfavourited wallpaper should leave.
        if libraryFavoritesOnly { reloadLibrary() }
    }

    /// Sets a file already on disk. No download step, so this is direct.
    @MainActor
    func setLocalWallpaper(_ wallpaper: LocalWallpaper, on display: DisplayTarget? = nil) {
        guard FileManager.default.fileExists(atPath: wallpaper.url.path) else {
            errorMessage = "\(wallpaper.filename) is no longer on disk."
            reloadLibrary()
            return
        }
        let screen = display.flatMap { target in
            NSScreen.screens.first { $0.localizedName == target.name }
        }
        do {
            try WallpaperSetter.apply(fileURL: wallpaper.url, to: screen,
                                      fit: display?.fit ?? .fill)
            recordHistory(wallpaper.url, id: nil, label: wallpaper.filename)
            if wallpaperScope == .allSpaces, display == nil {
                try? SpacesWallpaper.applyEverywhere(fileURL: wallpaper.url)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Appearance pairing
    //
    // Two wallpapers bound to the system appearance, so the desktop follows
    // light and dark the way the rest of the system does.

    /// Wallpaper shown while the system is light.
    var lightWallpaper: Wallpaper? { didSet { savePair() } }
    /// Wallpaper shown while the system is dark.
    var darkWallpaper: Wallpaper? { didSet { savePair() } }
    /// Off by default: it writes the desktop on every appearance change.
    var followsAppearance: Bool { didSet { save(followsAppearance, "followsAppearance") } }

    private func savePair() {
        saveJSON(lightWallpaper, "lightWallpaper")
        saveJSON(darkWallpaper, "darkWallpaper")
    }

    /// Applies whichever of the pair matches the system right now.
    @MainActor
    func applyPairedWallpaper() {
        guard followsAppearance else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let wanted = isDark ? darkWallpaper : lightWallpaper else { return }
        guard current?.id != wanted.id else { return }
        setWallpaper(wanted)
    }

    /// True when this wallpaper is one half of the pair.
    func pairedRole(_ wallpaper: Wallpaper) -> String? {
        if lightWallpaper?.id == wallpaper.id { return "Light" }
        if darkWallpaper?.id == wallpaper.id { return "Dark" }
        return nil
    }

    @MainActor
    func setPaired(_ wallpaper: Wallpaper?, dark: Bool) {
        withAnimation(Tokens.quick) {
            if dark { darkWallpaper = wallpaper } else { lightWallpaper = wallpaper }
        }
        applyPairedWallpaper()
    }

    // MARK: Scroll position
    //
    // Session state, keyed by pane. Opening a wallpaper or stepping away and
    // back used to drop you at the top of the results, which is punishing
    // several pages in.

    /// Topmost wallpaper in each grid, so returning restores the same place.
    private var scrollAnchors: [String: String] = [:]

    func scrollAnchor(for pane: String) -> String? { scrollAnchors[pane] }

    func rememberScroll(_ id: String?, for pane: String) {
        guard let id else { return }
        scrollAnchors[pane] = id
    }

    /// Dropped when the list underneath changes, since the anchor is an id in
    /// a list that no longer exists.
    func forgetScroll(for pane: String) { scrollAnchors[pane] = nil }

    // MARK: Preview mode
    //
    // Session state, not view state: SwiftUI re-creates the preview whenever
    // the browsed list changes, and stepping to the next image used to drop
    // you out of full-bleed back to the fitted view.

    /// Image fills the pane and is cropped, rather than being letterboxed.
    var previewZoomed = false
    /// Inspector column is showing.
    var previewShowsInspector = true
    /// True when the fit rule below hid the inspector rather than the user
    /// doing it, which is what lets it come back on its own.
    var previewInspectorAutoHidden = false

    /// Width of the inspector column, which is fixed.
    static let inspectorWidth: CGFloat = 316
    /// What the image column needs to still read as a preview.
    static let minimumPreviewWidth: CGFloat = 520
    /// What it needs once the image is expanded — expanding says the image is
    /// the point, so a squeezed column defeats it.
    static let expandedPreviewWidth: CGFloat = 900

    /// Whether the window is wide enough for both columns.
    static func inspectorFits(windowWidth: CGFloat, expanded: Bool) -> Bool {
        let needed = expanded ? expandedPreviewWidth : minimumPreviewWidth
        return windowWidth - inspectorWidth >= needed
    }

    /// Hides the inspector when there is no room for it beside the image, and
    /// brings it back when there is again.
    ///
    /// Only what this rule hid is restored: an inspector the user closed by
    /// hand stays closed.
    @MainActor
    func reconcilePreviewInspector(windowWidth: CGFloat, expanded: Bool) {
        guard windowWidth > 0 else { return }
        let fits = Store.inspectorFits(windowWidth: windowWidth, expanded: expanded)
        if !fits, previewShowsInspector {
            withAnimation(Tokens.normal) { previewShowsInspector = false }
            previewInspectorAutoHidden = true
        } else if fits, previewInspectorAutoHidden {
            withAnimation(Tokens.normal) { previewShowsInspector = true }
            previewInspectorAutoHidden = false
        }
    }

    @MainActor
    func togglePreviewZoom() {
        withAnimation(Tokens.normal) { previewZoomed.toggle() }
    }

    @MainActor
    func togglePreviewInspector() {
        withAnimation(Tokens.normal) { previewShowsInspector.toggle() }
        // A deliberate choice outranks the fit rule until the window or the
        // zoom changes again.
        previewInspectorAutoHidden = false
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

    /// True while pages are being fetched to satisfy a bulk selection.
    var isSelectingAhead = false

    /// The most that could be selected: what Wallhaven says exists, or what is
    /// loaded when it says nothing.
    var selectableTotal: Int { max(lastPage > 0 ? totalResults : 0, wallpapers.count) }

    /// Selects the first `count` results, fetching more pages if needed.
    ///
    /// Capped at what actually exists, so asking for 500 from a search with 90
    /// selects 90 rather than paging forever.
    @MainActor
    func selectFirst(_ count: Int, in list: [Wallpaper]) async {
        guard coreReady, count > 0 else { return }
        // Favorites and focus panes are already fully loaded lists.
        guard list.count == wallpapers.count else {
            selectAll(Array(list.prefix(count)))
            return
        }

        isSelectingAhead = true
        defer { isSelectingAhead = false }

        let target = min(count, selectableTotal)
        while wallpapers.count < target && page < lastPage && !isLoading {
            page += 1
            await search(reset: false)
            if errorMessage != nil { break }
        }
        selectAll(Array(wallpapers.prefix(target)))
    }

    /// Selects everything across the first `pages` pages, capped at the last.
    @MainActor
    func selectPages(_ pages: Int, in list: [Wallpaper]) async {
        guard coreReady, pages > 0 else { return }
        guard list.count == wallpapers.count else {
            selectAll(list)
            return
        }

        isSelectingAhead = true
        defer { isSelectingAhead = false }

        let wanted = min(pages, max(lastPage, 1))
        while page < wanted && !isLoading {
            page += 1
            await search(reset: false)
            if errorMessage != nil { break }
        }
        selectAll(wallpapers)
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
            .filter { wallpaper in
                !downloads.contains { $0.wallpaperId == wallpaper.id }
                    && !isDownloaded(wallpaper)
            }
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

    // MARK: Resolution rule

    /// Results worth showing, given the resolution rule.
    ///
    /// Filtering here rather than in the query is deliberate: Wallhaven's
    /// `atleast` also excludes anything of a different shape that is otherwise
    /// large enough, which is not what "do not upscale" means.
    func visible(_ list: [Wallpaper]) -> [Wallpaper] {
        guard hideBelowDisplay else { return list }
        return list.filter { !fit($0).upscales }
    }

    /// How many of the loaded results the rule is hiding.
    func hiddenCount(in list: [Wallpaper]) -> Int {
        guard hideBelowDisplay else { return 0 }
        return list.count - visible(list).count
    }

    // MARK: Library health

    struct LibraryHealth {
        var count = 0
        var bytes: Int64 = 0
        var belowDisplay = 0
        var unindexed = 0
        var largest: (name: String, bytes: Int)?

        var size: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    var health = LibraryHealth()
    var isMeasuringHealth = false

    /// Measures the imported library: size, how much is below this display,
    /// and how much still has no feature print.
    @MainActor
    func measureLibrary() async {
        guard coreReady, !isMeasuringHealth else { return }
        isMeasuringHealth = true
        defer { isMeasuringHealth = false }

        let files = libraryWallpapers
        let printed = LumenCore.shared.printedPaths()
        let display = WallpaperFitter.mainPixelSize

        health = await Task.detached(priority: .utility) {
            var found = LibraryHealth()
            found.count = files.count
            for file in files {
                found.bytes += Int64(file.fileSize)
                if found.largest == nil || file.fileSize > (found.largest?.bytes ?? 0) {
                    found.largest = (file.filename, file.fileSize)
                }
                if !printed.contains(file.path) { found.unindexed += 1 }
                // Reading each header is why this runs off the main thread.
                if let size = file.pixelSize,
                   DisplayFit(image: size, display: display).upscales {
                    found.belowDisplay += 1
                }
            }
            return found
        }.value
    }

    // MARK: Cropping

    /// The file the crop editor is open on, if any.
    var cropTarget: (title: String, source: URL, path: String)?

    var mainDisplayKey: String { LumenCore.displayKey(WallpaperFitter.mainPixelSize) }

    func savedCrop(forPath path: String) -> CGRect? {
        LumenCore.shared.crop(path: path, display: mainDisplayKey)
    }

    func hasCrop(forPath path: String) -> Bool { savedCrop(forPath: path) != nil }

    /// Opens the editor for a Wallhaven wallpaper, materialising the file first
    /// since cropping needs the real image, not a thumbnail.
    @MainActor
    func editCrop(for wallpaper: Wallpaper) {
        Task {
            do {
                let local = try await LumenCore.shared.ensureLocal(
                    url: wallpaper.path.absoluteString, filename: wallpaper.filename)
                cropTarget = (title: wallpaper.filename, source: local,
                              path: local.path(percentEncoded: false))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    func editCrop(for wallpaper: LocalWallpaper) {
        cropTarget = (title: wallpaper.filename, source: wallpaper.url, path: wallpaper.path)
    }

    @MainActor
    func saveCrop(_ rect: CGRect) {
        guard let target = cropTarget else { return }
        LumenCore.shared.saveCrop(path: target.path, display: mainDisplayKey, rect: rect)
        cropTarget = nil
        // Applying it immediately is the point of having set it.
        applyCroppedWallpaper(at: URL(filePath: target.path), crop: rect)
    }

    @MainActor
    func clearCrop(forPath path: String) {
        LumenCore.shared.clearCrop(path: path, display: mainDisplayKey)
    }

    /// Renders the chosen crop at the display's exact pixels and sets it.
    @MainActor
    private func applyCroppedWallpaper(at file: URL, crop: CGRect) {
        let size = WallpaperFitter.mainPixelSize
        Task {
            do {
                let directory = URL(filePath: LumenCore.shared.downloadDirectory)
                    .appending(path: "Fitted")
                let fitted = try WallpaperFitter.render(file, to: size, in: directory, crop: crop)
                try WallpaperSetter.apply(fileURL: fitted, to: nil, fit: .fill)
                recordHistory(fitted, id: nil, label: file.lastPathComponent + " (cropped)")
                if wallpaperScope == .allSpaces {
                    try? SpacesWallpaper.applyEverywhere(fileURL: fitted)
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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

    /// Saves a copy cropped and scaled to a chosen size into the download
    /// directory, rather than the original.
    ///
    /// Wallhaven has no per-resolution download, so a "download at this size"
    /// has to be produced locally.
    @MainActor
    func downloadFitted(_ wallpaper: Wallpaper, to size: CGSize) {
        Task {
            do {
                let source = try await LumenCore.shared.ensureLocal(
                    url: wallpaper.path.absoluteString,
                    filename: wallpaper.filename)
                let directory = URL(filePath: LumenCore.shared.downloadDirectory)
                _ = try WallpaperFitter.render(source, to: size, in: directory)
                refreshDownloadedIDs()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Sizes offered for a fitted download: this display, plus the common ones
    /// that are no larger than the source.
    func fittedSizes(for wallpaper: Wallpaper) -> [(label: String, size: CGSize)] {
        var offered: [(String, CGSize)] = []
        let native = WallpaperFitter.mainPixelSize
        offered.append(("This display · \(Int(native.width)) × \(Int(native.height))", native))

        let parts = wallpaper.resolution.split(separator: "x")
        let sourceWidth = Double(parts.first ?? "0") ?? 0
        for size in ["3840x2160", "2560x1440", "1920x1080"] {
            let dims = size.split(separator: "x")
            guard let width = Double(dims.first ?? ""), let height = Double(dims.last ?? ""),
                  width <= sourceWidth        // never offer an upscale
            else { continue }
            offered.append((size.replacingOccurrences(of: "x", with: " × "),
                            CGSize(width: width, height: height)))
        }
        return offered
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
                recordHistory(fitted, id: wallpaper.id, label: "wallhaven-\(wallpaper.id) (fitted)")
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

    /// Searches for wallpapers like this one.
    ///
    /// Wallhaven has a `like:<id>` operator that is its own notion of
    /// similarity — better than approximating it from tags, which is what this
    /// used to do. Category and purity carry over so results stay inside what
    /// the user already said they want to see.
    @MainActor
    func findSimilar(to wallpaper: Wallpaper) {
        var next = SearchFilters()
        next.categories = filters.categories
        next.purity = filters.purity
        next.sorting = .relevance
        next.query = "like:\(wallpaper.id)"
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
        forgetScroll(for: "focus")
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

    /// What can honestly be said about an uploader.
    ///
    /// Wallhaven has no profile endpoint — no join date, no follower count — so
    /// this is derived from their uploads: how many there are, and the views
    /// and favourites across the ones actually loaded. Labelled as such rather
    /// than presented as a complete profile.
    struct UploaderStats {
        var uploads: Int
        var loaded: Int
        var views: Int
        var favorites: Int

        var averageFavorites: Int { loaded > 0 ? favorites / loaded : 0 }
    }

    var uploaderStats: UploaderStats? {
        guard case .uploader = focus, !focusWallpapers.isEmpty else { return nil }
        return UploaderStats(
            uploads: focusTotal,
            loaded: focusWallpapers.count,
            views: focusWallpapers.reduce(0) { $0 + $1.views },
            favorites: focusWallpapers.reduce(0) { $0 + $1.favorites })
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
                // By id, not "#name": a tag like "LEO (Artist)" does not
                // survive being pasted into a fuzzy query.
                page = try await LumenCore.shared.search(
                    query(prefix: "id:", String(ref.id)), page: focusPage)
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
