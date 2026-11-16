import Foundation

public enum EdgeError: Error, Equatable {
    case invalidModelName
    case noModel
    /// The edge answered with a status the library does not take; 0 when there was no answer.
    case edge(status: Int)
    case invalidSignature
    case untrustedSigningKey
    case unreadableManifest(String)
    case wrongModel
    case needsNewerLibrary(features: [String])
    case missingLabels([String])
    case fileMismatch(path: String)
    case modelLoadFailed(String)
    case predictionFailed(String)
    case referenceCheckFailed(path: String)
    case undecodablePicture
    case unsupportedPixelFormat
    case uniformPicture
    /// A picture step set to a value it cannot run with.
    case invalidPreprocessing(step: String)
    case storage(String)
}

/// Only the library's own texts go to a log: another's could quote a request.
func describe(_ error: Error) -> String {
    (error as? EdgeError).map { String(describing: $0) } ?? String(describing: type(of: error))
}
