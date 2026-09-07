import Foundation
import CoreML
import AppKit
import Accelerate

/// Search the library by describing it.
///
/// Vision's feature prints know what an image *looks like* — they can find the
/// same wallpaper resized, and group things that share a palette and a
/// composition. What they cannot do is connect a picture to a word, because
/// they were never trained against language. "Moody city at night" is not a
/// question they can be asked.
///
/// MobileCLIP can, because images and text are embedded into one space: the
/// vector for a photograph of a samurai lands near the vector for the words
/// "a samurai", so searching is a dot product.
///
/// The model is not bundled. Apple releases MobileCLIP's weights for research
/// use only, so they are fetched to Application Support and stay out of the
/// repository; everything here degrades to "unavailable" when they are absent,
/// which is the normal state for a fresh checkout.
@MainActor
final class SemanticIndex {
    static let shared = SemanticIndex()

    /// Where the weights and vocabulary live, outside the app bundle.
    nonisolated static var modelDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/cc.lumen.Lumen/Models")
    }

    /// Length of the embeddings, fixed by the model.
    nonisolated static let dimensions = 512

    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var loadFailure: String?

    /// True once the models are on disk and loaded.
    var isReady: Bool { imageModel != nil && textModel != nil && tokenizer != nil }
    /// Why the index is unavailable, for the UI to show rather than fail mutely.
    var unavailableReason: String? { isReady ? nil : (loadFailure ?? "Model not installed.") }

    /// Whether the files are present, without paying to load them.
    nonisolated static var isInstalled: Bool {
        let directory = modelDirectory
        return ["mobileclip_s0_image.mlpackage", "mobileclip_s0_text.mlpackage",
                "clip_vocab.json", "clip_merges.txt"]
            .allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    // MARK: Loading

    /// Compiles and loads the models. Safe to call repeatedly.
    ///
    /// Compilation writes a `.mlmodelc` next to nothing in particular, so the
    /// result is kept beside the source and reused: compiling an 80 MB text
    /// encoder on every launch would be felt.
    func load() async {
        guard !isReady, loadFailure == nil else { return }
        guard Self.isInstalled else {
            loadFailure = "Model not installed."
            return
        }

        let directory = Self.modelDirectory
        do {
            let (image, text) = try await Task.detached(priority: .userInitiated) {
                let configuration = MLModelConfiguration()
                // The neural engine handles this well and keeps it off the GPU,
                // which the grid is already using.
                configuration.computeUnits = .all
                let image = try Self.loadModel(
                    package: directory.appending(path: "mobileclip_s0_image.mlpackage"),
                    configuration: configuration)
                let text = try Self.loadModel(
                    package: directory.appending(path: "mobileclip_s0_text.mlpackage"),
                    configuration: configuration)
                return (image, text)
            }.value

            imageModel = image
            textModel = text
            tokenizer = try CLIPTokenizer.standard(in: directory)
        } catch {
            loadFailure = error.localizedDescription
        }
    }

    /// Compiles a package once and reuses the compiled copy afterwards.
    ///
    /// `nonisolated` because loading happens off the main actor: compiling an
    /// 80 MB encoder on the actor that draws the grid would stall it.
    nonisolated private static func loadModel(package: URL,
                                  configuration: MLModelConfiguration) throws -> MLModel {
        let compiled = package.deletingPathExtension().appendingPathExtension("mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let built = try MLModel.compileModel(at: package)
            // compileModel writes to a temporary location that is cleaned up.
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: built, to: compiled)
        }
        return try MLModel(contentsOf: compiled, configuration: configuration)
    }

    // MARK: Embedding

    /// The embedding for an image file, or nil if it cannot be read.
    func embed(imageAt url: URL) -> [Float]? {
        guard let model = imageModel, let buffer = Self.pixelBuffer(for: url) else { return nil }
        return embed(model: model,
                     input: try? MLDictionaryFeatureProvider(
                        dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
    }

    /// The embedding for an image already in memory.
    ///
    /// The grid has decoded these thumbnails already, so ranking a page of
    /// results costs the model's time and nothing else — no fetch, and no
    /// round trip through a temporary file.
    func embed(image: NSImage) -> [Float]? {
        guard let model = imageModel,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let buffer = Self.pixelBuffer(from: cgImage) else { return nil }
        return embed(model: model,
                     input: try? MLDictionaryFeatureProvider(
                        dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
    }

    /// The embedding for a phrase.
    func embed(text: String) -> [Float]? {
        guard let model = textModel, let tokenizer else { return nil }
        let tokens = tokenizer.encode(text)
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: tokens.count)],
                                            dataType: .int32) else { return nil }
        for (index, token) in tokens.enumerated() {
            array[index] = NSNumber(value: token)
        }
        return embed(model: model,
                     input: try? MLDictionaryFeatureProvider(
                        dictionary: ["text": MLFeatureValue(multiArray: array)]))
    }

    private func embed(model: MLModel, input: MLDictionaryFeatureProvider?) -> [Float]? {
        guard let input, let output = try? model.prediction(from: input),
              let value = output.featureValue(for: "final_emb_1")?.multiArrayValue
        else { return nil }

        var vector = [Float](repeating: 0, count: value.count)
        for index in 0..<value.count { vector[index] = value[index].floatValue }
        return Self.normalised(vector)
    }

    /// Unit length, so similarity is a dot product rather than a division.
    nonisolated static func normalised(_ vector: [Float]) -> [Float] {
        var magnitude = Float(0)
        vDSP_svesq(vector, 1, &magnitude, vDSP_Length(vector.count))
        magnitude = sqrt(magnitude)
        guard magnitude > 0 else { return vector }
        var scale = 1 / magnitude
        var out = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &out, 1, vDSP_Length(vector.count))
        return out
    }

    /// Cosine similarity of two unit vectors: 1 is identical, 0 unrelated.
    nonisolated static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var product = Float(0)
        vDSP_dotpr(a, 1, b, 1, &product, vDSP_Length(a.count))
        return product
    }

    // MARK: Pixels

    /// The image at `url` as the 256x256 buffer the model expects.
    ///
    /// Decoded through ImageIO at the target size rather than in full: a 6000px
    /// wallpaper decoded whole, four thousand times over, is the difference
    /// between indexing in minutes and in an hour.
    nonisolated static func pixelBuffer(for url: URL, side: Int = 256) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        return pixelBuffer(from: thumbnail, side: side)
    }

    nonisolated static func pixelBuffer(from image: CGImage, side: Int = 256) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                  kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Aspect fill then centre crop, which is how CLIP was trained: letter-
        // boxing would feed the model bars it has never seen.
        let scale = max(CGFloat(side) / CGFloat(image.width),
                        CGFloat(side) / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2,
                                       y: (CGFloat(side) - height) / 2,
                                       width: width, height: height))
        return buffer
    }
}


// MARK: Storage

extension SemanticIndex {
    /// Which model produced a stored embedding. Written alongside every row so
    /// a change of model invalidates the old set rather than silently mixing
    /// two spaces that do not share coordinates.
    nonisolated static let modelIdentifier = "mobileclip_s0"

    /// Raw float32s, which is how an embedding travels to the database.
    nonisolated static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    nonisolated static func decode(_ data: Data) -> [Float]? {
        guard data.count == dimensions * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
