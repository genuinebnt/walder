import Foundation
import ImageIO
import CoreGraphics

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
    /// Tags with their identity, so a tag page can be opened from one.
    var tagRefs: [TagRef] = []
    var localFile: URL?     // set once downloaded; preview prefers it

    var displayResolution: String { resolution.replacingOccurrences(of: "x", with: " × ") }
    var previewSource: URL { localFile ?? path }
    var sizeMB: String { String(format: "%.1f MB", Double(fileSize) / 1_048_576) }
    var filename: String { "wallhaven-\(id).\(fileType.hasSuffix("png") ? "png" : "jpg")" }

    /// Minimal identity the core needs to act on this wallpaper.
    var wirePayload: [String: Any] { ["id": id] }
}

/// A tag as it appears on a wallpaper.
struct TagRef: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let category: String
    let purity: Purity
}

/// What Wallhaven knows about a tag beyond its name.
struct TagInfo: Identifiable, Hashable, Decodable {
    let id: Int
    let name: String
    let alias: String?
    let category: String
    let purity: Purity
    let createdAt: String?

    /// Alias list as Wallhaven writes it, comma separated.
    var aliases: [String] {
        (alias ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// One of an uploader's public collections on Wallhaven. Distinct from the
/// local `Collection`, which Lumen stores itself.
struct UploaderCollection: Identifiable, Hashable, Decodable {
    let id: Int
    let label: String
    let count: Int
    let views: Int
    let published: Bool

    private enum CodingKeys: String, CodingKey {
        case id, label, count, views
        case published = "public"
    }
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
    case toplist, hot, dateAdded = "date_added", views, favorites, random, relevance
    var id: String { rawValue }
    var label: String {
        switch self {
        case .toplist: "Top"
        case .hot: "Hot"
        case .dateAdded: "Latest"
        case .views: "Views"
        case .favorites: "Favorites"
        case .random: "Random"
        case .relevance: "Relevance"
        }
    }
}

/// Wallhaven's `type:` operator. It only distinguishes JPEG from PNG.
enum FileTypeFilter: String, Codable, CaseIterable, Identifiable {
    case any, jpg, png
    var id: String { rawValue }
    var label: String { self == .any ? "Any" : rawValue.uppercased() }
    var queryTerm: String? { self == .any ? nil : "type:\(rawValue)" }
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
    var resolution = SearchFilters.anyResolution
    /// Exact mode accepts several resolutions; At Least takes one.
    var exactResolutions: Set<String> = []
    var ratios: Set<String> = []
    var color: String?
    /// nil leaves AI art alone, false hides it, true shows only it.
    var aiArt: Bool?
    /// Wallhaven's `type:` operator.
    var fileType: FileTypeFilter = .any
    /// Tags to exclude, sent as `-tag`. The site supports this; the app did not.
    var excludedTags: Set<String> = []

    /// Every ratio Wallhaven accepts, in the site's own grouping. `landscape`
    /// and `portrait` are keywords it understands alongside exact ratios.
    static let ratioOptions = ["16x9", "16x10", "21x9", "32x9", "48x9",
                               "9x16", "10x16", "9x18",
                               "1x1", "3x2", "4x3", "5x4"]

    /// The site's resolution list, grouped by shape. Picking from a flat list
    /// of six was the reason this used to feel narrower than wallhaven.cc.
    static let resolutionGroups: [(label: String, sizes: [String])] = [
        ("16 × 9",  ["1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160"]),
        ("16 × 10", ["1280x800", "1600x1000", "1920x1200", "2560x1600", "3840x2400"]),
        ("4 × 3",   ["1280x960", "1600x1200", "1920x1440", "2560x1920", "3840x2880"]),
        ("5 × 4",   ["1280x1024", "1600x1280", "1920x1536", "2560x2048", "3840x3072"]),
        ("Ultrawide", ["2560x1080", "3440x1440", "3840x1600", "5120x2160"]),
        ("Super ultrawide", ["3840x1080", "5120x1440", "3840x1200", "5120x1600"]),
        ("Triple", ["5760x1080", "7680x1440", "5760x1200"]),
        ("Very large", ["5120x2880", "6016x3384", "7680x4320"])
    ]

    static let resolutionOptions = resolutionGroups.flatMap(\.sizes)

    /// Empty means no resolution filter at all, which is how wallhaven.cc
    /// starts. The core sends no `atleast` or `resolutions` parameter for it.
    static let anyResolution = ""
    static let topRanges = ["1d", "3d", "1w", "1M", "3M", "6M", "1y"]

    /// Wallhaven's palette, in the site's own order.
    static let colorOptions = ["660000", "990000", "cc0000", "cc3333", "ea4c88", "993399",
                               "663399", "333399", "0066cc", "0099cc", "66cccc", "77cc33",
                               "669900", "336600", "666600", "999900", "cccc33", "ffff00",
                               "ffcc33", "ff9900", "ff6600", "cc6633", "996633", "663300",
                               "000000", "999999", "cccccc", "ffffff", "424153"]

    private enum CodingKeys: String, CodingKey {
        case query, categories, purity, sorting, ascending, topRange, mode
        case resolution, exactResolutions, ratios, color, aiArt
        case fileType, excludedTags
    }

    init() {}

    /// Every field is optional on the way in. The synthesised decoder throws
    /// when a key is missing, so adding one field would silently discard a
    /// user's saved filters on their next launch.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SearchFilters()
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? fallback.query
        categories = try container.decodeIfPresent(Set<Category>.self, forKey: .categories)
            ?? fallback.categories
        purity = try container.decodeIfPresent(Set<Purity>.self, forKey: .purity) ?? fallback.purity
        sorting = try container.decodeIfPresent(Sorting.self, forKey: .sorting) ?? fallback.sorting
        ascending = try container.decodeIfPresent(Bool.self, forKey: .ascending) ?? fallback.ascending
        topRange = try container.decodeIfPresent(String.self, forKey: .topRange) ?? fallback.topRange
        mode = try container.decodeIfPresent(ResolutionMode.self, forKey: .mode) ?? fallback.mode
        resolution = try container.decodeIfPresent(String.self, forKey: .resolution)
            ?? fallback.resolution
        exactResolutions = try container.decodeIfPresent(Set<String>.self, forKey: .exactResolutions)
            ?? fallback.exactResolutions
        ratios = try container.decodeIfPresent(Set<String>.self, forKey: .ratios) ?? fallback.ratios
        color = try container.decodeIfPresent(String.self, forKey: .color)
        aiArt = try container.decodeIfPresent(Bool.self, forKey: .aiArt)
        fileType = try container.decodeIfPresent(FileTypeFilter.self, forKey: .fileType)
            ?? fallback.fileType
        excludedTags = try container.decodeIfPresent(Set<String>.self, forKey: .excludedTags)
            ?? fallback.excludedTags
    }

    /// The `q` Wallhaven actually receives: what was typed, plus the structured
    /// operators the popover sets. Kept here so the core stays a plain
    /// pass-through and the operators are testable on their own.
    var composedQuery: String {
        var terms: [String] = []
        let typed = query.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { terms.append(typed) }
        if let fileTerm = fileType.queryTerm { terms.append(fileTerm) }
        terms += excludedTags.sorted().map { "-\($0)" }
        return terms.joined(separator: " ")
    }

    var activeCount: Int {
        var n = 0
        if categories != [.general, .anime] { n += 1 }
        if purity != [.sfw] { n += 1 }
        if mode != .atLeast { n += 1 }
        if !resolution.isEmpty { n += 1 }
        n += exactResolutions.isEmpty ? 0 : 1
        n += ratios.isEmpty ? 0 : 1
        n += color == nil ? 0 : 1
        n += aiArt == nil ? 0 : 1
        n += fileType == .any ? 0 : 1
        n += excludedTags.isEmpty ? 0 : 1
        return n
    }

    func wirePayload(page: Int, seed: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "query": composedQuery,
            "categories": categories.map(\.rawValue).sorted(),
            "purity": purity.map(\.rawValue).sorted(),
            "sorting": sorting.rawValue,
            "ascending": ascending,
            "topRange": topRange,
            "mode": mode.rawValue,
            "resolution": resolution,
            "exactResolutions": exactResolutions.sorted(),
            "ratios": ratios.sorted(),
            "page": page
        ]
        if let color { payload["color"] = color }
        if let aiArt { payload["aiArt"] = aiArt }
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

/// How a wallpaper sits on a particular display.
///
/// macOS fills the screen and crops the overflow, so "does it fit" is really
/// two questions: how much of the image is lost to the crop, and is there
/// enough resolution to avoid softness. Wallhaven serves one file per
/// wallpaper — there is no alternate-resolution download — so the answer when
/// it does not fit is either a better-matching wallpaper or a local resize.
struct DisplayFit {
    let image: CGSize          // pixels
    let display: CGSize        // pixels

    /// Scale needed to cover the display.
    var fillScale: Double {
        guard image.width > 0, image.height > 0 else { return 1 }
        return max(display.width / image.width, display.height / image.height)
    }

    /// Fraction of the image lost off the edges when filling, 0...1.
    var cropFraction: Double {
        guard image.width > 0, image.height > 0 else { return 0 }
        let covered = display.width * display.height
        let scaled = (image.width * fillScale) * (image.height * fillScale)
        guard scaled > 0 else { return 0 }
        return max(0, 1 - covered / scaled)
    }

    /// True when the image has to be enlarged, which softens it.
    var upscales: Bool { fillScale > 1.001 }

    /// Same shape and at least as many pixels: nothing is lost either way.
    var isPerfect: Bool { !upscales && cropFraction < 0.01 }

    /// Loses a sliver at most — not worth flagging.
    var isGood: Bool { !upscales && cropFraction < 0.08 }

    var summary: String {
        if isPerfect { return "Fits this display exactly" }
        if upscales && cropFraction >= 0.08 {
            return "Upscaled \(percent(fillScale - 1)) and crops \(percent(cropFraction))"
        }
        if upscales { return "Below your display — upscaled \(percent(fillScale - 1))" }
        if cropFraction >= 0.08 { return "Crops \(percent(cropFraction)) to fill" }
        return "Fits, crops \(percent(cropFraction))"
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// A folder of wallpapers already on disk — Lumen's downloads, or anything
/// else the user points it at.
struct ImportedFolder: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let path: String
    let count: Int

    var url: URL { URL(filePath: path) }
}

/// One image inside an imported folder. Has no Wallhaven identity, so it
/// carries only what the filesystem knows.
struct LocalWallpaper: Identifiable, Hashable, Decodable {
    let id: String
    let folderId: String
    let url: URL
    let path: String
    let filename: String
    let fileSize: Int
    var isFavorite: Bool

    var sizeMB: String { String(format: "%.1f MB", Double(fileSize) / 1_048_576) }

    /// Pixel size, read from the file's header rather than by decoding it.
    var pixelSize: CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        return CGSize(width: width, height: height)
    }

    var displayResolution: String {
        guard let size = pixelSize else { return "—" }
        return "\(Int(size.width)) × \(Int(size.height))"
    }
}

/// One wallpaper that has actually been on the desktop.
struct HistoryEntry: Identifiable, Hashable, Decodable {
    let wallpaperId: String?
    let url: URL
    let label: String
    let setAt: String

    var id: String { "\(setAt)|\(url.path)" }

    /// "Sun 6 Sep, 11:22 pm" from SQLite's own timestamp format.
    var when: String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        parser.timeZone = TimeZone(identifier: "UTC")
        guard let date = parser.date(from: setAt) else { return setAt }
        let display = DateFormatter()
        display.dateFormat = "EEE d MMM, h:mm a"
        return display.string(from: date)
    }
}

/// A saved search that Lumen re-runs in the background.
struct Subscription: Identifiable, Hashable, Decodable {
    let id: String
    let query: String
    let label: String
    let minFavorites: Int
    /// Matches found since the last time this was looked at.
    let unseen: Int
}

/// What one subscription turned up on a check.
struct RadarResult: Identifiable, Decodable {
    let id: String
    let label: String
    let newMatches: Int
    let wallpapers: [Wallpaper]
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
