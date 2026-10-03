import Observation
import UIKit

/// State and rules for the post-job form (plan feature 8). The view only binds to this.
@MainActor
@Observable
final class CreateJobModel {
    var title = ""
    var description = ""
    /// Nil until the poster taps a category chip.
    var category: JobCategory?
    var isRemote = false
    var location: JobLocation?
    var deadline = Date.now.addingTimeInterval(24 * 3600)
    var payAmount: Decimal = 25
    var currency = PayCurrency.usd
    private(set) var photos: [PosterPhoto] = []

    private(set) var isGenerating = false
    var errorMessage: String?

    static let maxPhotos = 6

    // MARK: Validation

    /// Why the form can't be submitted yet, or nil when it's ready.
    var blockingIssue: String? {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return "Add a title." }
        if description.trimmingCharacters(in: .whitespaces).isEmpty { return "Describe the finished result." }
        if category == nil { return "Pick a category." }
        if !isRemote && location == nil { return "Choose a location, or mark the job as remote." }
        if deadline <= .now { return "Pick a deadline in the future." }
        if payAmount <= 0 { return "Set a payment above zero." }
        if photos.contains(where: { $0.state == .uploading }) { return "Waiting for photos to finish uploading." }
        if photos.contains(where: { $0.state == .failed }) { return "Remove or retry the photos that failed." }
        return nil
    }

    var canGenerate: Bool { blockingIssue == nil && !isGenerating }

    var canAddPhotos: Bool { photos.count < Self.maxPhotos }

    // MARK: Photos

    /// Adds a photo and starts uploading it right away, so it's ready by the time the form is.
    func addPhoto(_ image: UIImage, store: PosterStore) {
        guard canAddPhotos else { return }
        let photo = PosterPhoto(image: image.downscaled(maxDimension: 1600))
        photos.append(photo)
        upload(photo.id, store: store)
    }

    func retryPhoto(_ id: PosterPhoto.ID, store: PosterStore) {
        upload(id, store: store)
    }

    func removePhoto(_ id: PosterPhoto.ID) {
        photos.removeAll { $0.id == id }
    }

    private func upload(_ id: PosterPhoto.ID, store: PosterStore) {
        guard let index = photos.firstIndex(where: { $0.id == id }),
              let data = photos[index].image.jpegData(compressionQuality: 0.7) else { return }
        photos[index].state = .uploading
        Task {
            do {
                let url = try await store.uploadPhoto(jpegData: data)
                setState(.uploaded(url), for: id)
            } catch {
                setState(.failed, for: id)
            }
        }
    }

    private func setState(_ state: PosterPhoto.UploadState, for id: PosterPhoto.ID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].state = state
    }

    // MARK: Submit

    var draft: NewJobDraft {
        NewJobDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category ?? .errands,
            location: isRemote ? nil : location,
            deadline: deadline,
            payAmount: payAmount,
            currency: currency,
            posterPhotos: photos.compactMap(\.uploadedURL)
        )
    }

    /// Sends the form to the backend, which writes the proof checklist. Returns the DRAFT job.
    func generateChecklist(store: PosterStore) async -> Job? {
        guard canGenerate else { return nil }
        isGenerating = true
        defer { isGenerating = false }
        do {
            return try await store.createJob(draft)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Clears the form after a job is saved, keeping the poster's currency choice.
    func reset() {
        title = ""
        description = ""
        category = nil
        isRemote = false
        location = nil
        deadline = .now.addingTimeInterval(24 * 3600)
        payAmount = 25
        photos = []
    }
}

/// A photo the poster attached to describe the job, such as the lawn before mowing.
struct PosterPhoto: Identifiable {
    enum UploadState: Equatable {
        case uploading
        case uploaded(URL)
        case failed
    }

    let id = UUID()
    let image: UIImage
    var state = UploadState.uploading

    var uploadedURL: URL? {
        guard case .uploaded(let url) = state else { return nil }
        return url
    }
}

extension UIImage {
    /// Shrinks the image so its longest side is at most `maxDimension` points. Smaller images are returned as is.
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
