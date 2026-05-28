import Foundation
import CoreML

/// Loads a CoreML embedding model from a local path and runs inference.
/// Supports BERT-style models with (input_ids, attention_mask) inputs and pooled output.
public final class CoreMLEmbedder: Embedder, @unchecked Sendable {
    public let dimensions: Int
    public let identifier: String
    public let source: ModelSource

    private let model: MLModel
    private let tokenizer: BERTTokenizer?
    private let inputIdsFeature: String
    private let attentionMaskFeature: String
    private let outputFeature: String

    /// Initializes from a compiled .mlmodelc URL or a .mlpackage/.mlmodel that will be compiled.
    public init(modelDir: URL, modelSource: ModelSource, identifier: String) throws {
        self.source = modelSource
        self.identifier = identifier

        // Find the .mlpackage or .mlmodel
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)) ?? []

        let modelURL: URL
        if let pkg = contents.first(where: { $0.pathExtension == "mlpackage" }) {
            modelURL = pkg
        } else if let mdl = contents.first(where: { $0.pathExtension == "mlmodel" }) {
            modelURL = mdl
        } else if let mlmodelc = contents.first(where: { $0.pathExtension == "mlmodelc" }) {
            modelURL = mlmodelc
        } else {
            throw RagmacError.modelLoadFailed(reason: "No .mlpackage, .mlmodel, or .mlmodelc found in \(modelDir.path)")
        }

        let compiledURL: URL
        if modelURL.pathExtension == "mlmodelc" {
            compiledURL = modelURL
        } else {
            compiledURL = try MLModel.compileModel(at: modelURL)
        }

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

        // Load tokenizer if vocab.txt exists
        let vocabURL = modelDir.appendingPathComponent("vocab.txt")
        if fm.fileExists(atPath: vocabURL.path) {
            self.tokenizer = try BERTTokenizer(vocabURL: vocabURL)
        } else {
            self.tokenizer = nil
        }
    }

    public func embed(_ text: String) async throws -> [Float] {
        guard let tokenizer else {
            throw RagmacError.modelLoadFailed(
                reason: "No vocab.txt found alongside model. Cannot tokenize input."
            )
        }

        let (inputIds, attentionMask) = tokenizer.encode(text)
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
