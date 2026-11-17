# MatcaEdge for iOS

Run your Matca image model inside your iPhone app. The model answers on the phone, with no network needed,
and new releases you make in the Matca console reach the app by themselves, with no app update.

## What it does

- **Classifies pictures on the phone**: JPEG data, a `CGImage` or a camera `CVPixelBuffer` in, a label and its
  confidence out.
- **Keeps the model up to date**: it checks for a new release at start and every 6 hours, verifies its signature
  and takes it over on the next picture. A failed update never stops the model the phone already has.
- **Watches a camera feed**: turns a stream of frames into steady labels, and can wait for a stable picture,
  notice a black screen and only report confident answers that several frames agree on.
- **Works offline from the first launch**, when you ship a release inside the app.
- **Reports how each release does** on phones, once a day, as counts only, never a picture. You can switch this off.

## Requirements

iOS 15 or macOS 12, Swift 5.9, Xcode 15 or newer. No third-party dependencies.

## Install

In Xcode: **File › Add Package Dependencies…**, enter `https://github.com/matca-ai/edge-ios` and pick version
`0.2.1`. Or in `Package.swift`:

```swift
.package(url: "https://github.com/matca-ai/edge-ios.git", from: "0.2.1")
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
