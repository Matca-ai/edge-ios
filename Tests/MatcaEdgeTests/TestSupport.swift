import CoreGraphics
import CryptoKit
import Foundation
@testable import MatcaEdge
import XCTest

enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    static func data(_ name: String) -> Data {
        try! Data(contentsOf: url(name))
    }

    static func json(_ name: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data(name)) as! [String: Any]
    }
}

struct TestSigner {
    let privateKey = P256.Signing.PrivateKey()

    var publicKeyBase64: String {
        privateKey.publicKey.derRepresentation.base64EncodedString()
    }

    func sign(_ text: String) -> String {
        try! privateKey.signature(for: Data(text.utf8)).derRepresentation.base64EncodedString()
    }
}

/// A manifest as the control plane writes one, with the fields the tests vary.
struct TestManifest {
    var format = 1
    var model = "cap-detection"
    var release = 1
    var sequence = 1
    var rolloutShare = 100
    var classes = ["With Cap", "Without Cap"]
    var requires = ["fix_orientation", "centre_square_crop"]
    var iosFiles: [[String: Any]] = [["path": "Model.mlpackage/Manifest.json", "size": 5, "sha256": sha256Hex("hello")]]
    var reference: [[String: Any]] = []
    var certificate: [String: Any]? = nil

    func text(signingKey: String) -> String {
        let document: [String: Any] = [
            "format": format, "model": model, "release": release,
            "sequence": sequence, "rollout_share": rolloutShare, "classes": classes,
            "input": ["width": 224, "height": 224],
            "preprocessing": [
                "fix_orientation": true, "centre_square_crop": true, "crop_factor": NSNull(), "circle_mask": false,
                "illumination": NSNull(),
            ],
            "requires": requires,
            "files": ["ios": iosFiles, "android": []],
            "reference": reference,
            "signing": ["key": signingKey, "certificate": certificate.map { $0 as Any } ?? NSNull()],
        ]
        let data = try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    func signed(by signer: TestSigner, key: String? = nil) -> SignedManifest {
        let text = text(signingKey: key ?? signer.publicKeyBase64)
        return SignedManifest(manifest: text, signature: signer.sign(text))
    }
}

func sha256Hex(_ text: String) -> String {
    sha256Hex(Data(text.utf8))
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

final class FakeModelRunner: ModelRunner, @unchecked Sendable {
    var scores: [String: Double]
    var throwsOnPredict = false

    init(scores: [String: Double], throwsOnPredict: Bool = false) {
        self.scores = scores
        self.throwsOnPredict = throwsOnPredict
    }

    func predict(_ picture: RGBPicture) throws -> [String: Double] {
        if throwsOnPredict { throw EdgeError.predictionFailed("fake") }
        return scores
    }
}

/// Answers per release; a release listed as failing does not load.
final class FakeModelLoader: ModelLoader, @unchecked Sendable {
    var scoresByRelease: [Int: [String: Double]] = [:]
    var failingReleases: Set<Int> = []
    var throwingOnPredict: Set<Int> = []
    var loadedReleases: [Int] = []
    var lastRunner: FakeModelRunner?
    var whileLoading: () -> Void = {}

    func load(releaseDirectory: URL, manifest: Manifest) throws -> any ModelRunner {
        loadedReleases.append(manifest.release)
        guard !failingReleases.contains(manifest.release) else { throw EdgeError.modelLoadFailed("fake") }
        whileLoading()
        let runner = FakeModelRunner(
            scores: scoresByRelease[manifest.release] ?? ["With Cap": 0.9, "Without Cap": 0.1],
            throwsOnPredict: throwingOnPredict.contains(manifest.release)
        )
        lastRunner = runner
        return runner
    }
}

/// A wall clock and a monotonic clock that move only when the test moves them.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var uptime: UInt64 = 1_000_000_000

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    var today: Int { UTCDay.number(of: now) }

    var monitoringClock: MonitoringClock {
        MonitoringClock(now: { self.now }, uptimeNanoseconds: { self.uptimeNanoseconds })
    }

    func advance(seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date += seconds
        uptime += UInt64(seconds * 1_000_000_000)
    }

    private var uptimeNanoseconds: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return uptime
    }
}

/// Crash reports the test delivers itself, to every classifier still alive.
final class FakeCrashReports: CrashReportSource, @unchecked Sendable {
    private struct Listener {
        weak var owner: AnyObject?
        let receive: @Sendable ([CrashReport]) async -> Void
    }

    private let lock = NSLock()
    private var listeners: [Listener] = []

    func listen(for owner: AnyObject, _ receive: @escaping @Sendable ([CrashReport]) async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        listeners.append(Listener(owner: owner, receive: receive))
    }

    func deliver(_ reports: [CrashReport]) async {
        for receive in liveReceivers() {
            await receive(reports)
        }
    }

    private func liveReceivers() -> [@Sendable ([CrashReport]) async -> Void] {
        lock.lock()
        defer { lock.unlock() }
        return listeners.filter { $0.owner != nil }.map(\.receive)
    }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MatcaEdgeTests-\(UUID().uuidString)", isDirectory: true)
}

func solidGreyImage(_ value: UInt8, width: Int = 64, height: Int = 64) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let level = CGFloat(value) / 255
    context.setFillColor(red: level, green: level, blue: level, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func frames(_ frames: [Frame]) -> AsyncStream<Frame> {
    AsyncStream { continuation in
        for frame in frames {
            continuation.yield(frame)
        }
        continuation.finish()
    }
}

func collect(_ states: AsyncStream<WatchState>) async -> [WatchState] {
    var collected: [WatchState] = []
    for await state in states {
        collected.append(state)
    }
    return collected
}
