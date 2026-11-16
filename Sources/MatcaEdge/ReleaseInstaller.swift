import CryptoKit
import Foundation

enum ReleaseDecision: Equatable {
    case take
    case skip(String)
    case rememberAndSkip(String)
}

/// Steps 3 to 7 of the contract's section 4, for a manifest that has already been verified. Its async
/// functions run off the classifier's actor, so a slow download or compile leaves classifications answering.
struct ReleaseInstaller {
    static let bundledManifestFileName = "manifest.json"

    let model: String
    let configuration: EdgeConfiguration
    let store: ModelStore
    let delivery: any Delivery
    let loader: any ModelLoader

    /// Step 3 (reading) and step 4 (the rollout).
    func decide(_ manifest: Manifest, state: StoredState, runningRelease: Int?) throws -> ReleaseDecision {
        guard manifest.format == 1 else { throw EdgeError.unreadableManifest("format \(manifest.format)") }
        guard manifest.model == model else { throw EdgeError.wrongModel }
        // With nothing loaded, the release last accepted may come again: it may be the one that no longer loads.
        if manifest.sequence < state.lastSequence || (manifest.sequence == state.lastSequence && runningRelease != nil) {
            return .skip("sequence \(manifest.sequence) is not above \(state.lastSequence)")
        }
        // A move back or a wider rollout signs the release this phone already runs again: nothing to fetch.
        if manifest.release == runningRelease {
            return .rememberAndSkip("this phone already runs it")
        }
        let missingFeatures = manifest.requires.filter { !EdgeLibrary.features.contains($0) }
        guard missingFeatures.isEmpty else { throw EdgeError.needsNewerLibrary(features: missingFeatures) }
        let missingLabels = configuration.expectedLabels.filter { !manifest.classes.contains($0) }
        guard missingLabels.isEmpty else { throw EdgeError.missingLabels(missingLabels) }
        if manifest.iosFiles.isEmpty {
            return .skip("the release has no iOS files")
        }
        return state.rolloutNumber < manifest.rolloutShare ? .take : .rememberAndSkip("it is not for this device's rollout number")
    }

    /// Step 5 from the edge.
    func download(_ manifest: Manifest) async throws -> URL {
        try await fetchFiles(of: manifest) { platform, path, size in
            try await delivery.file(release: manifest.release, platform: platform, path: path, expectedSize: size)
        }
    }

    /// Step 5 from the app's bundle, with no network: the files at their paths, the pictures under `reference/`.
    func copyBundled(_ manifest: Manifest, from bundle: URL) async throws -> URL {
        try await fetchFiles(of: manifest) { platform, path, _ in
            try readFile(try store.fileURL(platform == Self.referencePlatform ? referencePath(path) : path, in: bundle), path: path)
        }
    }

    /// Steps 6 and 7: the model loaded, then every reference picture answered on this phone.
    func loadAndCheck(_ manifest: Manifest, in releaseURL: URL) async throws -> LoadedRelease {
        let runner = try loader.load(releaseDirectory: releaseURL, manifest: manifest)
        for picture in manifest.reference {
            // Any failure to answer counts: an engine that throws on this phone is what the check is for.
            guard let answer = try? answer(to: picture, of: manifest, in: releaseURL, with: runner),
                  answer.label == picture.expected, answer.confidence >= picture.minimumConfidence
            else { throw EdgeError.referenceCheckFailed(path: picture.path) }
        }
        return LoadedRelease(release: manifest.release, manifest: manifest, runner: runner)
    }

    private static let referencePlatform = "reference"

    /// Every file into a fresh directory, each checked; one mismatch removes the directory.
    private func fetchFiles(of manifest: Manifest, fetch: (_ platform: String, _ path: String, _ size: Int) async throws -> Data) async throws -> URL {
        let releaseURL = try store.createReleaseDirectory(manifest.release)
        do {
            for file in manifest.iosFiles {
                let data = try await fetch("ios", file.path, file.size)
                try check(data, size: file.size, sha256: file.sha256, path: file.path)
                try store.write(data, to: file.path, in: releaseURL)
            }
            for picture in manifest.reference {
                let data = try await fetch(Self.referencePlatform, picture.path, picture.size)
                try check(data, size: picture.size, sha256: picture.sha256, path: picture.path)
                try store.write(data, to: referencePath(picture.path), in: releaseURL)
            }
        } catch {
            store.removeRelease(manifest.release)
            throw error
        }
        return releaseURL
    }

    private func answer(to picture: Manifest.Reference, of manifest: Manifest, in releaseURL: URL, with runner: any ModelRunner) throws -> Answer {
        let data = try readFile(try store.fileURL(referencePath(picture.path), in: releaseURL), path: picture.path)
        let prepared = try Preprocessor.prepare(try PictureDecoding.decode(encoded: data), steps: manifest.preprocessing, input: manifest.input)
        return try Answer(scores: try runner.predict(prepared), release: manifest.release)
    }

    private func referencePath(_ path: String) -> String {
        "\(ModelStore.referenceDirectoryName)/\(path)"
    }

    private func check(_ data: Data, size: Int, sha256: String, path: String) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == size, digest == sha256.lowercased() else { throw EdgeError.fileMismatch(path: path) }
    }

    private func readFile(_ url: URL, path: String) throws -> Data {
        guard let data = try? Data(contentsOf: url) else { throw EdgeError.fileMismatch(path: path) }
        return data
    }
}
