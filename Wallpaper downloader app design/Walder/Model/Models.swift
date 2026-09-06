import Foundation

struct Wallpaper: Identifiable, Hashable, Codable {
    let id: String
    let url: URL?          // wallhaven page
    let path: URL          // full-resolution file
    let thumb: URL         // grid thumbnail
    let resolution: String
    let ratio: Double
    let views: Int
    let favorites: Int
    let category: String
    let purity: Purity
    let fileSize: Int
    let fileType: String
    let createdAt: String
    var tags: [String] = []
    var localFile: URL?    // set once downloaded; preview prefers it

    var displayResolution: String { resolution.replacingOccurrences(of: "x", with: " × ") }
    var previewSource: URL { localFile ?? path }
    var sizeMB: String { String(format: "%.1f MB", Double(fileSize) / 1_048_576) }
}

enum Purity: String, Codable, CaseIterable {
    case sfw, sketchy, nsfw
    var apiBit: Int { self == .sfw ? 0 : self == .sketchy ? 1 : 2 }
}

enum Category: String, Codable, CaseIterable, Identifiable {
    case general, anime, people
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum Sorting: String, CaseIterable, Identifiable {
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

enum ResolutionMode: String, CaseIterable, Identifiable {
    case atLeast, exactly
    var id: String { rawValue }
    var label: String { self == .atLeast ? "At Least" : "Exactly" }
}

/// Everything the Wallhaven /search endpoint accepts, in one value type.
struct SearchFilters: Equatable {
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

    func queryItems(page: Int, apiKey: String?) -> [URLQueryItem] {
        let catBits = Category.allCases.map { categories.contains($0) ? "1" : "0" }.joined()
        let purityBits = Purity.allCases.map { purity.contains($0) ? "1" : "0" }.joined()
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "categories", value: catBits),
            URLQueryItem(name: "purity", value: purityBits),
            URLQueryItem(name: "sorting", value: sorting.rawValue),
            URLQueryItem(name: "order", value: ascending ? "asc" : "desc")
        ]
        if !query.isEmpty { items.append(.init(name: "q", value: query)) }
        if sorting == .toplist { items.append(.init(name: "topRange", value: topRange)) }
        items.append(mode == .atLeast
                     ? .init(name: "atleast", value: resolution)
                     : .init(name: "resolutions", value: resolution))
        if !ratios.isEmpty { items.append(.init(name: "ratios", value: ratios.sorted().joined(separator: ","))) }
        if let color { items.append(.init(name: "colors", value: color)) }
        if let apiKey, !apiKey.isEmpty { items.append(.init(name: "apikey", value: apiKey)) }
        return items
    }
}

struct Collection: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var items: [Wallpaper] = []
}

struct DownloadTask: Identifiable {
    enum State: String { case queued = "Queued", active = "Active", done = "Done", failed = "Failed" }
    let id: String
    let wallpaper: Wallpaper
    var state: State = .queued
    var progress: Double = 0
    var localFile: URL?
    var error: String?
    var filename: String { "wallhaven-\(wallpaper.id).\(wallpaper.fileType.hasSuffix("png") ? "png" : "jpg")" }
}

struct DisplayTarget: Identifiable, Hashable {
    enum Fit: String, CaseIterable, Identifiable { case fill = "Fill", fit = "Fit", stretch = "Stretch"
        var id: String { rawValue } }
    let id: String
    let name: String
    let resolution: String
    let aspect: Double
    var fit: Fit = .fill
    var wallpaper: Wallpaper?
}

enum GridTheme: String, CaseIterable, Identifiable {
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

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
