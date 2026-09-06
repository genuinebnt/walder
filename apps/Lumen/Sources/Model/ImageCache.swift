import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Decode targets, in pixels on the long edge. Declared outside the cache so
/// they can be read from any isolation domain.
enum ImageDetail {
    /// Grid thumbnails. Covers a Cinema tile on a 2× display with headroom.
    static let thumbnail: CGFloat = 1000
    /// The full preview: sharp on a 5K wallpaper when zoomed, without holding
    /// 60 MB per image.
    static let preview: CGFloat = 3200
}

/// Decoded-image cache shared by every thumbnail in the app.
///
/// `AsyncImage` keeps nothing across a change of view identity, so switching
/// grid layout re-requested and re-decoded every visible thumbnail — which is
/// what made the layout picker feel slow. This holds decoded images in memory,
/// coalesces concurrent requests for the same URL, and backs onto a large
/// on-disk `URLCache`, so a layout switch becomes a synchronous cache read.
///
/// Images are downsampled to the size they will actually be drawn at. A grid of
/// 200pt tiles holding full 1600px decodes is the difference between a texture
/// upload the GPU does in one frame and one it does not.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [NSString: Task<NSImage?, Never>] = [:]

    private init() {
        memory.countLimit = 800
        memory.totalCostLimit = 320 * 1024 * 1024

        // Thumbnails are immutable once published, so a generous disk cache
        // costs nothing and survives relaunches.
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024)
    }

    private func key(_ url: URL, _ maxPixels: CGFloat) -> NSString {
        "\(url.absoluteString)|\(Int(maxPixels))" as NSString
    }

    /// A hit that can be rendered this frame, with no suspension.
    func cached(_ url: URL, maxPixels: CGFloat = ImageDetail.thumbnail) -> NSImage? {
        memory.object(forKey: key(url, maxPixels))
    }

    /// Returns the decoded image, fetching it only if no one else already is.
    func image(for url: URL, maxPixels: CGFloat = ImageDetail.thumbnail) async -> NSImage? {
        let cacheKey = key(url, maxPixels)
        if let hit = memory.object(forKey: cacheKey) { return hit }
        if let existing = inFlight[cacheKey] { return await existing.value }

        let task = Task<NSImage?, Never> {
            // Fetch and decode off the main actor. Decoding is the expensive
            // half, and doing it per tile on the main thread is what drops
            // frames while scrolling.
            await Task.detached(priority: .userInitiated) { () -> NSImage? in
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                guard let (data, response) = try? await URLSession.shared.data(for: request)
                else { return nil }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return nil
                }
                return Self.downsample(data, maxPixels: maxPixels)
            }.value
        }

        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil

        if let image {
            let pixels = image.size.width * image.size.height
            memory.setObject(image, forKey: cacheKey, cost: Int(pixels) * 4)
        }
        return image
    }

    /// Decodes straight to the target size through ImageIO, so the full-size
    /// bitmap is never materialised.
    private nonisolated static func downsample(_ data: Data, maxPixels: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return NSImage(data: data)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,      // decode now, not at draw time
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Warms the cache for images the user is about to scroll into.
    func prefetch(_ urls: [URL], maxPixels: CGFloat = ImageDetail.thumbnail) {
        for url in urls where memory.object(forKey: key(url, maxPixels)) == nil
            && inFlight[key(url, maxPixels)] == nil {
            Task { _ = await image(for: url, maxPixels: maxPixels) }
        }
    }
}

/// Drop-in replacement for `AsyncImage` that reads through `ImageCache`.
///
/// A cached URL renders on the first frame, so re-laying out a grid never
/// flashes placeholders. A load that comes back with nothing shows `failure`
/// rather than leaving the placeholder up forever.
struct CachedImage<Content: View, Placeholder: View, Failure: View>: View {
    let url: URL?
    let maxPixels: CGFloat
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure

    @State private var image: NSImage?
    @State private var failed = false

    init(url: URL?,
         maxPixels: CGFloat = ImageDetail.thumbnail,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder,
         @ViewBuilder failure: @escaping () -> Failure) {
        self.url = url
        self.maxPixels = maxPixels
        self.content = content
        self.placeholder = placeholder
        self.failure = failure
        // Seed synchronously so a cache hit paints on the first frame.
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0, maxPixels: maxPixels) })
    }

    var body: some View {
        Group {
            if let image {
                content(Image(nsImage: image))
            } else if failed {
                failure()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let hit = ImageCache.shared.cached(url, maxPixels: maxPixels) {
                image = hit
                failed = false
                return
            }
            failed = false
            let loaded = await ImageCache.shared.image(for: url, maxPixels: maxPixels)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

extension CachedImage where Failure == Placeholder {
    /// Two-closure form: a failed load falls back to the placeholder.
    init(url: URL?,
         maxPixels: CGFloat = ImageDetail.thumbnail,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.init(url: url, maxPixels: maxPixels, content: content,
                  placeholder: placeholder, failure: placeholder)
    }
}
