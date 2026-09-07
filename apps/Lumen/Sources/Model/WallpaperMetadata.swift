import Foundation

/// Writes a downloaded wallpaper's tags and origin into its file metadata, so
/// Spotlight and Finder can find it.
///
/// Wallhaven's tags only exist in the API response; once a file is on disk it
/// is an anonymous JPEG. Writing them as extended attributes means "forest"
/// finds the wallpaper in Finder, and the Get Info panel shows where it came
/// from — without Lumen having to be running.
///
/// The values are the ones Spotlight already indexes (`kMDItemKeywords`,
/// `kMDItemWhereFroms`, `kMDItemFinderComment`), stored the way macOS stores
/// them: a binary plist under a `com.apple.metadata:` attribute name.
enum WallpaperMetadata {
    /// Attaches `tags` and `source` to the file at `url`.
    ///
    /// Failures are returned rather than thrown at the caller's flow: metadata
    /// is a nicety, and a filesystem that does not support extended attributes
    /// should not fail a download.
    @discardableResult
    static func write(tags: [String], source: URL?, pageURL: URL?, to url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        var wroteSomething = false

        if !tags.isEmpty {
            wroteSomething = setPlist(tags, for: "com.apple.metadata:kMDItemKeywords", on: url)
                || wroteSomething
            // The comment is what Finder's Get Info shows, and it is searchable
            // in the same way.
            let comment = "Wallhaven · " + tags.joined(separator: ", ")
            wroteSomething = setPlist(comment, for: "com.apple.metadata:kMDItemFinderComment", on: url)
                || wroteSomething
        }

        // "Where from" is the same field Safari fills in for a download.
        let origins = [pageURL?.absoluteString, source?.absoluteString].compactMap { $0 }
        if !origins.isEmpty {
            wroteSomething = setPlist(origins, for: "com.apple.metadata:kMDItemWhereFroms", on: url)
                || wroteSomething
        }

        return wroteSomething
    }

    // MARK: Sidecar

    /// Where the full record for a downloaded file lives.
    ///
    /// A dotfile beside the image: the folder scanner skips hidden entries, so
    /// it is never indexed as a wallpaper, and it travels with the file if the
    /// folder is moved or copied.
    static func sidecarURL(for file: URL) -> URL {
        file.deletingLastPathComponent()
            .appending(path: ".\(file.lastPathComponent).lumen.json")
    }

    /// Writes everything Wallhaven knows about a wallpaper next to the file.
    ///
    /// Extended attributes carry tags and origin for Spotlight, but they cannot
    /// hold the whole record — and a file that has left Lumen's database should
    /// still be able to say what it is.
    @discardableResult
    static func writeSidecar(_ wallpaper: Wallpaper, for file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(wallpaper) else { return false }
        return (try? data.write(to: sidecarURL(for: file), options: .atomic)) != nil
    }

    /// The record for a downloaded file, if one was written.
    static func sidecar(for file: URL) -> Wallpaper? {
        guard let data = try? Data(contentsOf: sidecarURL(for: file)) else { return nil }
        return try? JSONDecoder().decode(Wallpaper.self, from: data)
    }

    /// Removes the record, for when the image itself is gone.
    static func removeSidecar(for file: URL) {
        try? FileManager.default.removeItem(at: sidecarURL(for: file))
    }

    /// Reads the keywords back, which is how the checks confirm a write landed.
    static func keywords(of url: URL) -> [String] {
        guard let data = getAttribute("com.apple.metadata:kMDItemKeywords", on: url),
              let value = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        else { return [] }
        return value as? [String] ?? []
    }

    static func whereFroms(of url: URL) -> [String] {
        guard let data = getAttribute("com.apple.metadata:kMDItemWhereFroms", on: url),
              let value = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        else { return [] }
        return value as? [String] ?? []
    }

    // MARK: Extended attributes

    private static func setPlist(_ value: Any, for name: String, on url: URL) -> Bool {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: value, format: .binary, options: 0)
        else { return false }

        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return data.withUnsafeBytes { bytes in
                setxattr(path, name, bytes.baseAddress, data.count, 0, 0) == 0
            }
        }
    }

    private static func getAttribute(_ name: String, on url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var buffer = Data(count: length)
            let read = buffer.withUnsafeMutableBytes { bytes in
                getxattr(path, name, bytes.baseAddress, length, 0, 0)
            }
            guard read == length else { return nil }
            return buffer
        }
    }
}
