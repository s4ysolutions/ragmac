import Foundation
import CoreML

/// Loads a CoreML embedding model from a local path and runs inference.
/// Supports BERT-style models with (input_ids, attention_mask) inputs and pooled output.
public final class CoreMLEmbedder: Embedder, @unchecked Sendable {
    public let dimensions: Int
    public let identifier: String
    public let source: ModelSource
    public let maxInputTokens: Int

    private let model: MLModel
    private let tokenizer: (any TextTokenizer)?
    private let inputIdsFeature: String
    private let attentionMaskFeature: String
    private let outputFeature: String
    private let requiredSeqLen: Int?  // non-nil when model has fixed input length

    /// Initializes from a compiled .mlmodelc URL or a .mlpackage/.mlmodel that will be compiled.
    public init(modelDir: URL, modelSource: ModelSource, identifier: String) throws {
        self.source = modelSource
        self.identifier = identifier

        // Find the .mlpackage or .mlmodel (search top level + one subdirectory level)
        let fm = FileManager.default

        guard let modelURL = CoreMLEmbedder.findModelURL(in: modelDir, fm: fm) else {
            throw RagmacError.modelLoadFailed(reason: "No .mlpackage, .mlmodel, or .mlmodelc found in \(modelDir.path)")
        }

        // Compile .mlpackage/.mlmodel → .mlmodelc, caching next to the source file
        let compiledURL: URL
        if modelURL.pathExtension == "mlmodelc" {
            compiledURL = modelURL
        } else {
            let cacheURL = modelURL.deletingPathExtension().appendingPathExtension("mlmodelc")
            if fm.fileExists(atPath: cacheURL.path) {
                compiledURL = cacheURL
            } else {
                fputs("→ Compiling model (first run, may take a minute)...\n", stderr)
                let tmp = try MLModel.compileModel(at: modelURL)
                try fm.moveItem(at: tmp, to: cacheURL)
                compiledURL = cacheURL
            }
        }

        fputs("→ Loading model...\n", stderr)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        self.model = try MLModel(contentsOf: compiledURL, configuration: config)

        // Detect input feature names
        let inputNames = Set(model.modelDescription.inputDescriptionsByName.keys)
        self.inputIdsFeature = inputNames.first(where: { $0.contains("input_id") }) ?? "input_ids"
        self.attentionMaskFeature = inputNames.first(where: { $0.contains("attention") }) ?? "attention_mask"

        // Detect output feature name
        let outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "embedding"
        self.outputFeature = outputName

        // Determine dimensions from output multi-array constraint
        if let outDesc = model.modelDescription.outputDescriptionsByName[outputFeature],
           outDesc.type == .multiArray,
           let constraint = outDesc.multiArrayConstraint {
            let shape: [NSNumber]
            if !constraint.shape.isEmpty {
                shape = constraint.shape
            } else if let first = constraint.shapeConstraint.enumeratedShapes.first {
                shape = first
            } else {
                shape = []
            }
            self.dimensions = shape.last?.intValue ?? 384
        } else {
            self.dimensions = 384
        }

        // Detect fixed sequence length from input shape constraint (e.g. b1_s128 → 128)
        if let inDesc = model.modelDescription.inputDescriptionsByName[self.inputIdsFeature],
           inDesc.type == .multiArray,
           let constraint = inDesc.multiArrayConstraint,
           !constraint.shape.isEmpty,
           constraint.shape.count >= 2 {
            let seqDim = constraint.shape[1].intValue
            self.requiredSeqLen = seqDim > 0 ? seqDim : nil
        } else {
            self.requiredSeqLen = nil
        }

        // Set maxInputTokens: use detected sequence length or default to 512
        self.maxInputTokens = self.requiredSeqLen ?? 512

        // Load tokenizer: BPE (tokenizer/tokenizer.json) or BERT (vocab.txt)
        let bpeURL = modelDir.appendingPathComponent("tokenizer").appendingPathComponent("tokenizer.json")
        let vocabURL = modelDir.appendingPathComponent("vocab.txt")
        let tokMaxLen = self.maxInputTokens
        if fm.fileExists(atPath: bpeURL.path) {
            self.tokenizer = try BPETokenizer(tokenizerDir: modelDir.appendingPathComponent("tokenizer"), maxLength: tokMaxLen)
        } else if fm.fileExists(atPath: vocabURL.path) {
            self.tokenizer = try BERTTokenizer(vocabURL: vocabURL)
        } else {
            self.tokenizer = nil
        }
    }

    /// Searches `dir` then its direct subdirectories (non-bundle) for a CoreML model.
    private static func findModelURL(in dir: URL, fm: FileManager) -> URL? {
        let modelExts = ["mlpackage", "mlmodel", "mlmodelc"]
        let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let found = top.first(where: { modelExts.contains($0.pathExtension) }) { return found }
        for sub in top where !modelExts.contains(sub.pathExtension) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let subContents = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
            if let found = subContents.first(where: { modelExts.contains($0.pathExtension) }) { return found }
        }
        return nil
    }

    public func embed(_ text: String) async throws -> [Float] {
        guard let tokenizer else {
            throw RagmacError.modelLoadFailed(
                reason: "No vocab.txt found alongside model. Cannot tokenize input."
            )
        }

        var (inputIds, attentionMask) = tokenizer.encode(text)

        // Pad to fixed sequence length if the model requires it.
        // Padding side matters: last-token-pooling models (Qwen3) pad left so the final
        // content token sits at the last position; mean/CLS models pad right.
        if let seqLen = requiredSeqLen {
            if inputIds.count < seqLen {
                let pad = seqLen - inputIds.count
                let padIds = [Int32](repeating: 0, count: pad)
                let padMask = [Int32](repeating: 0, count: pad)
                if tokenizer.paddingSide == .left {
                    inputIds = padIds + inputIds
                    attentionMask = padMask + attentionMask
                } else {
                    inputIds += padIds
                    attentionMask += padMask
                }
            } else {
                inputIds = Array(inputIds.prefix(seqLen))
                attentionMask = Array(attentionMask.prefix(seqLen))
            }
        }

        let seqLen = inputIds.count
        let idsArray = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        let maskArray = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)

        for (i, id) in inputIds.enumerated() {
            idsArray[i] = NSNumber(value: id)
        }
        for (i, m) in attentionMask.enumerated() {
            maskArray[i] = NSNumber(value: m)
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            inputIdsFeature: MLFeatureValue(multiArray: idsArray),
            attentionMaskFeature: MLFeatureValue(multiArray: maskArray),
        ])

        let output = try model.prediction(from: input)

        guard let outArray = output.featureValue(for: outputFeature)?.multiArrayValue else {
            throw RagmacError.modelLoadFailed(reason: "Model output '\(outputFeature)' is not a multi-array")
        }

        // Mean-pool over sequence dimension if shape is [1, seq, dim]
        return meanPool(outArray, attentionMask: attentionMask)
    }

    private func meanPool(_ array: MLMultiArray, attentionMask: [Int32]) -> [Float] {
        let shape = array.shape.map { $0.intValue }

        if shape.count == 2 {
            // Shape [1, dim] or [seq, dim] — treat first element as CLS token embedding
            let dim = shape.last ?? dimensions
            var result = [Float](repeating: 0, count: dim)
            for i in 0..<dim {
                result[i] = array[i].floatValue
            }
            return result
        }

        if shape.count == 3 {
            // Shape [1, seq, dim] — mean pool over non-padded tokens
            let seqLen = shape[1]
            let dim = shape[2]
            var sum = [Float](repeating: 0, count: dim)
            var count: Float = 0
            for s in 0..<seqLen {
                let mask = s < attentionMask.count ? attentionMask[s] : 0
                if mask == 0 { continue }
                count += 1
                for d in 0..<dim {
                    sum[d] += array[s * dim + d].floatValue
                }
            }
            if count > 0 {
                return sum.map { $0 / count }
            }
            return sum
        }

        // Fallback: flatten and take first `dimensions` values
        let count = min(array.count, dimensions)
        return (0..<count).map { array[$0].floatValue }
    }
}
