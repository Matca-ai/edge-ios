# MatcaEdge for iOS

The iOS library of the Matca platform's on-device models: one `Classifier` per device model holds the newest verified release on the phone, answers pictures with a label and a confidence, and keeps itself up to date from the edge. It implements `docs/edge-library-contract.md`; the Android library (`sdks/edge-android`) does the same things in the same order.

Swift package, tools 5.9, iOS 15 and macOS 12, no dependency (Foundation, CoreGraphics, ImageIO, CryptoKit, CoreML, Accelerate, MetricKit). Apache-2.0.

## Usage

```swift
let configuration = EdgeConfiguration(baseURL: edgeURL, deliveryKey: "mdk_…", rootPublicKey: rootKeyBase64, expectedLabels: ["With Cap", "Without Cap"])
let classifier = try Classifier(model: "cap-detection", configuration: configuration)
let answer = try await classifier.classify(jpegData)          // also CGImage, CVPixelBuffer or a Frame
print(answer.label, answer.confidence, answer.release)
for await state in Watch(classifier: classifier).states(of: frames) { … }   // .ready, .blackScreen, .label
```

`Watch` is a value with the app's own steps as properties (`frameInterval`, `waitForStablePicture`, `detectBlackScreen`, `ignoreFirstAnswers`, `confidenceGate`, `agreement`, `agreementAtStart`); set them before calling `states(of:)`. `classifier.setPreprocessing(_:)` switches a release's picture step on or off for the app, logged once at warning level. `checkForUpdates()` asks the edge now; the classifier also asks when it is created and every `checkInterval` (6 hours by default). Every failure leaves the current model working; `checkForUpdates()` throws the reason as an `EdgeError`, and the classifier's own asks log it. A frame that gets no answer, `noModel` included, is dropped and logged and the watch goes on. A bundled release (`EdgeConfiguration.bundledRelease`) is a directory with `manifest.json` as the edge answers it, the files at their listed paths and `reference/<path>`.

## Monitoring

Unless the app switches it off, the classifier counts how each release does on this phone, per release and UTC day (`docs/edge-library-contract.md`, section 11): answers at or above the trainer's 0.95 gate and below it, failed classifications, a `Watch` that waited for a stable picture in vain or saw a black screen, the answers' confidence in the trainer's twelve gate steps, answers per label, the time of preprocessing (decoding included) and of the model in twelve millisecond steps, sessions and crashes. Counting only adds in memory; nothing is written or sent on a classification's path. The counts are kept in `monitoring.json` beside the releases, written at most once a minute and before each check. After a manifest ask the edge answered, every finished day goes to `POST /v1/models/{model}/releases/{n}/report`, oldest first, at most 14 per check; today is never sent and a day older than 7 days is dropped unsent.

```swift
let configuration = EdgeConfiguration(baseURL: edgeURL, deliveryKey: "mdk_…", rootPublicKey: rootKeyBase64, monitoring: false)
```

`monitoring: false` counts nothing, sends nothing and deletes `monitoring.json` and `session.json`. Crashes come from MetricKit (`MXDiagnosticPayload.crashDiagnostics`): the library adds one subscriber per process, beside any the app's own crash reporter adds, and counts a crash against the release that `session.json` says the process before ran. MetricKit hands a crash over in a later process, at most once per subscriber, and Apple's forums report crash diagnostics missing on iOS 17.2 to 17.5: crashes are reported as MetricKit delivers them, never more.

## Parity with the trainer

`swift test` runs the three fixture pictures of `sdks/edge-fixtures` through the library's own steps and compares them with the trainer's output. Mean absolute difference per channel value, measured on 1 November 2026 (tolerance 3.0, 6.0 for illumination):

| Fixture | default | no-orientation | crop-0.8 | circle | illumination |
|---|---|---|---|---|---|
| cap-upright | 0.102 | 0.102 | 0.099 | 0.168 | 0.074 |
| cap-sideways | 0.100 | 0.100 | 0.098 | 0.166 | 0.065 |
| cap-second | 0.096 | 0.096 | 0.089 | 0.571 | 0.070 |

The resize reproduces Pillow's bilinear filter, which widens its support and averages when it shrinks, so a camera frame is reduced the way the trainer reduced it; the two-pixel cases in `PreprocessingTests` pin that arithmetic against Pillow's own answers. The fixtures grow (180-pixel squares to 224), so the shrink path is covered by those unit cases, not by a fixture. What remains inside the differences above is the JPEG decoder (ImageIO against Pillow's libjpeg) and rounding.

## Test app

`Example/MatcaEdgeExample.xcodeproj` is one SwiftUI screen over the library, with no other dependency: add images in the console, retrain, release, watch the phone take the new release with no app update, and move back.

1. Open the project in Xcode 16 or newer. On a phone: select the `MatcaEdgeExample` target, choose a team under Signing & Capabilities (none is set; if the bundle id `ai.matca.edge.example` is refused, a personal team needs a different one), pick the phone and press Run.
2. Fill in the edge URL (https), the delivery key, the root public key (SubjectPublicKeyInfo DER as base64, as the console's signing page shows it) and the model name. They stay in `UserDefaults` between launches: a delivery key is read-only and this is a test app, so do not copy this into a client's app.
3. "Check for updates" asks the edge now. "Choose picture" or "Take picture" answers a picture on the phone; the camera button shows only where there is a camera. The screen shows the current release, the answer's label and confidence, every score and the last error.

**Paired from the console** (docs/on-device-models-plan.md, section 5): the Test tab's iPhone pairing code opens the
edge's install page, which offers TestFlight and the invitation (the `ios` workflow archives and uploads a build on
develop), then opens `matcaedge://pair?…`; the app spends the code for a key on the test channel and fills the
four fields itself. "Answer the tries" (also done right after pairing) fetches every try picture this phone has
not answered, answers it on the phone's chip with the release it holds and sends the answer with its time; a
picture taken or chosen here sends its answer too, never the picture. The project has a Release configuration, an
app icon and `Info.plist` with the URL scheme for that upload.

A release a device has seen stays seen: to start over, delete the app.

## What is not covered

- A trained model: `RealModelTests` opens a real `.mlpackage` through `CoreMLModelLoader` and `CoreMLModelRunner`, and its answers change if the channels are swapped or the picture is turned, but it is the tiny fixture model from `matca_trainer.tiny_edge_model`, not one trained on pictures.
- A real phone and the edge over the network: the tests run against a `URLProtocol` fake with the contract's status codes. The workflow (`.forgejo/workflows/ios.yaml`) runs them on macOS and builds the test app; a person or the release check runs them on the iOS simulator. The test app above is how a person checks a phone and a real edge.
- 32RGBA `CVPixelBuffer`s: converted, but CoreVideo refuses to make one for a test. 32BGRA, 32ARGB, 24RGB and the two biplanar 4:2:0 formats have tests; others throw `unsupportedPixelFormat`.
- The Wi-Fi rule itself: a test holds that file requests refuse cellular and the manifest does not; what the system then does is not tested.
- URLSession has no separate connect timeout; the 60 s request timeout covers the connect as well.
- MetricKit itself: the tests deliver crash reports through a fake of the library's crash source; that MetricKit hands a real crash to the next process is proven on a phone (M8 of `docs/device-monitoring-plan.md`).

## Privacy

Nothing leaves the phone but the manifest request, the file downloads, two counts (an install, a failed reference check) and, unless the app sets `monitoring: false`, the daily report above. None of it carries an identity: the delivery key names the app, the rollout number is drawn on the phone and stays there. The report holds counts only: no picture or anything drawn from one, no device or advertising id, nothing of the user, no location, not the rollout number; besides the counts it names the day, the platform, the system's major version and the library's version. No picture is read that the app did not pass in and none is sent anywhere. Files and state live in the library's own directory under Application Support, excluded from backups.

The app that leaves monitoring on needs its own legal basis for it: the EDPB's Guidelines 2/2023 read Article 5(3) of the ePrivacy Directive as covering any information a phone sends, personal or not. Matca processes the reports for the app's owner; whether to leave it on is that owner's decision.

`PrivacyInfo.xcprivacy` declares no tracking and no tracking domain. It declares the report as collected data, not linked to the user and not used for tracking, for app functionality: crash data (the crash counts), performance data (the speed steps) and other diagnostic data (the outcomes, confidence steps and labels); an app that sets `monitoring: false` collects none of it through this library. It declares the system boot time API category with reason 35F9.1: the speed steps come from the monotonic clock and only the time elapsed between two events in the app leaves the phone.
