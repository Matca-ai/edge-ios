import CoreVideo
import Foundation
@testable import MatcaEdge
import XCTest

/// Section 10, test 3: every fixture through the library's own steps, within the trainer's tolerance.
final class PreprocessingTests: XCTestCase {
    private struct Index: Decodable {
        struct Expected: Decodable {
            let input: String
            let steps: String
        }

        struct Tolerance: Decodable {
            let meanAbs: Double
            let meanAbsIllumination: Double
        }

        let expected: [String: Expected]
        let tolerance: Tolerance
        let steps: [String: PreprocessingSettings]
    }

    func testEveryFixtureMatchesTheTrainerWithinTolerance() throws {
        let index = try snakeCaseDecoder().decode(Index.self, from: Fixtures.data("index.json"))
        let input = Manifest.Input(width: 224, height: 224)
        for (name, expected) in index.expected.sorted(by: { $0.key < $1.key }) {
            let decoded = try PictureDecoding.decode(encoded: Fixtures.data("\(expected.input).jpg"))
            let prepared = try Preprocessor.prepare(decoded, steps: index.steps[expected.steps]!, input: input)
            let reference = try PictureDecoding.decode(encoded: Fixtures.data(name)).picture
            let difference = meanAbsoluteDifference(prepared, reference)
            let tolerance = expected.steps == "illumination" ? index.tolerance.meanAbsIllumination : index.tolerance.meanAbs
            print("parity \(name): mean abs difference \(String(format: "%.3f", difference)) (tolerance \(tolerance))")
            XCTAssertLessThanOrEqual(difference, tolerance, name)
        }
    }

    func testTheSidewaysFixtureCarriesOrientationSixAndTheOthersNone() throws {
        XCTAssertEqual(try PictureDecoding.decode(encoded: Fixtures.data("cap-sideways.jpg")).exifOrientation, 6)
        XCTAssertEqual(try PictureDecoding.decode(encoded: Fixtures.data("cap-upright.jpg")).exifOrientation, 1)
    }

    func testEveryExifOrientationTurnsATwoByOnePictureUpright() {
        // A red pixel left of a green one; each orientation says where the red one went.
        let picture = RGBPicture(width: 2, height: 1, pixels: [255, 0, 0, 0, 255, 0])
        let red: [UInt8] = [255, 0, 0]
        XCTAssertEqual(Array(fixOrientation(picture, exifOrientation: 2).pixels[3..<6]), red)
        XCTAssertEqual(Array(fixOrientation(picture, exifOrientation: 3).pixels[3..<6]), red)
        XCTAssertEqual(Array(fixOrientation(picture, exifOrientation: 4).pixels[0..<3]), red)
        let transposed = fixOrientation(picture, exifOrientation: 5)
        XCTAssertEqual([transposed.width, transposed.height], [1, 2])
        XCTAssertEqual(Array(transposed.pixels[0..<3]), red)
        XCTAssertEqual(Array(fixOrientation(picture, exifOrientation: 6).pixels[0..<3]), red)
        XCTAssertEqual(Array(fixOrientation(picture, exifOrientation: 7).pixels[3..<6]), red)
        XCTAssertEqual(Array(fixOrientation(picture, exifOrientation: 8).pixels[3..<6]), red)
    }

    func testTheCropsTakeTheMiddleAsTheTrainerDoes() {
        let picture = RGBPicture(width: 7, height: 4, pixels: [UInt8](repeating: 0, count: 7 * 4 * 3))
        let square = centreSquareCrop(picture)
        XCTAssertEqual([square.width, square.height], [4, 4])
        let share = cropByFactor(picture, factor: 0.5)
        XCTAssertEqual([share.width, share.height], [3, 2])
    }

    func testTheResizeAveragesWhenItShrinksAndInterpolatesWhenItGrowsAsPillowDoes() {
        // Pillow 12.3.0's answers for the same rows, checked on 1 November 2026: a plain bilinear sample gives 0 and 255 here.
        let row = RGBPicture.grey(width: 4, height: 1, values: [0, 0, 255, 255])
        XCTAssertEqual(resizeBilinear(row, toWidth: 2, height: 1).pixels, RGBPicture.grey(width: 2, height: 1, values: [36, 219]).pixels)
        let column = RGBPicture.grey(width: 1, height: 4, values: [0, 0, 255, 255])
        XCTAssertEqual(resizeBilinear(column, toWidth: 1, height: 2).pixels, RGBPicture.grey(width: 1, height: 2, values: [36, 219]).pixels)
        let pair = RGBPicture.grey(width: 2, height: 1, values: [0, 255])
        XCTAssertEqual(resizeBilinear(pair, toWidth: 3, height: 1).pixels, RGBPicture.grey(width: 3, height: 1, values: [0, 128, 255]).pixels)
    }

    func testAUniformPictureCannotBeIlluminationNormalised() {
        let flat = RGBPicture(width: 8, height: 8, pixels: [UInt8](repeating: 100, count: 8 * 8 * 3))
        XCTAssertThrowsError(try illuminationNormalised(flat, settings: IlluminationSettings())) { error in
            XCTAssertEqual(error as? EdgeError, .uniformPicture)
        }
    }

    func testOverridesChangeOnlyTheStepsThatDifferFromTheRelease() {
        var overrides = PreprocessingOverrides()
        overrides.centreSquareCrop = true
        overrides.circleMask = true
        overrides.cropFactor = .on(0.8)
        let (settings, overridden) = overrides.applied(to: PreprocessingSettings())
        XCTAssertEqual(overridden, ["crop_factor", "circle_mask"])
        XCTAssertEqual(settings.cropFactor, 0.8)
        XCTAssertTrue(settings.circleMask)
    }

    func testACropFactorSoSmallItLeavesNoPixelKeepsOne() {
        let picture = RGBPicture(width: 8, height: 8, pixels: [UInt8](repeating: 0, count: 8 * 8 * 3))
        let share = cropByFactor(picture, factor: 0.001)
        XCTAssertEqual([share.width, share.height], [1, 1])
    }

    func testAnOverrideOutOfRangeIsAnErrorAndNoCrash() {
        let picture = DecodedPicture(picture: RGBPicture(width: 8, height: 8, pixels: [UInt8](repeating: 9, count: 8 * 8 * 3)), exifOrientation: 1)
        let input = Manifest.Input(width: 4, height: 4)
        for factor in [1.5, 0, -1] {
            XCTAssertThrowsError(try Preprocessor.prepare(picture, steps: PreprocessingSettings(cropFactor: factor), input: input)) { error in
                XCTAssertEqual(error as? EdgeError, .invalidPreprocessing(step: "crop_factor"))
            }
        }
        for settings in [IlluminationSettings(percentileHigh: 120), IlluminationSettings(percentileLow: 50, percentileHigh: 40), IlluminationSettings(sigmaPercent: 0)] {
            XCTAssertThrowsError(try Preprocessor.prepare(picture, steps: PreprocessingSettings(illumination: settings), input: input)) { error in
                XCTAssertEqual(error as? EdgeError, .invalidPreprocessing(step: "illumination"))
            }
        }
    }

    func testAPixelBufferOfEveryFormatGivesItsRGB() throws {
        let red = UInt8(200), green = UInt8(100), blue = UInt8(50)
        let packed: [(OSType, [UInt8])] = [
            (kCVPixelFormatType_32BGRA, [blue, green, red, 255]),
            (kCVPixelFormatType_32ARGB, [255, red, green, blue]),
            (kCVPixelFormatType_24RGB, [red, green, blue]),
        ]
        for (format, pixel) in packed {
            let picture = try PictureDecoding.rgb(of: pixelBuffer(format, pixel))
            XCTAssertEqual(picture.pixels, [red, green, blue], String(format))
        }
    }

    func testACameraFrameIsConvertedWithTheRightChannelsInEitherRange() throws {
        // Mid luma, neutral blue chroma, strong red chroma; each range gives its own numbers (ITU-R 601).
        let cases: [(OSType, [UInt8])] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, [255, 48, 128]),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [255, 39, 130]),
        ]
        for (format, expected) in cases {
            let picture = try PictureDecoding.rgb(of: biPlanarBuffer(format, luma: 128, cb: 128, cr: 240))
            XCTAssertEqual(picture.pixels.count, 2 * 2 * 3)
            for channel in 0..<3 {
                XCTAssertEqual(Int(picture.pixels[channel]), Int(expected[channel]), accuracy: 2, "\(format) channel \(channel)")
            }
        }
    }

    func testAnImageCarriesTheOrientationTheAppGaveIt() throws {
        let decoded = try PictureDecoding.decode(Frame(image: solidGreyImage(100), exifOrientation: 6))
        XCTAssertEqual(decoded.exifOrientation, 6)
    }

    private func pixelBuffer(_ format: OSType, _ pixel: [UInt8]) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1, 1, format, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        CVPixelBufferGetBaseAddress(buffer)!.copyMemory(from: pixel, byteCount: pixel.count)
        return buffer
    }

    private func biPlanarBuffer(_ format: OSType, luma: UInt8, cb: UInt8, cr: UInt8) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, format, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let lumaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        lumaPlane.initialize(repeating: luma, count: lumaRowBytes * 2)
        let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        chromaPlane[0] = cb
        chromaPlane[1] = cr
        return buffer
    }

    private func meanAbsoluteDifference(_ first: RGBPicture, _ second: RGBPicture) -> Double {
        XCTAssertEqual([first.width, first.height], [second.width, second.height])
        var total = 0
        for index in 0..<first.pixels.count {
            total += abs(Int(first.pixels[index]) - Int(second.pixels[index]))
        }
        return Double(total) / Double(first.pixels.count)
    }
}
