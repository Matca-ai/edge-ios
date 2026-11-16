import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Hands over the picture's own bytes, so the library reads its EXIF orientation as it does for any JPEG.
/// Bytes that cannot be read arrive empty, and the library's own error says so on the screen.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPicked: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPicker

        init(_ parent: PhotoLibraryPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            results.first?.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [parent] data, _ in
                DispatchQueue.main.async { parent.onPicked(data ?? Data()) }
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onTaken: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.dismiss()
            let image = info[.originalImage] as? UIImage
            parent.onTaken(image?.jpegData(compressionQuality: 0.9) ?? Data())
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
