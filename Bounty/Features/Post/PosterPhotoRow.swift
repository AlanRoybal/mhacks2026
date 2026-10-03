import PhotosUI
import SwiftUI

/// The row of photo tiles at the top of "Post a job", ending in an "Add photo" tile, as in the
/// design. Posters may use the camera or their library here; the camera-only rule applies to
/// the worker's proof, not to describing the job. Photos upload as soon as they're added.
struct PosterPhotoRow: View {
    @Environment(PosterStore.self) private var store
    let model: CreateJobModel

    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var isShowingCamera = false
    @State private var isShowingLibrary = false

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if model.photos.isEmpty {
                        // The category's sticker stands in until there's a real photo.
                        StickerTile(
                            sticker: model.category?.sticker ?? .camera,
                            background: model.category?.tileColor ?? BountyColor.pill,
                            size: 84, stickerSize: 66, radius: 18
                        )
                    }
                    ForEach(model.photos) { photo in
                        PhotoThumbnail(
                            photo: photo,
                            onRemove: { model.removePhoto(photo.id) },
                            onRetry: { model.retryPhoto(photo.id, store: store) }
                        )
                    }
                    if model.canAddPhotos {
                        Menu {
                            if cameraAvailable {
                                Button("Take a photo", systemImage: "camera") { isShowingCamera = true }
                            }
                            Button("Choose from library", systemImage: "photo.on.rectangle") { isShowingLibrary = true }
                        } label: {
                            AddPhotoTile()
                        }
                    }
                }
            }
            if model.category?.suggestsBeforePhotos == true && model.photos.isEmpty {
                Text("Add 2 to 4 photos of how it looks now. Workers match these angles in their proof.")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        }
        .photosPicker(
            isPresented: $isShowingLibrary,
            selection: $libraryItems,
            maxSelectionCount: CreateJobModel.maxPhotos - model.photos.count,
            matching: .images
        )
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

private struct AddPhotoTile: View {
    var body: some View {
        VStack(spacing: 4) {
            IconGlyph(icon: .images, size: 22)
            Text("Add photo")
                .bountyType(.caption)
        }
        .foregroundStyle(BountyColor.inkSecondary)
        .frame(width: 84, height: 84)
        .background(BountyColor.field, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(BountyColor.inkTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .opacity(photo.state == .uploading ? 0.5 : 1)

            switch photo.state {
            case .uploading:
                ProgressView()
            case .failed:
                IconButton(icon: .refresh, label: "Retry upload", size: 36, iconSize: 18, background: BountyColor.coral, foreground: BountyColor.inkInverse, action: onRetry)
            case .uploaded:
                EmptyView()
            }
        }
        .overlay(alignment: .topTrailing) {
            IconButton(icon: .x, label: "Remove photo", size: 24, iconSize: 12, background: BountyColor.inkPill, foreground: BountyColor.inkInverse, action: onRemove)
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
