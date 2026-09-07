import Foundation

/// The library as a weighted graph of "looks like".
///
/// The flat approach — sort everything by distance to one wallpaper — answers
/// "what is nearest" and nothing else, and it answers it badly in 768
/// dimensions. Two problems come with the territory:
///
/// **Hubs.** In high-dimensional space a few points sit close to almost
/// everything. They turn up in every result list without being especially
/// related to any of it. Keeping only *mutual* neighbours — I am in your top k
/// and you are in mine — removes them, because a hub is in everyone's list and
/// almost nobody is in the hub's.
///
/// **No sense of neighbourhood.** Mean distance to your favourites, which is
/// what taste ranking used, pulls everything towards the average of what you
/// like. It cannot surface something strongly connected to *one* favourite
/// through a dense cluster, which is exactly what a recommendation should do.
/// A random walk over the graph follows those connections, so a wallpaper two
/// hops away can outrank one that is nearer in a straight line.
///
/// Building it is cheap enough not to need caching: distances go through vDSP,
/// and the all-pairs sweep over four thousand wallpapers takes well under a
/// second on a laptop.
struct SimilarityGraph {
    struct Edge {
        let to: Int
        /// Similarity, not distance: larger is more alike, and it is what the
        /// walk moves along.
        let weight: Float
    }

    /// Node identity, in index order.
    let paths: [String]
    /// Adjacency. Symmetric — an edge appears in both endpoints' lists.
    let neighbours: [[Edge]]

    private let index: [String: Int]

    var isEmpty: Bool { paths.isEmpty }
    var edgeCount: Int { neighbours.reduce(0) { $0 + $1.count } / 2 }

    // MARK: Building

    /// Builds a mutual k-nearest-neighbour graph.
    ///
    /// `k` is the candidate width per node; the mutual test then removes
    /// roughly half of those, which is the point. A node whose neighbours all
    /// fail the test keeps its single nearest one, so the graph has no
    /// completely isolated points to strand a walk.
    static func build(from entries: [(path: String, vector: [Float])],
                      k: Int = 12) -> SimilarityGraph {
        let count = entries.count
        guard count > 1 else {
            return SimilarityGraph(paths: entries.map(\.path),
                                   neighbours: entries.isEmpty ? [] : [[]])
        }
        let width = min(k, count - 1)

        // Candidate neighbours per node, nearest first.
        var candidates = [[(index: Int, distance: Float)]](repeating: [], count: count)
        let vectors = entries.map(\.vector)

        // Each row is independent, so the sweep parallelises cleanly. The work
        // is a full row of distances per node, which is what makes this O(n²)
        // in wall time but only a fraction of a second in practice.
        // Only the k best are wanted, so the row is never materialised or
        // sorted: a bounded insertion keeps the running top-k. Sorting every
        // row would be n·log n per node on top of the distances, which at four
        // thousand nodes dominates the whole build.
        candidates.withUnsafeMutableBufferPointer { output in
            let buffer = output
            DispatchQueue.concurrentPerform(iterations: count) { i in
                var best: [(index: Int, distance: Float)] = []
                best.reserveCapacity(width + 1)
                var worst = Float.greatestFiniteMagnitude

                for j in 0..<count where j != i {
                    let apart = ImagePrints.distance(vectors[i], vectors[j])
                    // The common case once the list is full: reject without
                    // touching it.
                    if best.count == width && apart >= worst { continue }
                    let at = best.firstIndex { apart < $0.distance } ?? best.count
                    best.insert((j, apart), at: at)
                    if best.count > width { best.removeLast() }
                    worst = best.count == width ? best[width - 1].distance : .greatestFiniteMagnitude
                }
                // Each iteration owns exactly one slot, so the writes cannot
                // race and no lock is needed.
                buffer[i] = best
            }
        }

        // Self-tuning scale: each node's own k-th distance. Dense parts of the
        // library get a tighter scale than sparse ones, so one global cutoff
        // does not have to suit both.
        let scales: [Float] = candidates.map { row in
            max(row.last?.distance ?? 1, 0.0001)
        }

        // Built once. Testing membership by rebuilding a set per pair turned
        // the mutual check into the most expensive part of the build.
        let candidateSets: [Set<Int>] = candidates.map { Set($0.map(\.index)) }

        var adjacency = [[Edge]](repeating: [], count: count)
        var seen = Set<Int64>()
        for i in 0..<count {
            var kept = 0
            for candidate in candidates[i] {
                let j = candidate.index
                guard candidateSets[j].contains(i) else { continue }
                let pair = Int64(min(i, j)) << 32 | Int64(max(i, j))
                guard seen.insert(pair).inserted else { continue }
                // Gaussian kernel over the two local scales, which is the
                // usual self-tuning form. Identical images give ~1, unrelated
                // ones fall away sharply rather than lingering as weak edges.
                let weight = exp(-(candidate.distance * candidate.distance)
                                 / (scales[i] * scales[j]))
                adjacency[i].append(Edge(to: j, weight: weight))
                adjacency[j].append(Edge(to: i, weight: weight))
                kept += 1
            }
            // Never strand a node: a walk that reaches a dead end wastes its
            // mass on a restart.
            if kept == 0, adjacency[i].isEmpty, let nearest = candidates[i].first {
                let j = nearest.index
                let weight = exp(-(nearest.distance * nearest.distance)
                                 / (scales[i] * scales[j]))
                adjacency[i].append(Edge(to: j, weight: weight))
                adjacency[j].append(Edge(to: i, weight: weight))
            }
        }

        return SimilarityGraph(paths: entries.map(\.path), neighbours: adjacency)
    }

    private init(paths: [String], neighbours: [[Edge]]) {
        self.paths = paths
        self.neighbours = neighbours
        self.index = Dictionary(paths.enumerated().map { ($1, $0) },
                                uniquingKeysWith: { first, _ in first })
    }

    // MARK: Walking

    /// Personalised PageRank: where a random walk that keeps restarting from
    /// `seeds` spends its time.
    ///
    /// `restart` is the share of each step that jumps back to a seed. Lower
    /// values wander further and surface less obvious things; 0.15 is the
    /// conventional value and behaves well here.
    func walk(from seeds: [String: Float],
              restart: Float = 0.15,
              iterations: Int = 20) -> [Float] {
        let count = paths.count
        guard count > 0 else { return [] }

        var seedVector = [Float](repeating: 0, count: count)
        var seedMass: Float = 0
        for (path, weight) in seeds {
            guard let node = index[path], weight > 0 else { continue }
            seedVector[node] += weight
            seedMass += weight
        }
        // With nothing to start from the walk has nothing to say. An even
        // spread would just rank by degree, which is not a recommendation.
        guard seedMass > 0 else { return [Float](repeating: 0, count: count) }
        for i in 0..<count { seedVector[i] /= seedMass }

        // Outgoing weights per node, so each step spreads mass in proportion.
        let outgoing: [Float] = neighbours.map { edges in
            max(edges.reduce(0) { $0 + $1.weight }, .leastNormalMagnitude)
        }

        var current = seedVector
        var next = [Float](repeating: 0, count: count)
        for _ in 0..<iterations {
            for i in 0..<count { next[i] = restart * seedVector[i] }
            for i in 0..<count {
                let mass = current[i]
                guard mass > 0 else { continue }
                let share = (1 - restart) * mass / outgoing[i]
                for edge in neighbours[i] {
                    next[edge.to] += share * edge.weight
                }
            }
            swap(&current, &next)
        }
        return current
    }

    /// What to look at next, given what is already liked.
    ///
    /// Seeds are excluded from their own results — being told your favourites
    /// resemble your favourites is not a recommendation — as is anything in
    /// `excluding`, which is how recently-set wallpapers stay out of the way.
    func discover(likes: [String],
                  excluding: Set<String> = [],
                  limit: Int = 24) -> [(path: String, score: Float)] {
        let seeds = Dictionary(likes.map { ($0, Float(1)) }, uniquingKeysWith: +)
        let scores = walk(from: seeds)
        guard !scores.isEmpty else { return [] }

        let seeded = Set(likes)
        return scores.enumerated()
            .filter { !seeded.contains(paths[$0.offset]) && !excluding.contains(paths[$0.offset]) }
            .filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
            .prefix(limit)
            .map { (paths[$0.offset], $0.element) }
    }

    /// The wallpapers most related to one, by proximity through the graph
    /// rather than by straight-line distance.
    ///
    /// The difference shows on anything with a busy neighbourhood: a graph walk
    /// prefers things in the same cluster over a hub that happens to measure
    /// close to everything.
    func related(to path: String, limit: Int = 12) -> [(path: String, score: Float)] {
        guard index[path] != nil else { return [] }
        return discover(likes: [path], limit: limit)
    }

    // MARK: Communities

    /// Groups found by label propagation over the weighted edges.
    ///
    /// Single-link clustering, which this replaces, chains: A resembles B, B
    /// resembles C, and the group ends up holding A and C which resemble
    /// nothing of each other. Propagation asks instead which label a node's
    /// neighbourhood agrees on by weight, so a chain breaks where the
    /// connection is weak.
    ///
    /// Ties are broken by node order rather than at random, so the same library
    /// always yields the same groups — a shifting set of auto-collections would
    /// be useless.
    func communities(minimumSize: Int = 6, iterations: Int = 12) -> [[String]] {
        let count = paths.count
        guard count > 0 else { return [] }

        var labels = Array(0..<count)
        // A fixed shuffle: propagation needs a varied visit order to avoid
        // oscillating, but it has to be the same order every run.
        var order = Array(0..<count)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in stride(from: count - 1, to: 0, by: -1) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            order.swapAt(i, Int(seed % UInt64(i + 1)))
        }

        for _ in 0..<iterations {
            var changed = false
            for node in order {
                guard !neighbours[node].isEmpty else { continue }
                var weightByLabel: [Int: Float] = [:]
                for edge in neighbours[node] {
                    weightByLabel[labels[edge.to], default: 0] += edge.weight
                }
                // Highest total weight, lowest label id as the tie-break.
                let best = weightByLabel.min { a, b in
                    a.value != b.value ? a.value > b.value : a.key < b.key
                }
                if let best, best.key != labels[node] {
                    labels[node] = best.key
                    changed = true
                }
            }
            if !changed { break }
        }

        var members: [Int: [String]] = [:]
        for (node, label) in labels.enumerated() {
            members[label, default: []].append(paths[node])
        }
        return members.values
            .filter { $0.count >= minimumSize }
            .sorted { $0.count > $1.count }
    }
}
