import Foundation

// MARK: - Wallpaper

/// Decoded straight from the Rust core's `WallpaperDto`.
struct Wallpaper: Identifiable, Hashable, Codable {
    let id: String
    let url: URL?           // wallhaven page
    let path: URL           // full-resolution file
    let thumb: URL          // grid thumbnail
    let resolution: String
    let ratio: Double
    let views: Int
    let favorites: Int
    let category: String
    let purity: Purity
    let fileSize: Int
    let fileType: String
    let createdAt: String
    /// Wallhaven username of the uploader. Search `@name` for their uploads.
    var uploader: String?
    /// Dominant palette, hex without a leading `#`.
    var colors: [String] = []
    var tags: [String] = []
    var localFile: URL?     // set once downloaded; preview prefers it

    var displayResolution: String { resolution.replacingOccurrences(of: "x", with: " × ") }
    var previewSource: URL { localFile ?? path }
    var sizeMB: String { String(format: "%.1f MB", Double(fileSize) / 1_048_576) }
    var filename: String { "wallhaven-\(id).\(fileType.hasSuffix("png") ? "png" : "jpg")" }

    /// Minimal identity the core needs to act on this wallpaper.
    var wirePayload: [String: Any] { ["id": id] }
}

enum Purity: String, Codable, CaseIterable {
    case sfw, sketchy, nsfw
}

enum Category: String, Codable, CaseIterable, Identifiable {
    case general, anime, people
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum Sorting: String, Codable, CaseIterable, Identifiable {
    case toplist, dateAdded = "date_added", views, favorites, random, relevance
    var id: String { rawValue }
    var label: String {
        switch self {
        case .toplist: "Top"
        case .dateAdded: "Latest"
        case .views: "Views"
        case .favorites: "Favorites"
        case .random: "Random"
        case .relevance: "Relevance"
        }
    }
}

enum ResolutionMode: String, Codable, CaseIterable, Identifiable {
    case atLeast, exactly
    var id: String { rawValue }
    var label: String { self == .atLeast ? "At Least" : "Exactly" }
}

// MARK: - Filters

/// Everything the Wallhaven `/search` endpoint accepts, in one value type.
/// Serialised to the core's `FiltersDto`.
struct SearchFilters: Equatable, Codable {
    var query = ""
    var categories: Set<Category> = [.general, .anime]
    var purity: Set<Purity> = [.sfw]
    var sorting: Sorting = .toplist
    var ascending = false
    var topRange = "1M"
    var mode: ResolutionMode = .atLeast
    var resolution = "1920x1080"
    var ratios: Set<String> = []
    var color: String?

    static let ratioOptions = ["16x9", "16x10", "21x9", "4x3", "1x1", "9x16", "10x16"]
    static let resolutionOptions = ["1920x1080", "2560x1440", "3440x1440",
                                    "3840x2160", "5120x2880", "6016x3384"]
    static let topRanges = ["1d", "3d", "1w", "1M", "3M", "6M", "1y"]

    /// Wallhaven's palette, in the site's own order.
    static let colorOptions = ["660000", "990000", "cc0000", "cc3333", "ea4c88", "993399",
                               "663399", "333399", "0066cc", "0099cc", "66cccc", "77cc33",
                               "669900", "336600", "666600", "999900", "cccc33", "ffff00",
                               "ffcc33", "ff9900", "ff6600", "cc6633", "996633", "663300",
                               "000000", "999999", "cccccc", "ffffff", "424153"]

    private enum CodingKeys: String, CodingKey {
        case query, categories, purity, sorting, ascending, topRange, mode, resolution, ratios, color
    }

    var activeCount: Int {
        var n = 0
        if categories != [.general, .anime] { n += 1 }
        if purity != [.sfw] { n += 1 }
        if mode != .atLeast { n += 1 }
        if resolution != "1920x1080" { n += 1 }
        n += ratios.isEmpty ? 0 : 1
        n += color == nil ? 0 : 1
        return n
    }

    func wirePayload(page: Int, seed: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "query": query,
            "categories": categories.map(\.rawValue).sorted(),
            "purity": purity.map(\.rawValue).sorted(),
            "sorting": sorting.rawValue,
            "ascending": ascending,
            "topRange": topRange,
            "mode": mode.rawValue,
            "resolution": resolution,
            "ratios": ratios.sorted(),
            "page": page
        ]
        if let color { payload["color"] = color }
        if let seed, !seed.isEmpty { payload["seed"] = seed }
        return payload
    }
}

// MARK: - Search results

struct SearchPage: Decodable {
    let wallpapers: [Wallpaper]
    let currentPage: Int
    let lastPage: Int
    let total: Int
    /// Present for a random sort; must be sent back to keep later pages
    /// consistent with the first.
    let seed: String?
}

// MARK: - Downloads

/// Mirrors the core's `DownloadDto`. The core owns download state; the UI only
/// renders it, and looks the matching wallpaper up by `wallpaperId`.
struct DownloadTask: Identifiable, Decodable, Equatable {
    enum State: String, Decodable {
        case queued = "Queued", active = "Active", done = "Done"
        case failed = "Failed", cancelled = "Cancelled"
    }

    let id: String
    let wallpaperId: String
    let filename: String
    let state: State
    let progress: Double
    let localFile: URL?
    let error: String?
    let speedBps: Int

    var speedLabel: String {
        guard speedBps > 0, state == .active else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(speedBps), countStyle: .file) + "/s"
    }
}

// MARK: - Collections & displays

/// A named set of filters the user saved, so a search they tuned once can be
/// recalled instead of rebuilt.
struct FilterPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var filters: SearchFilters
}

/// A named set of wallpapers, stored by the core. Membership is independent of
/// favouriting, and one wallpaper can sit in several collections.
struct Collection: Identifiable, Hashable, Decodable {
    let id: String
    var name: String
    var wallpapers: [Wallpaper] = []
}

/// Where a set applies. macOS gives each Space its own desktop picture, and
/// `NSWorkspace` only ever writes the one you are looking at.
enum WallpaperScope: String, Codable, CaseIterable, Identifiable {
    case thisSpace, allSpaces
    var id: String { rawValue }
    var label: String { self == .thisSpace ? "This Space" : "All Spaces" }
}

struct DisplayTarget: Identifiable, Hashable {
    enum Fit: String, CaseIterable, Identifiable {
        case fill = "Fill", fit = "Fit", stretch = "Stretch"
        var id: String { rawValue }
    }
    let id: String
    let name: String
    let resolution: String
    let aspect: Double
    var fit: Fit = .fill
    var wallpaper: Wallpaper?
}

// MARK: - Appearance

enum GridTheme: String, Codable, CaseIterable, Identifiable {
    case compact, comfortable, cinema, masonry
    var id: String { rawValue }
    var label: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Grid"
        case .cinema: "Cinema"
        case .masonry: "Masonry"
        }
    }
    var minTileWidth: CGFloat {
        switch self {
        case .compact: 190
        case .comfortable: 280
        case .cinema: 420
        case .masonry: 250
        }
    }
    var spacing: CGFloat { self == .compact ? 10 : self == .cinema ? 20 : 14 }
    var cornerRadius: CGFloat { self == .cinema ? 14 : Tokens.tile }
}

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
