import SwiftUI
import Observation

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

    // Preferences (persisted)
    @ObservationIgnored @AppStorage("apiKey") var apiKey = ""
    @ObservationIgnored @AppStorage("downloadDirectory") var downloadDirectory = ""
    @ObservationIgnored @AppStorage("maxParallel") var maxParallel = 4
    @ObservationIgnored @AppStorage("gridTheme") var gridThemeRaw = GridTheme.comfortable.rawValue
    @ObservationIgnored @AppStorage("appearance") var appearanceRaw = Appearance.system.rawValue
    @ObservationIgnored @AppStorage("rotationEnabled") var rotationEnabled = true
    @ObservationIgnored @AppStorage("rotationMinutes") var rotationMinutes = 60
    @ObservationIgnored @AppStorage("rotationSource") var rotationSource = "Favorites"
    @ObservationIgnored @AppStorage("shuffle") var shuffle = true
    @ObservationIgnored @AppStorage("preferLocalPreview") var preferLocalPreview = true
    @ObservationIgnored @AppStorage("showPurityBorders") var showPurityBorders = true
    @ObservationIgnored @AppStorage("pauseOnBattery") var pauseOnBattery = false

    var gridTheme: GridTheme {
        get { GridTheme(rawValue: gridThemeRaw) ?? .comfortable }
        set { gridThemeRaw = newValue.rawValue }
    }
    var appearance: Appearance {
        get { Appearance(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }

    private var client: WallhavenClient { WallhavenClient(apiKey: apiKey) }
    private var saveDirectory: URL {
        downloadDirectory.isEmpty
        ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appending(path: "Walder")
        : URL(filePath: downloadDirectory)
    }

    // MARK: Search

    @MainActor
    func search(reset: Bool = true) async {
        if reset { page = 1 }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.search(filters, page: page)
            lastPage = result.lastPage
            wallpapers = reset ? result.wallpapers : wallpapers + result.wallpapers
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
        guard let detailed = try? await client.details(id: wallpaper.id) else { return }
        if let index = wallpapers.firstIndex(of: wallpaper) { wallpapers[index].tags = detailed.tags }
    }

    // MARK: Library

    func isFavorite(_ wallpaper: Wallpaper) -> Bool { favorites.contains { $0.id == wallpaper.id } }

    func toggleFavorite(_ wallpaper: Wallpaper) {
        withAnimation(Tokens.bouncy) {
            if let index = favorites.firstIndex(where: { $0.id == wallpaper.id }) {
                favorites.remove(at: index)
            } else {
                favorites.append(wallpaper)
            }
        }
    }

    func createCollection(named name: String, seeding favorites: Bool = false) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        withAnimation(Tokens.normal) {
            collections.append(Collection(name: name, items: favorites ? self.favorites : []))
        }
    }

    // MARK: Downloads

    @MainActor
    func download(_ wallpaper: Wallpaper) {
        guard !downloads.contains(where: { $0.id == wallpaper.id }) else { return }
        var task = DownloadTask(id: wallpaper.id, wallpaper: wallpaper, state: .active)
        withAnimation(Tokens.normal) { downloads.insert(task, at: 0) }

        Task {
            do {
                try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
                let destination = saveDirectory.appending(path: task.filename)
                let (bytes, response) = try await URLSession.shared.bytes(from: wallpaper.path)
                let expected = max(response.expectedContentLength, 1)
                var data = Data(capacity: Int(expected))
                var lastReported = 0.0
                for try await byte in bytes {
                    data.append(byte)
                    let fraction = Double(data.count) / Double(expected)
                    if fraction - lastReported > 0.01 {
                        lastReported = fraction
                        await MainActor.run { self.update(task.id) { $0.progress = fraction } }
                    }
                }
                try data.write(to: destination, options: .atomic)
                task.localFile = destination
                await MainActor.run {
                    self.update(task.id) { $0.progress = 1; $0.state = .done; $0.localFile = destination }
                    if let index = self.wallpapers.firstIndex(of: wallpaper) {
                        self.wallpapers[index].localFile = destination
                    }
                }
            } catch {
                await MainActor.run {
                    self.update(task.id) { $0.state = .failed; $0.error = error.localizedDescription }
                }
            }
        }
    }

    private func update(_ id: String, _ mutate: (inout DownloadTask) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Tokens.quick) { mutate(&downloads[index]) }
    }

    @MainActor func clearFinished() {
        withAnimation(Tokens.normal) { downloads.removeAll { $0.state == .done } }
    }

    @MainActor func retryFailed() {
        for task in downloads where task.state == .failed { download(task.wallpaper) }
        withAnimation(Tokens.quick) { downloads.removeAll { $0.state == .failed } }
    }

    // MARK: Applying

    /// Downloads first if needed — setDesktopImageURL only accepts local files.
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
        Task {
            let fit = display?.fit ?? .fill
            let screen = display.flatMap { target in
                NSScreen.screens.first { $0.localizedName == target.name }
            }
            if let local = wallpaper.localFile {
                try? WallpaperSetter.apply(fileURL: local, to: screen, fit: fit)
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: wallpaper.path) else { return }
            let cache = FileManager.default.temporaryDirectory
                .appending(path: "walder-\(wallpaper.id).\(wallpaper.fileType.hasSuffix("png") ? "png" : "jpg")")
            try? data.write(to: cache)
            try? WallpaperSetter.apply(fileURL: cache, to: screen, fit: fit)
        }
    }

    @MainActor
    func shuffleNow() {
        let pool: [Wallpaper]
        switch rotationSource {
        case "Downloads": pool = downloads.filter { $0.state == .done }.map(\.wallpaper)
        case "Collection": pool = collections.flatMap(\.items)
        default: pool = favorites.isEmpty ? wallpapers : favorites
        }
        guard let pick = shuffle ? pool.randomElement() : pool.first else { return }
        setWallpaper(pick)
    }
}
