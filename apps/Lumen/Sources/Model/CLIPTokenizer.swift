import Foundation

/// CLIP's byte-pair tokenizer, which is what the text encoder expects.
///
/// The model takes 77 integers, not a string, and the mapping from one to the
/// other is not obvious: text is lowercased, split by a specific regex, encoded
/// to bytes, those bytes mapped into a printable alphabet, and the result
/// merged by a ranked list of byte pairs until no ranked pair remains. Getting
/// any step wrong yields tokens that are individually valid and collectively
/// meaningless, so this mirrors OpenAI's `simple_tokenizer.py` step for step.
///
/// The vocabulary and merge list are OpenAI's, under the MIT licence.
struct CLIPTokenizer {
    /// Longest sequence the text encoder accepts, start and end markers
    /// included.
    static let contextLength = 77

    private let vocabulary: [String: Int32]
    /// Merge priority: the lower the rank, the earlier the pair is joined.
    private let ranks: [Pair: Int]
    private let startToken: Int32
    private let endToken: Int32
    /// Byte value to the printable character standing in for it.
    private let byteEncoder: [UInt8: String]

    struct Pair: Hashable {
        let first: String
        let second: String
    }

    enum Failure: LocalizedError {
        case missingVocabulary(URL)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .missingVocabulary(let url):
                "The CLIP vocabulary is not at \(url.path)."
            case .malformed(let what):
                "The CLIP \(what) file is not in the expected format."
            }
        }
    }

    init(vocabulary vocabularyURL: URL, merges mergesURL: URL) throws {
        guard let vocabularyData = try? Data(contentsOf: vocabularyURL) else {
            throw Failure.missingVocabulary(vocabularyURL)
        }
        guard let decoded = try? JSONDecoder().decode([String: Int32].self,
                                                      from: vocabularyData) else {
            throw Failure.malformed("vocabulary")
        }
        guard let start = decoded["<|startoftext|>"], let end = decoded["<|endoftext|>"] else {
            throw Failure.malformed("vocabulary")
        }
        guard let mergeText = try? String(contentsOf: mergesURL, encoding: .utf8) else {
            throw Failure.missingVocabulary(mergesURL)
        }

        var ranks: [Pair: Int] = [:]
        // The first line is a version banner, not a merge.
        for (index, line) in mergeText.split(separator: "\n").dropFirst().enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[Pair(first: String(parts[0]), second: String(parts[1]))] = index
        }
        guard !ranks.isEmpty else { throw Failure.malformed("merges") }

        self.vocabulary = decoded
        self.ranks = ranks
        self.startToken = start
        self.endToken = end
        self.byteEncoder = Self.bytesToUnicode()
    }

    /// Where the assets live when they have been fetched.
    static func standard(in directory: URL) throws -> CLIPTokenizer {
        try CLIPTokenizer(vocabulary: directory.appending(path: "clip_vocab.json"),
                          merges: directory.appending(path: "clip_merges.txt"))
    }

    // MARK: Encoding

    /// The token ids for `text`, padded to the context length.
    ///
    /// Longer text is truncated rather than rejected: a query that runs past 75
    /// tokens is still a usable query.
    func encode(_ text: String) -> [Int32] {
        var tokens: [Int32] = [startToken]
        for word in Self.split(clean(text)) {
            // Bytes first, so any script survives — the merge table is defined
            // over this printable stand-in alphabet, not over characters.
            let mapped = Array(word.utf8).map { byteEncoder[$0] ?? "" }.joined()
            guard !mapped.isEmpty else { continue }
            for piece in merge(mapped) {
                guard let id = vocabulary[piece] else { continue }
                tokens.append(id)
            }
        }
        // Room must be left for the end marker.
        if tokens.count > Self.contextLength - 1 {
            tokens = Array(tokens.prefix(Self.contextLength - 1))
        }
        tokens.append(endToken)
        // Padded with zeros, which is what the exported model expects.
        tokens.append(contentsOf: [Int32](repeating: 0,
                                          count: Self.contextLength - tokens.count))
        return tokens
    }

    // MARK: The pieces

    private func clean(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// CLIP's pre-tokenisation: contractions, then runs of letters, single
    /// digits, and runs of anything else.
    private static let pattern = try? NSRegularExpression(
        pattern: "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d"
            + "|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+",
        options: [.caseInsensitive])

    private static func split(_ text: String) -> [String] {
        guard let pattern else { return text.split(separator: " ").map(String.init) }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    /// Applies the ranked merges until none apply.
    ///
    /// The word carries an end-of-word marker on its last symbol, which is how
    /// the vocabulary distinguishes "in" inside a word from "in" ending one.
    private func merge(_ word: String) -> [String] {
        var symbols = word.map(String.init)
        guard symbols.count > 1 else { return [word + "</w>"] }
        symbols[symbols.count - 1] += "</w>"

        while symbols.count > 1 {
            var bestRank = Int.max
            var bestIndex: Int?
            for index in 0..<(symbols.count - 1) {
                let pair = Pair(first: symbols[index], second: symbols[index + 1])
                if let rank = ranks[pair], rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard let index = bestIndex else { break }
            symbols[index] += symbols[index + 1]
            symbols.remove(at: index + 1)
        }
        return symbols
    }

    /// The printable alphabet CLIP maps raw bytes into.
    ///
    /// Bytes that are already printable stand for themselves; the rest are
    /// mapped above U+0100 so every byte has a distinct, printable symbol the
    /// merge table can be written in terms of.
    private static func bytesToUnicode() -> [UInt8: String] {
        var byteValues: [UInt8] = []
        byteValues.append(contentsOf: UInt8(33)...UInt8(126))   // ! to ~
        byteValues.append(contentsOf: UInt8(161)...UInt8(172))
        byteValues.append(contentsOf: UInt8(174)...UInt8(255))

        var mapping: [UInt8: String] = [:]
        for value in byteValues {
            mapping[value] = String(UnicodeScalar(value))
        }
        var next = 0
        for value in UInt8(0)...UInt8(255) where mapping[value] == nil {
            mapping[value] = String(UnicodeScalar(256 + next)!)
            next += 1
        }
        return mapping
    }
}
