import Foundation
import Vision
import AppKit

/// Perceptual fingerprints for the local library, used for finding duplicates
/// and "more like this one".
///
/// This uses Vision's own feature print, which ships with macOS — no model to
/// download, no app-size cost. It understands what an image *looks like*, so it
/// finds the same wallpaper at a different resolution or re-encoded, which a
/// file hash cannot.
///
/// The honest limit: a feature print has no idea what words mean. It can say
/// "these two look alike"; it cannot answer "moody city at night". That needs a
/// CLIP-class model, which is a much larger commitment.
enum ImagePrints {
    /// How close two prints must be to count as the same picture.
    ///
    /// Measured rather than guessed, over 116 real wallpapers: unrelated pairs
    /// land between 0.97 and 1.27, while the same image resized measures 0.24.
    /// 0.5 sits clear of both. An earlier guess of 10 would have called every
    /// wallpaper a duplicate of every other.
    static let duplicateThreshold: Float = 0.5

    /// Computes a print for one file. Nil for anything Vision cannot read.
    static func print(of url: URL) -> VNFeaturePrintObservation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Work from a thumbnail: the print is scale-invariant, and decoding a
        // 6000px wallpaper for every file would make indexing unusable.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    /// Archives a print so it can be stored, and read back later.
    static func encode(_ observation: VNFeaturePrintObservation) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: observation,
                                          requiringSecureCoding: true)
    }

    static func decode(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Distance between two prints. Smaller is more alike.
    static func distance(_ a: VNFeaturePrintObservation,
                         _ b: VNFeaturePrintObservation) -> Float? {
        var distance = Float(0)
        do {
            try a.computeDistance(&distance, to: b)
            return distance
        } catch {
            // Prints from different Vision revisions cannot be compared.
            return nil
        }
    }

    /// Groups of files that look like the same picture.
    ///
    /// A simple pass rather than clustering: for a few thousand wallpapers a
    /// flat comparison is faster than building an index, and it is easy to be
    /// sure it is right.
    static func duplicateGroups(
        in prints: [(path: String, print: VNFeaturePrintObservation)],
        threshold: Float = duplicateThreshold
    ) -> [[String]] {
        var grouped = Set<Int>()
        var groups: [[String]] = []

        for index in prints.indices where !grouped.contains(index) {
            var group = [prints[index].path]
            for other in prints.indices where other > index && !grouped.contains(other) {
                guard let apart = distance(prints[index].print, prints[other].print),
                      apart <= threshold else { continue }
                group.append(prints[other].path)
                grouped.insert(other)
            }
            if group.count > 1 {
                grouped.insert(index)
                groups.append(group)
            }
        }
        return groups
    }

    /// Loose groups of files that look like each other.
    ///
    /// Single-link clustering: anything within `threshold` of a member joins
    /// the group. That is the right shape here — "these all look like each
    /// other" — and at a few thousand files a flat sweep beats an index.
    ///
    /// The threshold is far looser than the duplicate one: unrelated wallpapers
    /// measure around 1.0, so 0.8 groups things that share a look without
    /// gathering everything into one bucket.
    static func cluster(
        _ prints: [(path: String, print: VNFeaturePrintObservation)],
        threshold: Float = 0.8,
        minimumSize: Int = 6
    ) -> [[String]] {
        var unvisited = Set(prints.indices)
        var groups: [[String]] = []

        while let seed = unvisited.first {
            unvisited.remove(seed)
            var group = [seed]
            var queue = [seed]

            // Grow outwards from the seed rather than comparing every pair.
            while let current = queue.popLast() {
                for candidate in Array(unvisited) {
                    guard let apart = distance(prints[current].print, prints[candidate].print),
                          apart <= threshold else { continue }
                    unvisited.remove(candidate)
                    group.append(candidate)
                    queue.append(candidate)
                }
            }

            if group.count >= minimumSize {
                groups.append(group.map { prints[$0].path })
            }
        }
        return groups.sorted { $0.count > $1.count }
    }

    /// Mean distance from each print to a set of them — how well something fits
    /// a taste, rather than how close it is to any single wallpaper.
    static func affinity(
        of target: VNFeaturePrintObservation,
        to references: [VNFeaturePrintObservation]
    ) -> Float? {
        guard !references.isEmpty else { return nil }
        let distances = references.compactMap { distance(target, $0) }
        guard !distances.isEmpty else { return nil }
        return distances.reduce(0, +) / Float(distances.count)
    }

    /// The files most like `target`, nearest first.
    static func nearest(
        to target: VNFeaturePrintObservation,
        in prints: [(path: String, print: VNFeaturePrintObservation)],
        excluding path: String,
        limit: Int = 12
    ) -> [(path: String, distance: Float)] {
        prints
            .filter { $0.path != path }
            .compactMap { entry in
                distance(target, entry.print).map { (entry.path, $0) }
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }
}
