import Foundation

/// Thin async client for wallhaven.cc/api/v1.
struct WallhavenClient {
    var apiKey: String?
    private let base = URL(string: "https://wallhaven.cc/api/v1/")!

    struct Page { var wallpapers: [Wallpaper]; var lastPage: Int }

    func search(_ filters: SearchFilters, page: Int) async throws -> Page {
        var components = URLComponents(url: base.appending(path: "search"), resolvingAgainstBaseURL: false)!
        components.queryItems = filters.queryItems(page: page, apiKey: apiKey)
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try Self.check(response)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return Page(wallpapers: decoded.data.map(\.wallpaper),
                    lastPage: decoded.meta?.last_page ?? page)
    }

    /// Detail endpoint — the only place tags and the uploader come from.
    func details(id: String) async throws -> Wallpaper {
        var components = URLComponents(url: base.appending(path: "w/\(id)"), resolvingAgainstBaseURL: false)!
        if let apiKey, !apiKey.isEmpty { components.queryItems = [.init(name: "apikey", value: apiKey)] }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try Self.check(response)
        return try JSONDecoder().decode(DetailResponse.self, from: data).data.wallpaper
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw ClientError.unauthorized
        case 429: throw ClientError.rateLimited
        default: throw ClientError.http(http.statusCode)
        }
    }

    enum ClientError: LocalizedError {
        case unauthorized, rateLimited, http(Int)
        var errorDescription: String? {
            switch self {
            case .unauthorized: "Wallhaven rejected the API key. Check it in Settings."
            case .rateLimited: "Rate limited by Wallhaven — 45 requests/minute without a key."
            case .http(let code): "Wallhaven returned HTTP \(code)."
            }
        }
    }
}

// MARK: - Wire format

private struct SearchResponse: Decodable { let data: [APIWallpaper]; let meta: Meta?
    struct Meta: Decodable { let last_page: Int? } }
private struct DetailResponse: Decodable { let data: APIWallpaper }

private struct APIWallpaper: Decodable {
    let id: String
    let url: String?
    let path: String
    let thumbs: Thumbs
    let resolution: String
    let ratio: String
    let views: Int
    let favorites: Int
    let category: String
    let purity: String
    let file_size: Int
    let file_type: String
    let created_at: String
    let tags: [Tag]?

    struct Thumbs: Decodable { let large: String; let original: String; let small: String }
    struct Tag: Decodable { let name: String }

    var wallpaper: Wallpaper {
        Wallpaper(id: id,
                  url: url.flatMap(URL.init(string:)),
                  path: URL(string: path)!,
                  thumb: URL(string: thumbs.large)!,
                  resolution: resolution,
                  ratio: Double(ratio) ?? 1.777,
                  views: views,
                  favorites: favorites,
                  category: category,
                  purity: Purity(rawValue: purity) ?? .sfw,
                  fileSize: file_size,
                  fileType: file_type,
                  createdAt: String(created_at.prefix(10)),
                  tags: tags?.map(\.name) ?? [])
    }
}
