import PhotosUI
import SwiftUI

/// The form's photo section. Posters may use the camera or their library here; the
/// camera-only rule applies to the worker's proof, not to describing the job.
struct PosterPhotosSection: View {
    @Environment(PosterStore.self) private var store
    let model: CreateJobModel

    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var isShowingCamera = false

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        Section {
            if !model.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.photos) { photo in
                            PhotoThumbnail(
                                photo: photo,
                                onRemove: { model.removePhoto(photo.id) },
                                onRetry: { model.retryPhoto(photo.id, store: store) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if model.canAddPhotos {
                if cameraAvailable {
                    Button("Take a photo", systemImage: "camera") { isShowingCamera = true }
                }
                PhotosPicker(
                    selection: $libraryItems,
                    maxSelectionCount: CreateJobModel.maxPhotos - model.photos.count,
                    matching: .images
                ) {
                    Label("Choose from library", systemImage: "photo.on.rectangle")
                }
            }
        } header: {
            Text("Photos")
        } footer: {
            if model.category.suggestsBeforePhotos {
                Text("Add 2 to 4 photos showing the current state. Workers match these angles in their proof.")
            } else {
                Text("Optional. Photos help workers understand the job.")
            }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { image in
                model.addPhoto(image, store: store)
            }
            .ignoresSafeArea()
        }
        .onChange(of: libraryItems) { _, items in
            guard !items.isEmpty else { return }
            libraryItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        model.addPhoto(image, store: store)
                    }
                }
            }
        }
    }
}

private struct PhotoThumbnail: View {
    let photo: PosterPhoto
    let onRemove: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            Image(uiImage: photo.image)
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(photo.state == .uploading ? 0.5 : 1)

            switch photo.state {
            case .uploading:
                ProgressView()
            case .failed:
                Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .tint(BountyTheme.warning)
            case .uploaded:
                EmptyView()
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Remove photo", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
                .buttonStyle(.plain)
                .padding(4)
        }
    }
}

/// A thin wrapper around the system camera. Fastest path for the hackathon; swap for
/// AVFoundation later if we want guided angles.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
