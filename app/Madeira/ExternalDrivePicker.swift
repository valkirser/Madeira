import SwiftUI
import UniformTypeIdentifiers

/// Presents `UIDocumentPickerViewController` in folder-picking mode and hands
/// the chosen URL to `ExternalDriveStore`.
///
/// `forOpeningContentTypes` (rather than the exporting/copying initializer)
/// is what keeps this an "open in place" pick: the app gets a security-scoped
/// reference to the folder where it is, instead of a copy inside the app's
/// own container -- a copy would defeat the point of pointing Wine at an
/// external drive in the first place.
struct ExternalDrivePicker: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        func documentPicker(_ controller: UIDocumentPickerViewController,
                             didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            ExternalDriveStore.shared.connect(to: url)
        }
    }
}
