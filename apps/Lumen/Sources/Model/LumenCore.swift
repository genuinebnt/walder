import Foundation

/// Swift face of the Rust core.
///
/// The C layer is request/response with a single callback: every async call
/// returns a request id, and the reply arrives later carrying that id. This
/// class turns that into `async throws` by parking a continuation per id.
/// Request id `0` is reserved for unsolicited pushes (download progress).
final class LumenCore: @unchecked Sendable {
    static let shared = LumenCore()

    /// Fired whenever Rust pushes a new download list.
    var onDownloads: (@Sendable ([DownloadTask]) -> Void)?

    private let lock = NSLock()
    private var waiting: [UInt64: CheckedContinuation<Data, Error>] = [:]

    private init() {}

    // MARK: Lifecycle

    /// Boots the Rust runtime. Safe to call again to reconfigure.
    @discardableResult
    func start(apiKey: String, downloadDirectory: String, maxParallel: Int) -> Bool {
        lumen_set_callback({ requestID, json, _ in
            guard let json else { return }
            let data = Data(String(cString: json).utf8)
            LumenCore.shared.deliver(requestID: requestID, data: data)
        }, nil)

        let config: [String: Any] = [
            "apiKey": apiKey,
            "downloadDir": downloadDirectory,
            "maxParallel": maxParallel
        ]
        let reply = Self.takeString(lumen_init(Self.json(config)))
        return (try? JSONDecoder().decode(Envelope<String>.self, from: Data(reply.utf8)))?.ok ?? false
    }

    var status: String { Self.takeString(lumen_status()) }

    var downloadDirectory: String { Self.takeString(lumen_download_dir()) }

    func setPreferences(apiKey: String, downloadDirectory: String, maxParallel: Int) {
        let payload: [String: Any] = [
            "apiKey": apiKey,
            "downloadDir": downloadDirectory,
            "maxParallel": maxParallel
        ]
        _ = Self.takeString(lumen_set_preferences(Self.json(payload)))
    }

    // MARK: Async calls

    func search(_ filters: SearchFilters, page: Int, seed: String? = nil) async throws -> SearchPage {
        try await call(SearchPage.self) {
            lumen_search(Self.json(filters.wirePayload(page: page, seed: seed)))
        }
    }

    func details(id: String) async throws -> Wallpaper {
        try await call(Wallpaper.self) { id.withCString { lumen_details($0) } }
    }

    func download(id: String, url: String, filename: String) async throws {
        _ = try await call(String.self) {
            lumen_download(Self.json(["id": id, "url": url, "filename": filename]))
        }
    }

    /// Downloads the file if it is not already on disk and returns its location.
    /// `NSWorkspace` only accepts local files, so this runs before every set.
    ///
    /// Returns a `URL`, not a string: the core sends a `file://` URL, and
    /// `URL(filePath:)` would read that as a relative path and point at
    /// nothing — which is exactly the bug this signature prevents.
    func ensureLocal(url: String, filename: String) async throws -> URL {
        let raw = try await call(String.self) {
            lumen_ensure_local(Self.json(["url": url, "filename": filename]))
        }
        guard let local = Self.fileURL(from: raw) else {
            throw CoreError.backend("The core returned an unusable path: \(raw)")
        }
        return local
    }

    /// Parses what the core sends for a local file. Accepts a bare path too, so
    /// an older payload still resolves.
    static func fileURL(from raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.isFileURL { return url }
        guard raw.hasPrefix("/") else { return nil }
        return URL(filePath: raw)
    }

    // MARK: Synchronous calls

    func downloadsSnapshot() -> [DownloadTask] {
        decodeSync([DownloadTask].self, Self.takeString(lumen_downloads_snapshot())) ?? []
    }

    func clearFinishedDownloads() { _ = lumen_downloads_clear_finished() }

    func favorites() -> [Wallpaper] {
        decodeSync([Wallpaper].self, Self.takeString(lumen_favorites_list())) ?? []
    }

    // MARK: Collections

    func collections() -> [Collection] {
        decodeSync([Collection].self, Self.takeString(lumen_collections_list())) ?? []
    }

    func createCollection(named name: String) -> Collection? {
        name.withCString { decodeSync(Collection.self, Self.takeString(lumen_collection_create($0))) }
    }

    @discardableResult
    func deleteCollection(id: String) -> Bool {
        id.withCString { pointer in
            let reply = Self.takeString(lumen_collection_delete(pointer))
            return (try? JSONDecoder().decode(Envelope<String?>.self, from: Data(reply.utf8)))?.ok ?? false
        }
    }

    @discardableResult
    func setCollectionMember(collectionID: String, wallpaperID: String, member: Bool) -> Bool {
        let payload: [String: Any] = [
            "collectionId": collectionID,
            "wallpaperId": wallpaperID,
            "member": member
        ]
        let reply = Self.takeString(lumen_collection_set_member(Self.json(payload)))
        struct Flag: Decodable { let member: Bool }
        return decodeSync(Flag.self, reply)?.member == member
    }

    /// Returns the resulting state, or nil when the core rejected the toggle.
    func toggleFavorite(_ wallpaper: Wallpaper) -> Bool? {
        let reply = Self.takeString(lumen_favorite_toggle(Self.json(wallpaper.wirePayload)))
        struct Flag: Decodable { let favorited: Bool }
        return decodeSync(Flag.self, reply)?.favorited
    }

    // MARK: Plumbing

    private func call<T: Decodable>(_ type: T.Type, _ invoke: () -> UInt64) async throws -> T {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            // Park the continuation before invoking: the reply can land on
            // another thread before this call returns.
            let id = nextParked(continuation)
            let actual = invoke()
            reparent(from: id, to: actual)
        }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard envelope.ok, let value = envelope.data else {
            throw CoreError.backend(envelope.error ?? "unknown error")
        }
        return value
    }

    /// Placeholder ids are negative-space (high bit set) so they cannot collide
    /// with the counter Rust hands out.
    private var placeholderCounter: UInt64 = 1 << 63

    private func nextParked(_ continuation: CheckedContinuation<Data, Error>) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        placeholderCounter += 1
        waiting[placeholderCounter] = continuation
        return placeholderCounter
    }

    private func reparent(from placeholder: UInt64, to actual: UInt64) {
        lock.lock()
        guard let continuation = waiting.removeValue(forKey: placeholder) else {
            // The reply already arrived and was matched against the real id.
            lock.unlock()
            return
        }
        if let early = early.removeValue(forKey: actual) {
            lock.unlock()
            continuation.resume(returning: early)
            return
        }
        waiting[actual] = continuation
        lock.unlock()
    }

    /// Replies that arrived before `reparent` could file the continuation.
    private var early: [UInt64: Data] = [:]

    fileprivate func deliver(requestID: UInt64, data: Data) {
        if requestID == 0 {
            if let tasks = decodeSync([DownloadTask].self, String(decoding: data, as: UTF8.self)) {
                onDownloads?(tasks)
            }
            return
        }
        lock.lock()
        if let continuation = waiting.removeValue(forKey: requestID) {
            lock.unlock()
            continuation.resume(returning: data)
        } else {
            early[requestID] = data
            lock.unlock()
        }
    }

    private func decodeSync<T: Decodable>(_ type: T.Type, _ raw: String) -> T? {
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: Data(raw.utf8)),
              envelope.ok else { return nil }
        return envelope.data
    }

    // MARK: C string helpers

    /// Copies a Rust-owned string into Swift and frees the original.
    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { lumen_string_free(pointer) }
        return String(cString: pointer)
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Every payload from the core arrives in this envelope.
struct Envelope<T: Decodable>: Decodable {
    let ok: Bool
    let kind: String
    let data: T?
    let error: String?
}

enum CoreError: LocalizedError {
    case backend(String)
    var errorDescription: String? {
        switch self {
        case .backend(let message): message
        }
    }
}
