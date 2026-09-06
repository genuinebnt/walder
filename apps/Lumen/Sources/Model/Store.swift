import SwiftUI
import Observation
import IOKit.ps

/// App state. Every network, disk and database operation is delegated to the
/// Rust core through `LumenCore`; this type holds only what the views render.
@Observable
final class Store {
    // Browsing
    var filters: SearchFilters
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
        showPurityBorders = bool("showPurityBorders", default: true)
        pauseOnBattery = bool("pauseOnBattery", default: false)
        presets = Self.loadJSON([FilterPreset].self, "filterPresets", from: defaults) ?? []

        // The filter set from last launch, so a tuned search survives a restart.
        filters = Self.loadJSON(SearchFilters.self, "lastFilters", from: defaults) ?? SearchFilters()
    }

    /// Records the current filters as the ones to restore next launch.
    func rememberFilters() { saveJSON(filters, "lastFilters") }

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

    @MainActor
    func loadTags(for wallpaper: Wallpaper) async {
        guard wallpaper.tags.isEmpty else { return }
        guard let detailed = try? await LumenCore.shared.details(id: wallpaper.id) else { return }
        if let index = wallpapers.firstIndex(where: { $0.id == wallpaper.id }) {
            wallpapers[index].tags = detailed.tags
        }
        known[wallpaper.id]?.tags = detailed.tags
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

    @MainActor
    func createCollection(named name: String, seeding seedFromFavorites: Bool = false) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        withAnimation(Tokens.normal) {
            collections.append(Collection(name: name, items: seedFromFavorites ? favorites : []))
        }
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
    func setWallpaper(_ wallpaper: Wallpaper, on display: DisplayTarget? = nil) {
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
                try WallpaperSetter.apply(fileURL: local, to: screen, fit: fit)
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
        case "Collection": pool = collections.flatMap(\.items)
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
}
