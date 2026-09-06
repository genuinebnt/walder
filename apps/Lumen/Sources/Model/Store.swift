import SwiftUI
import Observation
import IOKit.ps

/// App state. Every network, disk and database operation is delegated to the
/// Rust core through `LumenCore`; this type holds only what the views render.
@Observable
final class Store {
    // Browsing
    var filters = SearchFilters()
    var wallpapers: [Wallpaper] = []
    var page = 1
    var lastPage = 1
    var isLoading = false
    var errorMessage: String?

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

    // Preferences (persisted by AppKit, mirrored into the core)
    @ObservationIgnored @AppStorage("apiKey") var apiKey = "" { didSet { pushPreferences() } }
    @ObservationIgnored @AppStorage("downloadDirectory") var downloadDirectory = "" { didSet { pushPreferences() } }
    @ObservationIgnored @AppStorage("maxParallel") var maxParallel = 4
    @ObservationIgnored @AppStorage("gridTheme") var gridThemeRaw = GridTheme.comfortable.rawValue
    @ObservationIgnored @AppStorage("appearance") var appearanceRaw = Appearance.system.rawValue
    @ObservationIgnored @AppStorage("rotationEnabled") var rotationEnabled = true { didSet { rearmRotation() } }
    @ObservationIgnored @AppStorage("rotationMinutes") var rotationMinutes = 60 { didSet { rearmRotation() } }
    @ObservationIgnored @AppStorage("rotationSource") var rotationSource = "Favorites"
    @ObservationIgnored @AppStorage("shuffle") var shuffle = true
    @ObservationIgnored @AppStorage("preferLocalPreview") var preferLocalPreview = true
    @ObservationIgnored @AppStorage("menuBarEnabled") var menuBarEnabled = true
    @ObservationIgnored @AppStorage("showPurityBorders") var showPurityBorders = true
    @ObservationIgnored @AppStorage("pauseOnBattery") var pauseOnBattery = false { didSet { rearmRotation() } }

    var gridTheme: GridTheme {
        get { GridTheme(rawValue: gridThemeRaw) ?? .comfortable }
        set { gridThemeRaw = newValue.rawValue }
    }
    var appearance: Appearance {
        get { Appearance(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
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
        LumenCore.shared.setPreferences(apiKey: apiKey, downloadDirectory: downloadDirectory)
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
        if reset { page = 1 }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await LumenCore.shared.search(filters, page: page)
            lastPage = max(result.lastPage, 1)
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
                let path = try await LumenCore.shared.ensureLocal(url: wallpaper.path.absoluteString,
                                                                  filename: wallpaper.filename)
                let local = URL(filePath: path)
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
        LumenCore.shared.setPreferences(apiKey: apiKey, downloadDirectory: downloadDirectory)
        rearmRotation()
        withAnimation(Tokens.quick) { savedConfirmation = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(Tokens.normal) { savedConfirmation = false }
        }
    }
}
