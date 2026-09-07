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

    /// Kept in the keychain rather than in `UserDefaults` — see [Keychain].
    /// The rest of the preferences below are ordinary settings and stay there.
    var apiKey: String { didSet { Keychain.setAPIKey(apiKey); pushPreferences() } }
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

    /// The key from the keychain, moving an older plaintext copy there first.
    ///
    /// Versions before this kept it in `UserDefaults`. The copy in the plist is
    /// only removed once the keychain has accepted it, so a failed write — a
    /// locked keychain, a denied prompt — loses nothing.
    private static func migratedAPIKey(from defaults: UserDefaults) -> String {
        if let stored = Keychain.apiKey() {
            defaults.removeObject(forKey: "apiKey")
            return stored
        }
        guard let legacy = defaults.string(forKey: "apiKey"), !legacy.isEmpty else { return "" }
        if Keychain.setAPIKey(legacy) {
            defaults.removeObject(forKey: "apiKey")
        }
        return legacy
    }

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

        apiKey = Store.migratedAPIKey(from: defaults)
        focusUsesFilters = bool("focusUsesFilters", default: false)
        focusSorting = Sorting(rawValue: defaults.string(forKey: "focusSorting") ?? "") ?? .dateAdded
        indexInBackground = bool("indexInBackground", default: true)
        localSort = LocalSort(rawValue: defaults.string(forKey: "localSort") ?? "") ?? .name
        localSortAscending = bool("localSortAscending", default: true)
        remoteSort = RemoteSort(rawValue: defaults.string(forKey: "remoteSort") ?? "") ?? .dateAdded
        remoteSortAscending = bool("remoteSortAscending", default: false)
        downloadDestination = DownloadDestination(
            key: defaults.string(forKey: "downloadDestination") ?? "")
        skipDuplicateDownloads = bool("skipDuplicateDownloads", default: true)
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
        // Whatever a previous run left unfinished, quietly.
        startBackgroundIndexing()
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
    /// Whether this wallpaper is already on disk.
    ///
    /// Not only what Lumen downloaded: a folder of wallpapers collected from
    /// the site years ago is still a folder you already have, and browsing
    /// should say so rather than offering them all over again. The names carry
    /// the ids, so the answer is a set lookup.
    func isDownloaded(_ wallpaper: Wallpaper) -> Bool {
        downloadedIDs.contains(wallpaper.id) || libraryWallhavenIDs.contains(wallpaper.id)
    }

    /// Wallhaven ids present anywhere in the imported library.
    ///
    /// Built once from the filenames rather than per tile: it is one pass over
    /// the library, and every grid tile then costs a hash lookup.
    private(set) var libraryWallhavenIDs: Set<String> = []

    /// Rebuilds that set. Only the calls that change what is imported need it —
    /// switching folders does not, which is why it is not in `reloadLibrary`.
    @MainActor
    func reloadLibraryIdentities() {
        libraryWallhavenIDs = LumenCore.shared.libraryWallhavenIDs()
    }

    /// The file holding a wallpaper, when the library already has it.
    func libraryFile(for wallpaper: Wallpaper) -> LocalWallpaper? {
        guard libraryWallhavenIDs.contains(wallpaper.id) else { return nil }
        return libraryWallpapers.first {
            Wallpaper.wallhavenID(fromFilename: $0.filename) == wallpaper.id
        }
    }

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
            // Asked before the bytes are spent, not after.
            if let have = await alreadyInLibrary(wallpaper) {
                lastSkippedDuplicates = [wallpaper.id]
                errorMessage = "You already have this one — \(have.filename)."
                return
            }
            do {
                try await LumenCore.shared.download(id: wallpaper.id,
                                                    url: wallpaper.path.absoluteString,
                                                    filename: wallpaper.filename,
                                                    directory: destinationDirectory)
                fileIntoDestination(wallpaper)
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

        // Published in batches. Reading four thousand file headers takes long
        // enough that doing it all before publishing anything left the grid
        // laying every wallpaper out at the placeholder shape for seconds.
        for chunk in stride(from: 0, to: missing.count, by: 200).map({
            Array(missing[$0..<min($0 + 200, missing.count)])
        }) {
            if Task.isCancelled { return }
            let measured = await Task.detached(priority: .utility) {
                chunk.reduce(into: [String: Double]()) { found, wallpaper in
                    guard let size = wallpaper.pixelSize, size.height > 0 else { return }
                    found[wallpaper.path] = size.width / size.height
                }
            }.value
            guard !measured.isEmpty else { continue }
            aspectRatios.merge(measured) { _, new in new }
        }
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
        // Vectors rather than prints: the comparison is the same measure, four
        // times faster, and the same one the graph uses.
        let prints = await loadedPrints()
            .filter { wanted.contains($0.path) }
            .compactMap { entry -> (path: String, vector: [Float])? in
                ImagePrints.vector(entry.print).map { (entry.path, $0) }
            }
        // Shapes come from the file headers the grid already reads, so the
        // confirming check costs nothing extra.
        let aspects = candidates.reduce(into: [String: Double]()) { out, file in
            guard let size = file.pixelSize, size.height > 0 else { return }
            out[file.path] = size.width / size.height
        }
        let groups = await Task.detached(priority: .userInitiated) {
            ImagePrints.duplicateGroups(in: prints, aspects: aspects)
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

    // MARK: The similarity graph
    //
    // Three features used to each do their own sweep over the prints with a
    // different measure. They now share one weighted graph, which is both
    // faster — it is built once — and better, because a graph can answer
    // questions a distance list cannot. See [SimilarityGraph].

    /// Held between calls: building is the expensive part, and the library
    /// changes far less often than these features are used.
    @ObservationIgnored private var cachedGraph: (paths: Set<String>,
                                                  graph: SimilarityGraph,
                                                  vectors: [(path: String, vector: [Float])])?

    /// The library as a graph, built on first use and reused until the set of
    /// indexed files changes.
    private func libraryGraph() async -> SimilarityGraph? {
        let prints = await loadedPrints()
        guard prints.count > 1 else { return nil }

        let key = Set(prints.map(\.path))
        if let cached = cachedGraph, cached.paths == key { return cached.graph }

        let entries = prints.compactMap { entry -> (path: String, vector: [Float])? in
            ImagePrints.vector(entry.print).map { (entry.path, $0) }
        }
        guard entries.count > 1 else { return nil }

        let graph = await Task.detached(priority: .userInitiated) {
            SimilarityGraph.build(from: entries)
        }.value
        cachedGraph = (key, graph, entries)
        return graph
    }

    /// The library's vectors, for questions that are not about the graph.
    private func libraryVectors() async -> [(path: String, vector: [Float])] {
        _ = await libraryGraph()
        return cachedGraph?.vectors ?? []
    }

    /// Collapses results that are the same picture filed twice.
    ///
    /// A library built from several folders holds the same wallpaper more than
    /// once — this one has over fifteen hundred such pairs — and without this
    /// a page of "similar" is mostly the same picture repeated. Only the
    /// best-ranked copy of each survives.
    ///
    /// Cheap enough to do unconditionally: a result list is a couple of dozen
    /// entries, so this is a few hundred vector comparisons, and the filename
    /// test settles most of them before any arithmetic happens.
    private func collapsingDuplicates(_ paths: [String], limit: Int) -> [String] {
        let vectors = cachedGraph?.vectors.reduce(into: [String: [Float]]()) { out, entry in
            out[entry.path] = entry.vector
        } ?? [:]
        let names = libraryWallpapers.reduce(into: [String: String]()) { out, file in
            out[file.path] = file.filename
        }

        var kept: [String] = []
        var keptNames = Set<String>()
        for path in paths {
            guard kept.count < limit else { break }
            // Same filename in another folder is the same wallpaper; for a
            // library named after Wallhaven ids that settles it outright.
            if let name = names[path] {
                guard !keptNames.contains(name) else { continue }
            }
            if let vector = vectors[path] {
                let isCopy = kept.contains { other in
                    guard let existing = vectors[other] else { return false }
                    return ImagePrints.distance(vector, existing) <= ImagePrints.duplicateThreshold
                }
                guard !isCopy else { continue }
            }
            kept.append(path)
            if let name = names[path] { keptNames.insert(name) }
        }
        return kept
    }

    /// Drops the graph, for when the indexed set has changed under it.
    func forgetSimilarityGraph() { cachedGraph = nil }

    /// Files in the library most like this one.
    ///
    /// Ranked by proximity through the graph rather than by straight-line
    /// distance, which keeps hubs — the handful of prints that measure close to
    /// almost everything — out of every result list.
    @MainActor
    func findSimilarInLibrary(to wallpaper: LocalWallpaper) async {
        guard coreReady else { return }
        await indexLibrary()

        guard let graph = await libraryGraph() else {
            similarToSelection = []
            return
        }
        let path = wallpaper.path
        // Over-fetch, because collapsing copies removes entries: asking for
        // twelve and then deduplicating would leave four.
        let nearest = await Task.detached(priority: .userInitiated) {
            graph.related(to: path, limit: 48).map(\.path)
        }.value
        let unique = collapsingDuplicates(nearest, limit: 12)

        let byPath = Dictionary(uniqueKeysWithValues: libraryWallpapers.map { ($0.path, $0) })
        withAnimation(Tokens.normal) {
            similarToSelection = unique.compactMap { byPath[$0] }
        }
    }

    // MARK: Where downloads go, and what not to download twice

    /// Where a download should land.
    ///
    /// A collection is a grouping in the database, not a place on disk, so
    /// filing into one still writes the file to the download folder. An
    /// imported folder is a real directory, so the file goes there and turns up
    /// in that folder on the next scan.
    enum DownloadDestination: Hashable {
        case downloadFolder
        case importedFolder(id: String)
        case collection(id: String)

        var key: String {
            switch self {
            case .downloadFolder: "downloads"
            case .importedFolder(let id): "folder:\(id)"
            case .collection(let id): "collection:\(id)"
            }
        }

        init(key: String) {
            if let id = key.split(separator: ":", maxSplits: 1).last.map(String.init),
               key.hasPrefix("folder:") {
                self = .importedFolder(id: id)
            } else if let id = key.split(separator: ":", maxSplits: 1).last.map(String.init),
                      key.hasPrefix("collection:") {
                self = .collection(id: id)
            } else {
                self = .downloadFolder
            }
        }
    }

    var downloadDestination: DownloadDestination = .downloadFolder {
        didSet { save(downloadDestination.key, "downloadDestination") }
    }

    /// Whether a download is skipped when the library already holds the picture.
    var skipDuplicateDownloads = true {
        didSet { save(skipDuplicateDownloads, "skipDuplicateDownloads") }
    }

    /// What the last download call skipped, so the UI can say why nothing
    /// happened rather than appearing to have ignored the click.
    var lastSkippedDuplicates: [String] = []

    /// The directory a download should be written to, if not the default.
    var destinationDirectory: String? {
        guard case .importedFolder(let id) = downloadDestination else { return nil }
        return libraryFolders.first { $0.id == id }?.path
    }

    /// A human name for the destination, for the picker and for messages.
    var destinationLabel: String {
        switch downloadDestination {
        case .downloadFolder:
            "Download folder"
        case .importedFolder(let id):
            libraryFolders.first { $0.id == id }?.name ?? "Download folder"
        case .collection(let id):
            collections.first { $0.id == id }?.name ?? "Download folder"
        }
    }

    /// A wallpaper already in the library that looks like this one.
    ///
    /// Checked against the *thumbnail*, which the grid has already decoded, so
    /// asking costs a feature print rather than a download. That is what makes
    /// it possible to answer "you already have this" before spending the
    /// bandwidth, and it catches the case an id check cannot: the same picture
    /// downloaded before at a different resolution, or from another uploader.
    @MainActor
    func alreadyInLibrary(_ wallpaper: Wallpaper) async -> LocalWallpaper? {
        guard skipDuplicateDownloads else { return nil }
        // The name is proof when it is there; no need to look at the picture.
        if let known = libraryFile(for: wallpaper) { return known }
        let nearest = await nearestInLibrary(to: wallpaper, limit: 1).first
        guard let nearest, nearest.distance <= ImagePrints.duplicateThreshold else { return nil }
        return nearest.file
    }

    /// The wallpaper's own vector, printed from the thumbnail the grid has
    /// already decoded so nothing has to be downloaded to ask.
    private func vector(for wallpaper: Wallpaper) async -> [Float]? {
        guard let image = await ImageCache.shared.image(for: wallpaper.thumb) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> [Float]? in
            // Vision reads from a file, so the decoded thumbnail goes back out
            // to one briefly rather than being re-fetched.
            let url = FileManager.default.temporaryDirectory
                .appending(path: "lumen-print-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: url)) != nil,
                  let print = ImagePrints.print(of: url) else { return nil }
            return ImagePrints.vector(print)
        }.value
    }

    /// What the library already holds that looks like a wallpaper from
    /// Wallhaven, nearest first.
    ///
    /// A remote wallpaper is not a node in the similarity graph — it is not on
    /// disk — so the graph walk that answers "more like this" for a local file
    /// cannot be used. This measures against the library's vectors directly,
    /// which is the same question asked a cruder way.
    func nearestInLibrary(to wallpaper: Wallpaper,
                          limit: Int = 12) async -> [(file: LocalWallpaper, distance: Float)] {
        let vectors = await libraryVectors()
        guard !vectors.isEmpty, let made = await vector(for: wallpaper) else { return [] }

        let ranked = await Task.detached(priority: .userInitiated) {
            vectors
                .map { ($0.path, ImagePrints.distance(made, $0.vector)) }
                .sorted { $0.1 < $1.1 }
                .prefix(limit)
                .map { ($0.0, $0.1) }
        }.value

        let byPath = Dictionary(uniqueKeysWithValues: libraryWallpapers.map { ($0.path, $0) })
        return ranked.compactMap { path, distance in
            byPath[path].map { (file: $0, distance: distance) }
        }
    }

    /// What the library holds like the wallpaper being previewed, and whether
    /// the closest is close enough to call the same picture.
    var libraryMatches: [(file: LocalWallpaper, distance: Float)] = []
    var isMatchingLibrary = false

    @MainActor
    func findInLibrary(like wallpaper: Wallpaper) async {
        guard coreReady else { return }
        isMatchingLibrary = true
        defer { isMatchingLibrary = false }
        await indexLibrary()
        let found = await nearestInLibrary(to: wallpaper, limit: 48)
        // The nearest thing to a wallpaper you have twice is itself, twice.
        let unique = collapsingDuplicates(found.map(\.file.path), limit: 12)
        let byPath = Dictionary(found.map { ($0.file.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        withAnimation(Tokens.normal) {
            libraryMatches = unique.compactMap { byPath[$0] }
        }
    }

    @MainActor
    func clearLibraryMatches() { libraryMatches = [] }

    /// Files a wallpaper into the chosen collection, if one is chosen.
    @MainActor
    private func fileIntoDestination(_ wallpaper: Wallpaper) {
        guard case .collection(let id) = downloadDestination,
              let collection = collections.first(where: { $0.id == id }) else { return }
        setMembership(wallpaper, of: collection, member: true)
    }

    // MARK: Semantic search
    //
    // Describing what you want, rather than naming it. Tags only cover what
    // Wallhaven happened to label; this covers the rest, and works on folders
    // of your own images that have no tags at all.

    /// Results for the current description, best first.
    var semanticResults: [LocalWallpaper] = []
    var isSemanticIndexing = false
    var semanticProgress = (done: 0, total: 0)
    /// Set when the model is missing or failed, so the UI can say why.
    var semanticUnavailable: String?

    /// How many of the library's files have an embedding.
    var semanticCoverage: (done: Int, total: Int) {
        (embeddedCount, libraryWallpapers.count)
    }

    @ObservationIgnored private var embeddedCount = 0
    /// Vectors held in memory once loaded: 3,900 x 512 floats is eight
    /// megabytes, and reloading them per query would be the slowest part.
    @ObservationIgnored private var semanticVectors: [(path: String, vector: [Float])] = []

    @MainActor
    func prepareSemanticIndex() async {
        await SemanticIndex.shared.load()
        semanticUnavailable = SemanticIndex.shared.unavailableReason
        loadSemanticVectors()
    }

    private func loadSemanticVectors() {
        let stored = LumenCore.shared.allEmbeddings(model: SemanticIndex.modelIdentifier)
        semanticVectors = stored.compactMap { entry in
            guard let data = Data(base64Encoded: entry.embedding),
                  let vector = SemanticIndex.decode(data) else { return nil }
            return (entry.path, vector)
        }
        embeddedCount = semanticVectors.count
    }

    /// Embeds everything in the library that has not been embedded yet.
    ///
    /// Resumable by construction — only what is missing is computed — because
    /// at roughly forty milliseconds an image a full library is minutes, and
    /// that is not something to start over after a quit.
    @MainActor
    func buildSemanticIndex() async {
        await SemanticIndex.shared.load()
        guard SemanticIndex.shared.isReady else {
            semanticUnavailable = SemanticIndex.shared.unavailableReason
            return
        }
        semanticUnavailable = nil

        let known = LumenCore.shared.embeddedPaths(model: SemanticIndex.modelIdentifier)
        let pending = libraryWallpapers.filter { !known.contains($0.path) }
        guard !pending.isEmpty else {
            loadSemanticVectors()
            return
        }

        isSemanticIndexing = true
        semanticProgress = (0, pending.count)
        defer {
            isSemanticIndexing = false
            semanticProgress = (0, 0)
        }

        // Written in batches so an interrupted run keeps most of its work, and
        // so the progress the user sees is real rather than a spinner.
        var batch: [(path: String, data: Data, fileSize: Int)] = []
        for (index, file) in pending.enumerated() {
            if Task.isCancelled { break }
            if let vector = SemanticIndex.shared.embed(imageAt: file.url) {
                batch.append((file.path, SemanticIndex.encode(vector), file.fileSize))
            }
            if batch.count >= 64 {
                _ = LumenCore.shared.storeEmbeddings(batch,
                                                     model: SemanticIndex.modelIdentifier)
                batch.removeAll(keepingCapacity: true)
            }
            semanticProgress = (index + 1, pending.count)
            // Yield so the grid keeps drawing during a run of several minutes.
            await Task.yield()
        }
        if !batch.isEmpty {
            _ = LumenCore.shared.storeEmbeddings(batch, model: SemanticIndex.modelIdentifier)
        }
        loadSemanticVectors()
    }

    /// Finds library wallpapers matching a description.
    @MainActor
    func searchSemantically(_ description: String) async {
        let query = description.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            semanticResults = []
            return
        }
        await SemanticIndex.shared.load()
        guard SemanticIndex.shared.isReady else {
            semanticUnavailable = SemanticIndex.shared.unavailableReason
            return
        }
        if semanticVectors.isEmpty { loadSemanticVectors() }
        guard !semanticVectors.isEmpty else {
            semanticUnavailable = "Nothing indexed yet — run Build Index first."
            return
        }
        semanticUnavailable = nil

        guard let wanted = SemanticIndex.shared.embed(text: query) else { return }
        let vectors = semanticVectors
        let ranked = await Task.detached(priority: .userInitiated) {
            vectors
                .map { ($0.path, SemanticIndex.similarity(wanted, $0.vector)) }
                .sorted { $0.1 > $1.1 }
                .prefix(96)
                .map(\.0)
        }.value

        let unique = collapsingDuplicates(ranked, limit: 36)
        let byPath = Dictionary(uniqueKeysWithValues: libraryWallpapers.map { ($0.path, $0) })
        withAnimation(Tokens.normal) {
            semanticResults = unique.compactMap { byPath[$0] }
        }
    }

    @MainActor
    func clearSemanticResults() {
        withAnimation(Tokens.normal) { semanticResults = [] }
    }

    // MARK: Discover

    /// Wallpapers of your own worth another look.
    var discoveries: [LocalWallpaper] = []
    var isDiscovering = false

    /// Follows the graph out from what you have favourited.
    ///
    /// Deliberately not "nearest to your favourites": that returns near-copies
    /// of things you have already chosen. A walk that keeps restarting from the
    /// favourites spreads into the neighbourhoods around them, so something two
    /// hops away through a dense cluster can outrank a closer but isolated
    /// file — which is the difference between a search result and a suggestion.
    ///
    /// Recently-set wallpapers are held back, because the answer to "show me
    /// something" should not be what was on the screen yesterday.
    /// What Discover follows, strongest signal first.
    ///
    /// Favourites alone are too thin to walk from: one heart is one seed, and a
    /// seed in a sparse corner of the graph reaches almost nothing. Wallpapers
    /// you have actually put on the desktop are the better evidence anyway —
    /// choosing something repeatedly says more than clicking a heart once.
    private func discoverySeeds() -> [String: Float] {
        var seeds: [String: Float] = [:]
        let known = Set(libraryWallpapers.map(\.path))

        for file in libraryWallpapers where file.isFavorite {
            seeds[file.path, default: 0] += 3
        }
        // Repeats add up, so a wallpaper set again and again weighs more.
        for entry in history.prefix(60) where known.contains(entry.url.path) {
            seeds[entry.url.path, default: 0] += 1
        }
        return seeds
    }

    @MainActor
    func discover() async {
        guard coreReady else { return }
        await indexLibrary()

        let seeds = discoverySeeds()
        guard !seeds.isEmpty else {
            errorMessage = "Favourite a few of your own wallpapers, or set some, "
                + "so Discover has something to follow."
            return
        }
        guard let graph = await libraryGraph() else { return }

        isDiscovering = true
        defer { isDiscovering = false }

        let recent = Set(history.prefix(8).map(\.url.path))
        let vectors = await libraryVectors()
        let picks = await Task.detached(priority: .userInitiated) { () -> [String] in
            var found = graph.discover(seeds: seeds, excluding: recent, limit: 96)
                .map(\.path)

            // The graph is not one connected piece — a seed in a small
            // component genuinely has few neighbours to reach, and returning
            // one result reads as a broken feature rather than a sparse corner.
            // Topping up by plain distance to the seeds is the honest fallback.
            if found.count < 24 {
                let taken = Set(found).union(seeds.keys).union(recent)
                let byPath = Dictionary(vectors.map { ($0.path, $0.vector) },
                                        uniquingKeysWith: { first, _ in first })
                let references = seeds.keys.compactMap { byPath[$0] }
                if !references.isEmpty {
                    let extra = vectors
                        .filter { !taken.contains($0.path) }
                        .map { entry -> (String, Float) in
                            let best = references
                                .map { ImagePrints.distance(entry.vector, $0) }
                                .min() ?? .greatestFiniteMagnitude
                            return (entry.path, best)
                        }
                        .sorted { $0.1 < $1.1 }
                        .prefix(96 - found.count)
                        .map(\.0)
                    found.append(contentsOf: extra)
                }
            }
            return found
        }.value

        let unique = collapsingDuplicates(picks, limit: 24)
        let byPath = Dictionary(uniqueKeysWithValues: libraryWallpapers.map { ($0.path, $0) })
        withAnimation(Tokens.normal) {
            discoveries = unique.compactMap { byPath[$0] }
        }
        if discoveries.isEmpty {
            errorMessage = "Nothing to suggest yet — index the library first."
        }
    }

    /// Clears the Discover results, so the pane goes back to the folder.
    @MainActor
    func clearDiscoveries() {
        withAnimation(Tokens.normal) { discoveries = [] }
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
    /// What each Space is showing now, so the list can be read by picture
    /// rather than by number.
    var spaceWallpapers: [String: URL] = [:]

    @MainActor
    func reloadSpaces() {
        spaces = SpacesWallpaper.spaces()
        spaceWallpapers = SpacesWallpaper.currentWallpapers()
        screenSaverImage = SpacesWallpaper.screenSaverImage()
    }

    /// The file a Space is showing, if Lumen can tell.
    func wallpaper(onSpace space: SpacesWallpaper.Space) -> URL? {
        spaceWallpapers[space.uuid]
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
                reloadSpaces()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Makes a wallpaper the screen saver.
    ///
    /// Deliberately not called "lock screen": macOS shows the desktop picture
    /// when you lock, so there is nothing separate to set. This is the picture
    /// that replaces the moving screen saver after the idle delay.
    @MainActor
    func setScreenSaver(_ wallpaper: Wallpaper) {
        Task {
            do {
                let local = try await LumenCore.shared.ensureLocal(
                    url: wallpaper.path.absoluteString, filename: wallpaper.filename)
                attachLocalFile(local, to: wallpaper.id)
                try SpacesWallpaper.applyToScreenSaver(fileURL: local)
                // Deliberately not recorded in history: history is what has
                // been on the *desktop*, and undo restores that. Mixing the
                // screen saver in would make undo put the wrong thing back.
                screenSaverImage = local
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    func setScreenSaver(local wallpaper: LocalWallpaper) {
        guard FileManager.default.fileExists(atPath: wallpaper.url.path) else {
            errorMessage = "\(wallpaper.filename) is no longer on disk."
            return
        }
        do {
            try SpacesWallpaper.applyToScreenSaver(fileURL: wallpaper.url)
            screenSaverImage = wallpaper.url
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The screen saver's still picture, when it is one.
    var screenSaverImage: URL?

    @MainActor
    func reloadScreenSaver() {
        screenSaverImage = SpacesWallpaper.screenSaverImage()
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
            reloadSpaces()
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
        // Communities over the graph rather than single-link clustering, which
        // chained: A resembled B and B resembled C, so a group ended up holding
        // A and C which resembled nothing of each other.
        guard let graph = await libraryGraph() else { return }
        let groups = await Task.detached(priority: .userInitiated) {
            graph.communities().map { $0.filter { wanted.contains($0) } }
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

        // A graph over the favourites *and* the results together, walked from
        // the favourites. Mean distance — what this did before — ranks by
        // closeness to the average of what you like, which rewards the
        // unremarkable middle and buries anything distinctive. The walk instead
        // follows the connections between results, so a wallpaper that sits in
        // a cluster around one favourite scores well even when its straight-line
        // distance to the rest is large.
        let referenceKeys = references.keys.map { "fav:\($0)" }
        var entries: [(path: String, vector: [Float])] = []
        for (key, print) in references {
            if let vector = ImagePrints.vector(print) { entries.append(("fav:\(key)", vector)) }
        }
        for (key, print) in candidates {
            if let vector = ImagePrints.vector(print) { entries.append((key, vector)) }
        }
        guard entries.count > 1 else { return }

        let scored = await Task.detached(priority: .userInitiated) {
            let graph = SimilarityGraph.build(from: entries)
            let seeds = Dictionary(referenceKeys.map { ($0, Float(1)) }, uniquingKeysWith: +)
            let scores = graph.walk(from: seeds)
            return zip(graph.paths, scores).reduce(into: [String: Float]()) { out, pair in
                out[pair.0] = pair.1
            }
        }.value

        withAnimation(Tokens.normal) {
            // Highest score first: this is a ranking now, not a distance.
            wallpapers.sort { a, b in
                (scored[a.thumb.absoluteString] ?? 0) > (scored[b.thumb.absoluteString] ?? 0)
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

    // MARK: Background indexing
    //
    // Importing a folder used to leave every derived thing unbuilt until the
    // feature that needed it was asked for — so the first duplicate scan, the
    // first Discover and the first description each paid for the whole library
    // while the user waited. The work is the same either way; doing it quietly
    // after an import is what makes those features feel instant later.

    /// Whether importing a folder starts building its indexes.
    var indexInBackground = true {
        didSet { save(indexInBackground, "indexInBackground") }
    }

    /// What the background pass is doing, for the status line.
    var backgroundIndexStage: String?

    @ObservationIgnored private var indexingTask: Task<Void, Never>?

    /// Builds everything the library needs, in the order it becomes useful.
    ///
    /// Shapes first because the grid is drawing right now and needs them;
    /// feature prints next, which duplicates and Discover rest on; embeddings
    /// last because they are the slowest and the only stage that can be absent
    /// entirely. Cancellable, and each stage skips what is already done, so an
    /// interrupted run costs nothing on the next one.
    @MainActor
    func startBackgroundIndexing() {
        guard indexInBackground, coreReady else { return }
        indexingTask?.cancel()
        indexingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.backgroundIndexStage = nil }

            self.backgroundIndexStage = "shapes"
            await self.loadAspectRatios(for: self.libraryWallpapers)
            if Task.isCancelled { return }

            self.backgroundIndexStage = "prints"
            await self.indexLibrary()
            if Task.isCancelled { return }

            // Only when the model is installed: it is a large download that
            // cannot be redistributed, so a fresh checkout will not have it.
            if SemanticIndex.isInstalled {
                self.backgroundIndexStage = "descriptions"
                await self.buildSemanticIndex()
            }
        }
    }

    @MainActor
    func stopBackgroundIndexing() {
        indexingTask?.cancel()
        indexingTask = nil
        backgroundIndexStage = nil
    }

    /// Reloads the imported folder list and the files in the selected one.
    ///
    /// Also refreshes the id set, which is what browsing consults to know a
    /// wallpaper is already on disk. It is one query returning short strings,
    /// so doing it here rather than tracking every path that could change what
    /// is imported is the cheaper mistake.
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
        reloadLibraryIdentities()
    }

    @MainActor
    func importFolder(at path: String) async {
        isScanningLibrary = true
        defer { isScanningLibrary = false }
        do {
            _ = try await LumenCore.shared.importFolder(at: path)
            reloadLibrary()
            startBackgroundIndexing()
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
            startBackgroundIndexing()
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
            + "|\(localSort.rawValue)|\(localSortAscending)|\(localSearch)"
        if let cached = currentFilesCache, cached.key == key { return cached.files }
        let files = localSort.apply(
            to: matching(localSearch, in: libraryWallpapers.filter { $0.subpath == browsePath }),
            ascending: localSortAscending
        )
        currentFilesCache = (key, files)
        return files
    }

    // MARK: Sorting and searching what you already have
    //
    // A folder of four thousand wallpapers is not browsable in file order. The
    // sort keys are the ones actually worth ordering by — how big it is on
    // screen, how big it is on disk, when it arrived — and the search reaches
    // the Wallhaven tags too, for any file whose record is on disk.

    enum LocalSort: String, CaseIterable, Identifiable {
        case name, size, resolution, dateAdded

        var id: String { rawValue }

        var label: String {
            switch self {
            case .name: "Name"
            case .size: "File Size"
            case .resolution: "Resolution"
            case .dateAdded: "Date Added"
            }
        }

        var symbol: String {
            switch self {
            case .name: "textformat"
            case .size: "internaldrive"
            case .resolution: "arrow.up.left.and.arrow.down.right"
            case .dateAdded: "calendar"
            }
        }

        func apply(to files: [LocalWallpaper], ascending: Bool) -> [LocalWallpaper] {
            let sorted: [LocalWallpaper]
            switch self {
            case .name:
                sorted = files.sorted {
                    $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
                }
            case .size:
                sorted = files.sorted { $0.fileSize < $1.fileSize }
            case .resolution:
                // By pixel count, so a tall wallpaper and a wide one of the
                // same size sort together. Unknown sizes sink rather than
                // scattering through the list.
                sorted = files.sorted { area(of: $0) < area(of: $1) }
            case .dateAdded:
                // The index has no timestamp, so this is the file's own — which
                // for a folder of downloads is when it was downloaded.
                sorted = files.sorted { added(to: $0) < added(to: $1) }
            }
            return ascending ? sorted : sorted.reversed()
        }

        private func area(of file: LocalWallpaper) -> Double {
            guard let size = file.pixelSize else { return 0 }
            return size.width * size.height
        }

        private func added(to file: LocalWallpaper) -> Date {
            let values = try? file.url.resourceValues(
                forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            return values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast
        }
    }

    var localSort: LocalSort = .name {
        didSet { save(localSort.rawValue, "localSort"); currentFilesCache = nil }
    }
    var localSortAscending = true {
        didSet { save(localSortAscending, "localSortAscending"); currentFilesCache = nil }
    }
    /// Filters the pane. Matches the filename, and the Wallhaven tags of any
    /// file that has its record beside it.
    var localSearch = "" { didSet { currentFilesCache = nil } }

    /// Terms per file, built once and kept.
    ///
    /// Reading a sidecar per file per keystroke would make typing unusable at
    /// four thousand files, so the records are read once and indexed.
    @ObservationIgnored private var searchTerms: [String: String] = [:]
    @ObservationIgnored private var searchTermsBuiltFor = 0

    /// Applies the search box to a list.
    func matching(_ query: String, in files: [LocalWallpaper]) -> [LocalWallpaper] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return files }
        return files.filter { file in
            file.filename.lowercased().contains(needle)
                || (searchTerms[file.path]?.contains(needle) ?? false)
        }
    }

    /// Reads every sidecar once so tags are searchable.
    ///
    /// Off the main actor: at four thousand files this is thousands of small
    /// reads, and it must not block the pane it is about to improve.
    @MainActor
    func indexSearchTerms() async {
        let files = libraryWallpapers
        guard files.count != searchTermsBuiltFor else { return }
        let paths = files.map(\.url)

        let built = await Task.detached(priority: .utility) {
            var terms: [String: String] = [:]
            terms.reserveCapacity(paths.count)
            for url in paths {
                guard let record = WallpaperMetadata.sidecar(for: url) else { continue }
                // One string per file rather than a set: `contains` on a joined
                // string beats iterating a set of short tags.
                var bag = record.tags.joined(separator: " ")
                if let uploader = record.uploader { bag += " @" + uploader }
                bag += " " + record.category + " " + record.resolution
                terms[url.path] = bag.lowercased()
            }
            return terms
        }.value

        searchTerms = built
        searchTermsBuiltFor = files.count
        currentFilesCache = nil
    }

    /// How many files have a Wallhaven record beside them, which is what makes
    /// tag search work.
    var filesWithMetadata: Int { searchTerms.count }

    // ── the same, for wallpapers that came from Wallhaven ──────────────────
    //
    // Collections and search results carry more to sort by than files on disk
    // do: the API reports views and favourites, and the resolution is known
    // without opening anything.

    enum RemoteSort: String, CaseIterable, Identifiable {
        case dateAdded, name, size, resolution, favorites, views

        var id: String { rawValue }

        var label: String {
            switch self {
            case .dateAdded: "Date Added"
            case .name: "Name"
            case .size: "File Size"
            case .resolution: "Resolution"
            case .favorites: "Favourites"
            case .views: "Views"
            }
        }

        var symbol: String {
            switch self {
            case .dateAdded: "calendar"
            case .name: "textformat"
            case .size: "internaldrive"
            case .resolution: "arrow.up.left.and.arrow.down.right"
            case .favorites: "heart"
            case .views: "eye"
            }
        }

        func apply(to wallpapers: [Wallpaper], ascending: Bool) -> [Wallpaper] {
            let sorted: [Wallpaper]
            switch self {
            case .dateAdded:
                // Wallhaven's own upload date, as a string that sorts
                // correctly because it is written year-first.
                sorted = wallpapers.sorted { $0.createdAt < $1.createdAt }
            case .name:
                sorted = wallpapers.sorted { $0.id < $1.id }
            case .size:
                sorted = wallpapers.sorted { $0.fileSize < $1.fileSize }
            case .resolution:
                sorted = wallpapers.sorted { pixels(of: $0) < pixels(of: $1) }
            case .favorites:
                sorted = wallpapers.sorted { $0.favorites < $1.favorites }
            case .views:
                sorted = wallpapers.sorted { $0.views < $1.views }
            }
            return ascending ? sorted : sorted.reversed()
        }

        private func pixels(of wallpaper: Wallpaper) -> Int {
            let parts = wallpaper.resolution.split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return 0 }
            return w * h
        }
    }

    var remoteSort: RemoteSort = .dateAdded {
        didSet { save(remoteSort.rawValue, "remoteSort") }
    }
    /// Newest and most-favourited first is what people want by default, so
    /// these lists start descending where the local ones start ascending.
    var remoteSortAscending = false {
        didSet { save(remoteSortAscending, "remoteSortAscending") }
    }
    var remoteSearch = ""

    /// Sorted and filtered, for a collection or the downloaded list.
    func arranged(_ wallpapers: [Wallpaper]) -> [Wallpaper] {
        let needle = remoteSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? wallpapers : wallpapers.filter { wallpaper in
            wallpaper.id.lowercased().contains(needle)
                || wallpaper.tags.contains { $0.lowercased().contains(needle) }
                || (wallpaper.uploader?.lowercased().contains(needle) ?? false)
                || wallpaper.resolution.contains(needle)
        }
        return remoteSort.apply(to: filtered, ascending: remoteSortAscending)
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

    /// Whether the inspector should be showing.
    ///
    /// Clicking the image expands it to fill the window, and that is a request
    /// for the whole window — so the inspector yields whatever the width.
    /// Otherwise it stays as long as the image column still has room to read
    /// as a preview beside it.
    static func inspectorFits(windowWidth: CGFloat, expanded: Bool) -> Bool {
        if expanded { return false }
        return windowWidth - inspectorWidth >= minimumPreviewWidth
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

    /// How far expanding may scale an image past the size that fits.
    ///
    /// Filling the pane is the right answer for a wallpaper roughly the pane's
    /// shape. It is the wrong one for a portrait in a landscape window: filling
    /// there shows a narrow vertical slice and throws most of the picture off
    /// the edges. Capping the scale means expanding always shows more detail
    /// without the image leaving the window it is being viewed in.
    static let maximumExpansion: CGFloat = 1.6

    /// The size an image should be drawn at inside a pane.
    ///
    /// Fitted, it is the largest that fits whole. Expanded, it grows towards
    /// filling but no further than `maximumExpansion` — so a 2:3 portrait in a
    /// 16:9 window, which would need 2.7x to fill, stops at 1.6x and stays
    /// mostly on screen.
    static func drawnSize(image: CGSize, in container: CGSize,
                          expanded: Bool) -> CGSize {
        guard image.width > 0, image.height > 0,
              container.width > 0, container.height > 0 else { return container }

        let fit = min(container.width / image.width, container.height / image.height)
        guard expanded else {
            return CGSize(width: image.width * fit, height: image.height * fit)
        }
        let fill = max(container.width / image.width, container.height / image.height)
        let scale = min(fill, fit * maximumExpansion)
        return CGSize(width: image.width * scale, height: image.height * scale)
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
        let queueable = picked.filter { wallpaper in
            !downloads.contains { $0.wallpaperId == wallpaper.id } && !isDownloaded(wallpaper)
        }
        guard !queueable.isEmpty else { return }

        Task {
            // One print per wallpaper against the library, before any of it is
            // downloaded. On a page of two dozen that is a second or so, and it
            // is the difference between filing twenty and filing eight.
            var wanted: [Wallpaper] = []
            var skipped: [String] = []
            for wallpaper in queueable {
                if await alreadyInLibrary(wallpaper) != nil {
                    skipped.append(wallpaper.id)
                } else {
                    wanted.append(wallpaper)
                }
            }
            lastSkippedDuplicates = skipped

            guard !wanted.isEmpty else {
                errorMessage = "All \(skipped.count) are already in your library."
                return
            }
            do {
                try await LumenCore.shared.download(
                    wanted.map { (id: $0.id, url: $0.path.absoluteString, filename: $0.filename) },
                    directory: destinationDirectory)
                for wallpaper in wanted { fileIntoDestination(wallpaper) }
                if !skipped.isEmpty {
                    errorMessage = "Downloading \(wanted.count); skipped \(skipped.count) "
                        + "already in your library."
                }
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
    /// The category of the wallpaper a focus page was opened from, so the page
    /// cannot exclude it. See `query(prefix:_:)`.
    @ObservationIgnored private var focusSeedCategory: Category?

    /// Whether a tag or uploader page is narrowed by the browse filters.
    ///
    /// Off by default. Opening someone's work is a request to see *their work*,
    /// and inheriting a General-only filter from the last search silently
    /// removed every anime wallpaper they had posted — including, often, the
    /// one that was clicked through from.
    var focusUsesFilters = false {
        didSet {
            save(focusUsesFilters, "focusUsesFilters")
            Task { await reloadFocus() }
        }
    }

    /// How a tag or uploader page is ordered. Newest first by default, which is
    /// what "show me their work" usually means; toplist is the other useful
    /// answer and is one click away.
    var focusSorting: Sorting = .dateAdded {
        didSet {
            save(focusSorting.rawValue, "focusSorting")
            Task { await reloadFocus() }
        }
    }

    @MainActor
    func reloadFocus() async {
        guard focus != nil else { return }
        await loadFocus(reset: true)
    }
    var focusWallpapers: [Wallpaper] = []
    var focusPage = 1
    var focusLastPage = 1
    var isLoadingFocus = false
    var focusTotal = 0

    /// Extra context for the pane: an uploader's collections, or a tag's record.
    var uploaderCollections: [UploaderCollection] = []
    var tagInfo: TagInfo?

    /// `from` is the wallpaper the page was opened from, when there is one.
    ///
    /// Its category is added to the scope, because inheriting the browse
    /// filter alone can exclude the very wallpaper that was clicked through:
    /// open an anime wallpaper's uploader while browsing General only and the
    /// page comes back without it, or empty if that is all they post.
    @MainActor
    func showUploader(_ name: String, from wallpaper: Wallpaper? = nil) async {
        beginFocus(.uploader(name), seenIn: wallpaper?.category)
        // Public collections are a bonus; a failure there must not hold up the
        // wallpapers, so it runs alongside rather than before.
        async let collections = try? await LumenCore.shared.uploaderCollections(username: name)
        await loadFocus(reset: true)
        uploaderCollections = await collections ?? []
    }

    @MainActor
    func showTag(_ ref: TagRef, from wallpaper: Wallpaper? = nil) async {
        beginFocus(.tag(ref), seenIn: wallpaper?.category)
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
    private func beginFocus(_ next: Focus, seenIn category: String? = nil) {
        focusSeedCategory = category.flatMap { Category(rawValue: $0.lowercased()) }
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
        if focusUsesFilters {
            scoped.categories = filters.categories
            // Whatever was clicked through from belongs on the page it opened,
            // even when the filters would have excluded it.
            if let seed = focusSeedCategory { scoped.categories.insert(seed) }
        } else {
            scoped.categories = [.general, .anime, .people]
        }
        // Purity is always inherited, filters on or off: it is about what you
        // are willing to be shown at all, not about narrowing a result set.
        scoped.purity = filters.purity
        scoped.query = prefix + value
        scoped.sorting = focusSorting
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
