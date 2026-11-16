import Foundation

struct StoredState: Codable, Equatable {
    /// The highest sequence this device accepted or skipped by rollout: a manifest at or below it changes nothing.
    var lastSequence: Int
    /// Drawn once in 0...99; the device takes a release when this is below its rollout share.
    var rolloutNumber: Int
    var currentRelease: Int?
}

/// The library's own directory: the state file, one directory per release, the manifest text beside its
/// files. One step of taking a release runs at a time, the classifier's checks being serial, so it keeps no lock.
final class ModelStore {
    static let stateFileName = "state.json"
    static let unreadableStateFileName = "state.json.unreadable"
    static let manifestFileName = "manifest.txt"
    static let referenceDirectoryName = "reference"

    let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL) throws {
        self.directory = directory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = directory
            try excluded.setResourceValues(values)
        } catch {
            throw EdgeError.storage("cannot prepare the model directory")
        }
    }

    static func defaultDirectory(model: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MatcaEdge", isDirectory: true).appendingPathComponent(model, isDirectory: true)
    }

    /// The state file, drawing the rollout number when there is none yet; an unreadable one is set aside and rebuilt.
    func loadOrCreateState() -> StoredState {
        let stateURL = directory.appendingPathComponent(Self.stateFileName)
        guard let data = try? Data(contentsOf: stateURL) else {
            return written(StoredState(lastSequence: 0, rolloutNumber: Self.drawnRolloutNumber(), currentRelease: nil))
        }
        if let state = try? JSONDecoder().decode(StoredState.self, from: data) { return state }
        let aside = directory.appendingPathComponent(Self.unreadableStateFileName)
        try? fileManager.removeItem(at: aside)
        try? fileManager.moveItem(at: stateURL, to: aside)
        return written(rebuiltState())
    }

    func writeState(_ state: StoredState) throws {
        do {
            try JSONEncoder().encode(state).write(to: directory.appendingPathComponent(Self.stateFileName), options: .atomic)
        } catch {
            throw EdgeError.storage("cannot write the state file")
        }
    }

    func rememberSequence(_ sequence: Int) throws {
        var state = loadOrCreateState()
        state.lastSequence = max(state.lastSequence, sequence)
        try writeState(state)
    }

    /// Step 8: the pointer moves in one atomic write; the other releases go once nothing uses them.
    func switchTo(release: Int, sequence: Int, manifestText: String) throws {
        try write(Data(manifestText.utf8), to: Self.manifestFileName, in: releaseDirectory(release))
        var state = loadOrCreateState()
        state.currentRelease = release
        state.lastSequence = max(state.lastSequence, sequence)
        try writeState(state)
        for other in releaseNumbers() where other != release {
            removeRelease(other)
        }
    }

    func releaseDirectory(_ release: Int) -> URL {
        directory.appendingPathComponent("releases", isDirectory: true).appendingPathComponent(String(release), isDirectory: true)
    }

    func createReleaseDirectory(_ release: Int) throws -> URL {
        let releaseURL = releaseDirectory(release)
        removeRelease(release)
        do {
            try fileManager.createDirectory(at: releaseURL, withIntermediateDirectories: true)
        } catch {
            throw EdgeError.storage("cannot create the release directory")
        }
        return releaseURL
    }

    func removeRelease(_ release: Int) {
        try? fileManager.removeItem(at: releaseDirectory(release))
    }

    /// Writes a listed file under its release directory; a path that would leave it is refused.
    func write(_ data: Data, to path: String, in releaseURL: URL) throws {
        let target = try fileURL(path, in: releaseURL)
        do {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            throw EdgeError.storage("cannot write \(path)")
        }
    }

    func fileURL(_ path: String, in base: URL) throws -> URL {
        let basePath = base.standardizedFileURL.path
        let target = base.appendingPathComponent(path).standardizedFileURL
        guard !path.hasPrefix("/"), !path.contains("\0"), target.path.hasPrefix(basePath + "/") else {
            throw EdgeError.fileMismatch(path: path)
        }
        return target
    }

    func readManifestText(in releaseURL: URL) -> String? {
        try? String(contentsOf: releaseURL.appendingPathComponent(Self.manifestFileName), encoding: .utf8)
    }

    private static func drawnRolloutNumber() -> Int {
        Int.random(in: 0..<100)
    }

    /// The newest release kept on this device gives back the pointer and a floor for the sequence.
    private func rebuiltState() -> StoredState {
        let installed = releaseNumbers().compactMap { release in
            readManifestText(in: releaseDirectory(release)).flatMap { try? Manifest.parse(Data($0.utf8)) }
        }
        let newest = installed.max { $0.sequence < $1.sequence }
        return StoredState(lastSequence: newest?.sequence ?? 0, rolloutNumber: Self.drawnRolloutNumber(), currentRelease: newest?.release)
    }

    private func written(_ state: StoredState) -> StoredState {
        try? writeState(state)
        return state
    }

    private func releaseNumbers() -> [Int] {
        let releases = directory.appendingPathComponent("releases", isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: releases.path)) ?? []
        return names.compactMap(Int.init)
    }
}
