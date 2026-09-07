import Foundation
import Vision
import AppKit
import Accelerate

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
    /// Re-measured over a 3,894-wallpaper library, using the 1,552 pairs that
    /// are provably the same wallpaper — the same Wallhaven id filed in two
    /// folders — as ground truth. Those pairs measure 0.000 to 0.002. Distinct
    /// wallpapers begin appearing around 0.49 and have a median of 1.01.
    ///
    /// The two distributions are not cleanly separable, because a heavily
    /// downscaled copy can land as far as 0.87 — further than the closest pair
    /// of genuinely different wallpapers. So this is a choice about which error
    /// to make. It is set to catch every exact copy and the common resize and
    /// re-encode cases (medians 0.033 and 0.077), and to accept missing an
    /// extreme downscale, because the alternative — the 0.5 this used to be —
    /// flagged roughly 474 pairs of unrelated wallpapers as duplicates.
    ///
    /// At 0.15 that falls to about 109 while still catching all 1,552.
    static let duplicateThreshold: Float = 0.15

    /// How much two aspect ratios may differ and still be the same picture.
    ///
    /// A resize preserves shape and a re-encode preserves it exactly, so a
    /// difference in proportions is decisive evidence against a duplicate. Over
    /// the same library this rejected no true duplicate at all — it is free
    /// accuracy, even though it only removes about a tenth of the false pairs,
    /// most of which are same-resolution wallpapers in a similar style.
    static let duplicateAspectTolerance: Double = 0.02

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

    // ── raw vectors ───────────────────────────────────────────────────────
    //
    // `computeDistance` is a per-pair Vision call. That is fine for a handful,
    // and far too slow to build a graph with: a library of 4,000 is eight
    // million pairs. A print is a plain 768-element float vector underneath, so
    // the distance can be computed directly — measured at four times the rate,
    // and agreeing with Vision to the last bit over a thousand test pairs.

    /// The print's underlying vector, or nil if it is not the float layout
    /// this expects (a revision change would do that).
    static func vector(_ observation: VNFeaturePrintObservation) -> [Float]? {
        guard observation.elementType == .float,
              observation.elementCount > 0 else { return nil }
        let data = observation.data
        guard data.count == observation.elementCount * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// Euclidean distance between two vectors — the same measure Vision's
    /// `computeDistance` returns for feature prints.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vectors of different lengths cannot be compared")
        var difference = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &difference, 1, vDSP_Length(a.count))
        var sumOfSquares = Float(0)
        vDSP_svesq(difference, 1, &sumOfSquares, vDSP_Length(a.count))
        return sqrt(sumOfSquares)
    }

    /// Groups of files that look like the same picture.
    ///
    /// A simple pass rather than clustering: for a few thousand wallpapers a
    /// flat comparison is faster than building an index, and it is easy to be
    /// sure it is right.
    static func duplicateGroups(
        in prints: [(path: String, print: VNFeaturePrintObservation)],
        threshold: Float = duplicateThreshold,
        /// Proportions per file, when known. A pair whose shapes disagree is
        /// not a duplicate whatever the prints say.
        aspects: [String: Double] = [:]
    ) -> [[String]] {
        var grouped = Set<Int>()
        var groups: [[String]] = []

        for index in prints.indices where !grouped.contains(index) {
            var group = [prints[index].path]
            for other in prints.indices where other > index && !grouped.contains(other) {
                guard let apart = distance(prints[index].print, prints[other].print),
                      apart <= threshold,
                      sameShape(prints[index].path, prints[other].path, aspects)
                else { continue }
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

    /// Whether two files are the same shape, treating an unknown shape as no
    /// evidence either way rather than as a mismatch.
    static func sameShape(_ a: String, _ b: String, _ aspects: [String: Double]) -> Bool {
        guard let ra = aspects[a], let rb = aspects[b], ra > 0, rb > 0 else { return true }
        return abs(ra - rb) / max(ra, rb) <= duplicateAspectTolerance
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
