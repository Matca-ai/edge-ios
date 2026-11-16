import MatcaEdge
import SwiftUI

struct TestScreen: View {
    private enum PictureSource: Identifiable {
        case photoLibrary, camera

        var id: Self { self }
    }

    @AppStorage("edgeURL") private var edgeURL = ""
    @AppStorage("deliveryKey") private var deliveryKey = ""
    @AppStorage("rootPublicKey") private var rootPublicKey = ""
    @AppStorage("modelName") private var modelName = ""
    @StateObject private var tester = EdgeTester()
    @State private var openPictureSource: PictureSource?

    private var fields: EdgeFields {
        EdgeFields(edgeURL: edgeURL, deliveryKey: deliveryKey, rootPublicKey: rootPublicKey, modelName: modelName)
    }

    var body: some View {
        Form {
            fieldsSection
            actionsSection
            releaseSection
            if let answer = tester.answer {
                answerSection(answer)
            }
            if let lastError = tester.lastError {
                Section("Last error") {
                    Text(lastError).foregroundColor(.red)
                }
            }
        }
        .task { await tester.checkForUpdates(with: fields) }
        .onOpenURL { url in
            guard let link = PairingLink(url) else { return }
            Task { await pair(link) }
        }
        .sheet(item: $openPictureSource) { source in
            switch source {
            case .photoLibrary:
                PhotoLibraryPicker { classify($0, named: "chosen on the phone") }
            case .camera:
                CameraPicker { classify($0, named: "taken on the phone") }.ignoresSafeArea()
            }
        }
    }

    private var fieldsSection: some View {
        Section("Edge") {
            TextField("Edge URL", text: $edgeURL).keyboardType(.URL)
            SecureField("Delivery key", text: $deliveryKey)
            TextField("Root public key", text: $rootPublicKey)
            TextField("Model name", text: $modelName)
        }
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
    }

    private var actionsSection: some View {
        Section {
            Button("Check for updates") {
                Task { await tester.checkForUpdates(with: fields) }
            }
            Button("Answer the tries") {
                Task { await tester.answerTries(with: fields) }
            }
            Button("Choose picture") { openPictureSource = .photoLibrary }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take picture") { openPictureSource = .camera }
            }
        }
        .disabled(tester.isBusy)
    }

    private var releaseSection: some View {
        Section {
            valueRow("Current release", tester.release.map(String.init) ?? "none")
            if let answered = tester.triesAnswered {
                valueRow("Try pictures answered", String(answered))
            }
        }
    }

    private func answerSection(_ answer: Answer) -> some View {
        Section("Answer of release \(answer.release)") {
            valueRow("Label", answer.label)
            valueRow("Confidence", formatted(answer.confidence))
            ForEach(answer.all, id: \.label) { score in
                valueRow("Score of \(score.label)", formatted(score.confidence))
            }
        }
    }

    private func valueRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private func formatted(_ confidence: Double) -> String {
        String(format: "%.4f", confidence)
    }

    private func classify(_ picture: Data, named name: String) {
        Task { await tester.classify(picture, named: name, with: fields) }
    }

    /// A pairing code from the console's Test tab fills the four fields, then the phone answers the tries.
    private func pair(_ link: PairingLink) async {
        guard let paired = await tester.pair(link) else { return }
        edgeURL = link.edgeURL.absoluteString
        deliveryKey = paired.key
        rootPublicKey = paired.rootPublicKey
        modelName = paired.model
        await tester.answerTries(with: fields)
    }
}
