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

    // MARK: Uploader and tags

    func uploaderCollections(username: String) async throws -> [UploaderCollection] {
        try await call([UploaderCollection].self) {
            username.withCString { lumen_uploader_collections($0) }
        }
    }

    func uploaderCollection(username: String, id: Int, page: Int) async throws -> SearchPage {
        try await call(SearchPage.self) {
            lumen_uploader_collection_wallpapers(
                Self.json(["username": username, "collectionId": id, "page": page]))
        }
    }

    func tagInfo(id: Int) async throws -> TagInfo {
        try await call(TagInfo.self) { lumen_tag_info(UInt64(id)) }
    }

    /// Wallpaper ids already on disk in the download directory.
    func downloadedIDs() -> Set<String> {
        Set(decodeSync([String].self, Self.takeString(lumen_downloaded_ids())) ?? [])
    }

    /// Records Lumen already holds for these wallpapers, skipping any it does not.
    func cachedWallpapers(ids: [String]) -> [Wallpaper] {
        guard !ids.isEmpty else { return [] }
        return decodeSync([Wallpaper].self,
                          Self.takeString(lumen_wallpapers_cached(Self.json(["ids": ids])))) ?? []
    }

    // MARK: Crops

    /// Identifier a crop is stored against. Screens have no stable name, so
    /// their pixel size stands in — the same size means the same framing.
    static func displayKey(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    func saveCrop(path: String, display: String, rect: CGRect) {
        let payload: [String: Any] = [
            "path": path, "display": display,
            "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height
        ]
        _ = Self.takeString(lumen_crop_save(Self.json(payload)))
    }

    func crop(path: String, display: String) -> CGRect? {
        struct Rect: Decodable { let x: Double; let y: Double
                                 let width: Double; let height: Double }
        let reply = Self.takeString(
            lumen_crop_get(Self.json(["path": path, "display": display])))
        guard let rect = decodeSync(Rect.self, reply) else { return nil }
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    func clearCrop(path: String, display: String) {
        _ = Self.takeString(lumen_crop_clear(Self.json(["path": path, "display": display])))
    }

    /// Stores records so a restored backup has something to point at.
    @discardableResult
    func cacheWallpapers(_ wallpapers: [Wallpaper]) -> Int {
        guard !wallpapers.isEmpty else { return 0 }
        guard let data = try? JSONEncoder().encode(wallpapers),
              let array = try? JSONSerialization.jsonObject(with: data) else { return 0 }
        let reply = Self.takeString(
            lumen_wallpapers_cache(Self.json(["wallpapers": array])))
        struct Stored: Decodable { let stored: Int }
        return decodeSync(Stored.self, reply)?.stored ?? 0
    }

    // MARK: Image feature prints

    struct StoredPrint: Decodable {
        let path: String
        /// Base64; the raw archive travels as JSON.
        let print: String
    }

    @discardableResult
    func storePrints(_ entries: [(path: String, data: Data, fileSize: Int)]) -> Int {
        guard !entries.isEmpty else { return 0 }
        let payload = entries.map {
            ["path": $0.path, "print": $0.data.base64EncodedString(), "fileSize": $0.fileSize]
        }
        let reply = Self.takeString(lumen_prints_store(Self.json(["prints": payload])))
        struct Stored: Decodable { let stored: Int }
        return decodeSync(Stored.self, reply)?.stored ?? 0
    }

    func allPrints() -> [StoredPrint] {
        decodeSync([StoredPrint].self, Self.takeString(lumen_prints_all())) ?? []
    }

    func printedPaths() -> Set<String> {
        Set(decodeSync([String].self, Self.takeString(lumen_prints_known())) ?? [])
    }

    @discardableResult
    func prunePrints() -> Int {
        let reply = Self.takeString(lumen_prints_prune())
        struct Removed: Decodable { let removed: Int }
        return decodeSync(Removed.self, reply)?.removed ?? 0
    }

    // MARK: Tag radar

    @discardableResult
    func subscribe(query: String, label: String, minFavorites: Int) -> Bool {
        let payload: [String: Any] = [
            "query": query, "label": label, "minFavorites": minFavorites
        ]
        let reply = Self.takeString(lumen_radar_subscribe(Self.json(payload)))
        struct Created: Decodable { let id: String }
        return decodeSync(Created.self, reply) != nil
    }

    func subscriptions() -> [Subscription] {
        decodeSync([Subscription].self, Self.takeString(lumen_radar_list())) ?? []
    }

    func unsubscribe(id: String) {
        _ = id.withCString { Self.takeString(lumen_radar_remove($0)) }
    }

    func markSubscriptionSeen(id: String) {
        _ = id.withCString { Self.takeString(lumen_radar_mark_seen($0)) }
    }

    /// Re-runs every subscription. Only subscriptions with something new
    /// appear in the result.
    func checkRadar() async throws -> [RadarResult] {
        try await call([RadarResult].self) { lumen_radar_check() }
    }

    // MARK: History

    func recordHistory(wallpaperID: String?, path: String, label: String) {
        var payload: [String: Any] = ["path": path, "label": label]
        if let wallpaperID { payload["wallpaperId"] = wallpaperID }
        _ = Self.takeString(lumen_history_record(Self.json(payload)))
    }

    func history(limit: Int = 40) -> [HistoryEntry] {
        decodeSync([HistoryEntry].self, Self.takeString(lumen_history(UInt32(limit)))) ?? []
    }

    func dropLatestHistory() {
        _ = Self.takeString(lumen_history_drop_latest())
    }

    // MARK: Imported folders

    /// Scanning can take a moment on a large folder, so this is async.
    @discardableResult
    func importFolder(at path: String) async throws -> ImportedFolder {
        try await call(ImportedFolder.self) { path.withCString { lumen_library_import($0) } }
    }

    /// Re-indexes only the download directory, which is cheap enough to run
    /// each time a download finishes.
    func refreshDownloads() async throws {
        _ = try await call(String?.self) { lumen_library_refresh_downloads() }
    }

    @discardableResult
    func rescanLibrary() async throws -> Int {
        struct Counted: Decodable { let count: Int }
        return try await call(Counted.self) { lumen_library_rescan() }.count
    }

    func libraryFolders() -> [ImportedFolder] {
        decodeSync([ImportedFolder].self, Self.takeString(lumen_library_folders())) ?? []
    }

    func libraryWallpapers(folder: String? = nil, favoritesOnly: Bool = false) -> [LocalWallpaper] {
        let reply = (folder ?? "").withCString {
            Self.takeString(lumen_library_wallpapers($0, favoritesOnly))
        }
        return decodeSync([LocalWallpaper].self, reply) ?? []
    }

    @discardableResult
    func forgetFolder(id: String) -> Bool {
        id.withCString { pointer in
            let reply = Self.takeString(lumen_library_forget(pointer))
            return (try? JSONDecoder().decode(Envelope<String?>.self, from: Data(reply.utf8)))?.ok
                ?? false
        }
    }

    @discardableResult
    func setLibraryFavorite(id: String, favorite: Bool) -> Bool {
        let reply = Self.takeString(
            lumen_library_favorite(Self.json(["id": id, "favorite": favorite])))
        struct Flag: Decodable { let favorite: Bool }
        return decodeSync(Flag.self, reply)?.favorite == favorite
    }

    // MARK: Bulk actions

    /// Returns how many rows actually changed.
    @discardableResult
    func setFavorites(ids: [String], favorited: Bool) -> Int {
        let reply = Self.takeString(
            lumen_favorites_set_many(Self.json(["ids": ids, "favorited": favorited])))
        struct Changed: Decodable { let changed: Int }
        return decodeSync(Changed.self, reply)?.changed ?? 0
    }

    @discardableResult
    func addToCollection(id collectionID: String, ids: [String]) -> Int {
        let reply = Self.takeString(
            lumen_collection_add_many(Self.json(["collectionId": collectionID, "ids": ids])))
        struct Changed: Decodable { let changed: Int }
        return decodeSync(Changed.self, reply)?.changed ?? 0
    }

    /// Enqueues a whole selection; the core's semaphore bounds concurrency.
    func download(_ items: [(id: String, url: String, filename: String)]) async throws {
        let payload = items.map { ["id": $0.id, "url": $0.url, "filename": $0.filename] }
        _ = try await call(Queued.self) { lumen_download_many(Self.json(["items": payload])) }
    }

    private struct Queued: Decodable { let queued: Int }

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
