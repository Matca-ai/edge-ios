import Foundation
import os

let log = Logger(subsystem: "ai.matca.edge", category: "classifier")

/// The seam over the platform's engine: every test but the one on a real file runs with a fake.
protocol ModelRunner: AnyObject, Sendable {
    /// Each label with its probability, for a picture at the model's input size, RGB 0...255.
    func predict(_ picture: RGBPicture) throws -> [String: Double]
}

protocol ModelLoader: Sendable {
    func load(releaseDirectory: URL, manifest: Manifest) throws -> any ModelRunner
}

struct LoadedRelease: Sendable {
    let release: Int
    let manifest: Manifest
    let runner: any ModelRunner
}
