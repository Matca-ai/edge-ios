# MatcaEdge for iOS

Run your Matca image model inside your iPhone app. The model answers on the phone, with no network needed,
and new releases you make in the Matca console reach the app by themselves, with no app update.

## What it does

- **Classifies pictures on the phone**: JPEG data, a `CGImage` or a camera `CVPixelBuffer` in, a label and its
  confidence out.
- **Keeps the model up to date**: it checks for a new release at start and every 6 hours, verifies its signature
  and takes it over on the next picture. A failed update never stops the model the phone already has.
- **Gets the model on the first launch**: until the first release is on the phone it asks again within seconds, and
  `waitUntilReady()` tells your app when the model is there.
- **Watches a camera feed**: turns a stream of frames into steady labels, and can wait for a stable picture,
  notice a black screen and only report confident answers that several frames agree on.
- **Works offline from the first launch**, when you ship a release inside the app.
- **Reports how each release does** on phones, once a day, as counts only, never a picture. You can switch this off.

## Requirements

iOS 15 or macOS 12, Xcode 26.5 or newer. No third-party dependencies.

The package installs a prebuilt, optimised framework, so the picture steps run at full speed even in your app's Debug
build. GitHub builds it from the source in `Sources/` and signs where it came from; to check a release:

```sh
gh attestation verify MatcaEdge.xcframework.zip --repo Matca-ai/edge-ios
```

Rather build from source? Use the `MatcaEdgeSource` product instead (`import MatcaEdgeSource`): the same code,
compiled in your app.

## Install

In Xcode: **File › Add Package Dependencies…**, enter `https://github.com/matca-ai/edge-ios` and pick version
`1.1.0`. Or in `Package.swift`:

```swift
.package(url: "https://github.com/matca-ai/edge-ios.git", from: "1.1.0")
// and in your target's dependencies:
.product(name: "MatcaEdge", package: "edge-ios")
```

## Use

You need three values from your model's **SDK** page in the Matca console: the edge address, a delivery key
(`mdk_…`) and the signing key.

### Classify a picture

```swift
import MatcaEdge

let classifier = try Classifier(
    model: "cap-detection",
    configuration: EdgeConfiguration(
        baseURL: URL(string: "https://assistant.matca.ai")!,
        deliveryKey: "mdk_…",
        rootPublicKey: "MFkw…"
    )
)

let answer = try await classifier.classify(jpegData)   // or a CGImage or CVPixelBuffer
print(answer.label, answer.confidence)                  // "With Cap" 0.98
```

`classify` throws `EdgeError.noModel` until the first release has reached the phone.

### Wait for the model on the first launch

Right after install the model may still be downloading. Show that it is being prepared, then start:

```swift
showPreparing()                                   // e.g. "Preparing the model…"
do {
    try await classifier.waitUntilReady()         // returns at once once the model is on the phone
} catch {
    showError(error)                              // after 60 s: why no model came (no network, nothing released, …)
}
```

### Watch a camera feed

```swift
var watch = Watch(classifier: classifier)
watch.waitForStablePicture = true
watch.detectBlackScreen = true

for await state in watch.states(of: frames) {   // frames: AsyncStream<Frame>, e.g. Frame(pixelBuffer:)
    switch state {
    case .ready: break                            // warm-up done
    case .blackScreen: showCameraBlocked()
    case .label(let label, let confidence, _): show(label, confidence)
    }
}
```

| `Watch` setting | Default | What it does |
|---|---|---|
| `frameInterval` | 0.25 s | Classifies at most one frame per interval |
| `waitForStablePicture` | `false` | Waits for a steady, bright picture before the first answer (at most 4 s) |
| `stablePictureFrames` | 12 | Steady frames in a row that settle the picture |
| `stablePictureMinimumBrightness` | 130 | Brightness (0–255) a steady frame needs; `0` if a dark picture is itself an answer |
| `stablePictureTimeout` | 4 s | How long the wait lasts at most before answering anyway, in seconds |
| `detectBlackScreen` | `false` | Reports `.blackScreen` and stops when the picture goes black |
| `ignoreFirstAnswers` | 4 | Skips the answers while the camera settles |
| `confidenceGate` | 0.95 | Drops answers below it |
| `agreement` / `agreementAtStart` | 3 / 4 | Answers in a row a label needs before it is reported |

### Options

| `EdgeConfiguration` | Default | What it does |
|---|---|---|
| `expectedLabels` | `[]` | Refuses a release that lacks one of these labels |
| `bundledRelease` | `nil` | A release shipped in the app, used before any network |
| `wifiOnly` | `false` | Downloads releases on Wi-Fi only |
| `checkInterval` | 6 hours | How often it checks for a new release |
| `monitoring` | `true` | Sends each release's daily counts; `false` sends nothing |

`try await classifier.checkForUpdates()` checks right away and throws an `EdgeError` that says why a release was not
taken. The current release is `await classifier.currentRelease`.

## Privacy

- Pictures never leave the phone.
- The library sends only the release check, the downloads and, unless `monitoring` is `false`, one report a day of
  counts per release: answers, confidence, speed and crashes. No device id, no user data, no location.
- The package ships `PrivacyInfo.xcprivacy`: no tracking; with monitoring on it declares crash, performance and other
  diagnostic data, not linked to the user.
- With monitoring on, your app needs its own legal basis for sending the reports (ePrivacy Directive, Article 5(3)).

## Try it

`Example/MatcaEdgeExample.xcodeproj` is a one-screen test app. Open it in Xcode, choose your team under
**Signing & Capabilities**, run it on a phone, and fill in the edge address, delivery key, signing key and model
name, or pair it from the model's **Test** tab in the console.

## License

Apache-2.0
