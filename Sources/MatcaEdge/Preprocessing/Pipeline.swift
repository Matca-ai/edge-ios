import Foundation

public struct IlluminationSettings: Decodable, Equatable, Sendable {
    public var sigmaPercent: Double
    public var percentileLow: Double
    public var percentileHigh: Double
    public var smoothing: Bool

    public init(sigmaPercent: Double = 20, percentileLow: Double = 1, percentileHigh: Double = 99, smoothing: Bool = true) {
        self.sigmaPercent = sigmaPercent
        self.percentileLow = percentileLow
        self.percentileHigh = percentileHigh
        self.smoothing = smoothing
    }
}

/// The steps a release records, in the order they run (the contract's section 6).
struct PreprocessingSettings: Decodable, Equatable, Sendable {
    var fixOrientation = true
    var centreSquareCrop = true
    var cropFactor: Double?
    var circleMask = false
    var illumination: IlluminationSettings?

    /// An override comes from the app and is not checked by the control plane, as a release's steps are.
    func requireInRange() throws {
        if let cropFactor, !(cropFactor > 0 && cropFactor <= 1) { throw EdgeError.invalidPreprocessing(step: "crop_factor") }
        if let illumination {
            let percentiles = illumination.percentileLow >= 0 && illumination.percentileLow < illumination.percentileHigh && illumination.percentileHigh <= 100
            guard percentiles, illumination.sigmaPercent > 0, illumination.sigmaPercent <= 100 else {
                throw EdgeError.invalidPreprocessing(step: "illumination")
            }
        }
    }
}

public enum StepOverride<Value: Equatable & Sendable>: Equatable, Sendable {
    case off
    case on(Value)
}

/// What the app switches on or off for itself; `nil` leaves a step as the release recorded it.
public struct PreprocessingOverrides: Equatable, Sendable {
    public var fixOrientation: Bool?
    public var centreSquareCrop: Bool?
    public var cropFactor: StepOverride<Double>?
    public var circleMask: Bool?
    public var illumination: StepOverride<IlluminationSettings>?

    public init() {}

    /// The release's steps with the overrides applied, and the names of the steps that now differ.
    func applied(to release: PreprocessingSettings) -> (settings: PreprocessingSettings, overridden: [String]) {
        var settings = release
        var overridden: [String] = []
        if let fixOrientation, fixOrientation != release.fixOrientation {
            settings.fixOrientation = fixOrientation
            overridden.append("fix_orientation")
        }
        if let centreSquareCrop, centreSquareCrop != release.centreSquareCrop {
            settings.centreSquareCrop = centreSquareCrop
            overridden.append("centre_square_crop")
        }
        if let cropFactor, resolved(cropFactor) != release.cropFactor {
            settings.cropFactor = resolved(cropFactor)
            overridden.append("crop_factor")
        }
        if let circleMask, circleMask != release.circleMask {
            settings.circleMask = circleMask
            overridden.append("circle_mask")
        }
        if let illumination, resolved(illumination) != release.illumination {
            settings.illumination = resolved(illumination)
            overridden.append("illumination")
        }
        return (settings, overridden)
    }

    private func resolved<Value>(_ override: StepOverride<Value>) -> Value? {
        if case .on(let value) = override { return value }
        return nil
    }
}

enum Preprocessor {
    /// The picture as the model takes it: the steps that are on, then the resize to the model's input.
    static func prepare(_ decoded: DecodedPicture, steps: PreprocessingSettings, input: Manifest.Input) throws -> RGBPicture {
        try steps.requireInRange()
        var picture = decoded.picture
        if steps.fixOrientation {
            picture = fixOrientation(picture, exifOrientation: decoded.exifOrientation)
        }
        if steps.centreSquareCrop {
            picture = centreSquareCrop(picture)
        }
        if let factor = steps.cropFactor {
            picture = cropByFactor(picture, factor: factor)
        }
        if steps.circleMask {
            picture = circleMasked(picture)
        }
        if let illumination = steps.illumination {
            picture = try illuminationNormalised(picture, settings: illumination)
        }
        return resizeBilinear(picture, toWidth: input.width, height: input.height)
    }
}
