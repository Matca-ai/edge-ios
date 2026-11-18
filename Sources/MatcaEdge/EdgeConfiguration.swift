import Foundation

enum EdgeLibrary {
    static let version = "1.2.0"
    static let userAgent = "matca-edge-ios/\(version)"
    /// The picture steps this version applies; a manifest that requires another is refused.
    static let features = [
        "fix_orientation", "centre_square_crop", "crop_factor", "circle_mask", "illumination",
    ]
}

public struct EdgeConfiguration: Sendable {
    public var baseURL: URL
    public var deliveryKey: String
    /// The root public key as SubjectPublicKeyInfo DER, base64: what the console's signing page shows.
    public var rootPublicKey: String
    /// Labels the app relies on; a release missing one of them is refused.
    public var expectedLabels: [String]
    /// A directory with `manifest.json` as the edge answers it, the files at their listed paths and the
    /// reference pictures under `reference/`, taken before any network.
    public var bundledRelease: URL?
    public var wifiOnly: Bool
    public var checkInterval: TimeInterval
    /// Counts how each release does on this phone and sends each day's counts to the edge as they grow (the
    /// contract's section 11); false counts and sends nothing and deletes what was kept. Leaving it on needs
    /// the app's own legal basis.
    public var monitoring: Bool

    public init(
        baseURL: URL,
        deliveryKey: String,
        rootPublicKey: String,
        expectedLabels: [String] = [],
        bundledRelease: URL? = nil,
        wifiOnly: Bool = false,
        checkInterval: TimeInterval = 6 * 60 * 60,
        monitoring: Bool = true
    ) {
        self.baseURL = baseURL
        self.deliveryKey = deliveryKey
        self.rootPublicKey = rootPublicKey
        self.expectedLabels = expectedLabels
        self.bundledRelease = bundledRelease
        self.wifiOnly = wifiOnly
        self.checkInterval = checkInterval
        self.monitoring = monitoring
    }
}
