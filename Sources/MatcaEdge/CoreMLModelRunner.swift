import CoreML
import CoreVideo
import Foundation

/// Step 6 on iOS: the `.mlpackage` compiled once beside itself, then loaded.
struct CoreMLModelLoader: ModelLoader {
    func load(releaseDirectory: URL, manifest: Manifest) throws -> any ModelRunner {
        guard let packagePath = manifest.iosFiles.map(\.path).compactMap(packageRoot).first else {
            throw EdgeError.modelLoadFailed("the release lists no .mlpackage")
        }
        let package = releaseDirectory.appendingPathComponent(packagePath)
        let compiled = package.deletingPathExtension().appendingPathExtension("mlmodelc")
        do {
            if !FileManager.default.fileExists(atPath: compiled.path) {
                let temporary = try MLModel.compileModel(at: package)
                try FileManager.default.moveItem(at: temporary, to: compiled)
            }
            return try CoreMLModelRunner(model: MLModel(contentsOf: compiled))
        } catch let error as EdgeError {
            throw error
        } catch {
            throw EdgeError.modelLoadFailed(String(describing: error))
        }
    }

    private func packageRoot(of path: String) -> String? {
        let first = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
        return first.hasSuffix(".mlpackage") ? first : nil
    }
}

final class CoreMLModelRunner: ModelRunner, @unchecked Sendable {
    private let model: MLModel
    private let inputName: String

    init(model: MLModel) throws {
        guard let input = model.modelDescription.inputDescriptionsByName.first, input.value.type == .image else {
            throw EdgeError.modelLoadFailed("the model takes no image")
        }
        self.model = model
        inputName = input.key
    }

    func predict(_ picture: RGBPicture) throws -> [String: Double] {
        let output = try answer(to: MLFeatureValue(pixelBuffer: try pixelBuffer(of: picture)))
        // The classifier's probabilities are its one dictionary output, whatever coremltools named it.
        for name in output.featureNames {
            if let probabilities = output.featureValue(for: name)?.dictionaryValue, !probabilities.isEmpty {
                return Dictionary(uniqueKeysWithValues: probabilities.map { (String(describing: $0.key), $0.value.doubleValue) })
            }
        }
        throw EdgeError.predictionFailed("the model answered no probabilities")
    }

    private func answer(to value: MLFeatureValue) throws -> MLFeatureProvider {
        do {
            return try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: value]))
        } catch {
            throw EdgeError.predictionFailed(String(describing: error))
        }
    }

    /// The contract's form for an image input: 32BGRA at the picture's size.
    private func pixelBuffer(of picture: RGBPicture) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let created = CVPixelBufferCreate(nil, picture.width, picture.height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard created == kCVReturnSuccess, let pixelBuffer = buffer else { throw EdgeError.predictionFailed("no pixel buffer") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<picture.height {
            for x in 0..<picture.width {
                let source = picture.offset(x: x, y: y)
                let target = base + y * rowBytes + x * 4
                target[0] = picture.pixels[source + 2]
                target[1] = picture.pixels[source + 1]
                target[2] = picture.pixels[source]
                target[3] = 255
            }
        }
        return pixelBuffer
    }
}
