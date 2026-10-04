import CoreLocation
import SwiftUI
import TwinKit
import UIKit
import UniformTypeIdentifiers

// Proof capture and results for the worker (US-36 to US-43, `docs/API.md` "Proof").
//
//   JobDetailView ──start──▶ ProofCaptureView ──precheck, submit──▶ ProofCheckView
//                                   ▲                                    │
//                                   └──── failed, retries left ──────────┘
//
// Evidence is uploaded as soon as it's captured, so the server checks (precheck) and the submission
// only send file URLs. `ProofStore` keeps each job's evidence in memory, so a retry reuses earlier uploads.
// Photos and videos come only from the Bounty camera and are signed on capture (`CaptureSignature`).

// MARK: - State

/// Evidence gathered per job, kept across retries for the life of the app.
@MainActor
@Observable
final class ProofStore {
    /// Each `ProofDraft` is observable on its own; creating one isn't a change views need to see.
    @ObservationIgnored private var drafts: [String: ProofDraft] = [:]

    func draft(for jobId: String) -> ProofDraft {
        if let draft = drafts[jobId] { return draft }
        let draft = ProofDraft()
        drafts[jobId] = draft
        return draft
    }
}

@MainActor
@Observable
final class ProofDraft {
    struct Photo: Identifiable {
        let id = UUID()
        let image: UIImage
        /// `before` or `after`.
        let phase: String
        let capturedAt: Date
        let latitude: Double?
        let longitude: Double?
        var fileURL: URL?
        var signed: CaptureSignature.Signed?
        var failed = false
    }

    /// A short clip from the Bounty camera, plus the stills the grader reads.
    struct Video: Identifiable {
        struct Upload {
            let fileURL: URL
            let signed: CaptureSignature.Signed
        }

        let id = UUID()
        let localURL: URL
        let thumbnail: UIImage
        let frames: [UIImage]
        /// `before` or `after`.
        let phase: String
        let capturedAt: Date
        let latitude: Double?
        let longitude: Double?
        var upload: Upload?
        var frameUploads: [Upload] = []
        var failed = false

        var isUploaded: Bool { upload != nil && frameUploads.count == frames.count && !frames.isEmpty }
    }

    struct File: Identifiable {
        let id = UUID()
        let name: String
        var fileURL: URL?
        var failed = false
    }

    struct CheckIn {
        let latitude: Double
        let longitude: Double
        let at: Date
    }

    var photos: [String: [Photo]] = [:]
    var videos: [String: [Video]] = [:]
    var links: [String: String] = [:]
    var files: [String: [File]] = [:]
    var checkIns: [String: CheckIn] = [:]
    /// The latest server checks (US-39).
    var checks: ProofChecks?
    var isBusy = false
    var message: String?

    func photos(for item: ChecklistItem, phase: String) -> [Photo] {
        (photos[item.id] ?? []).filter { $0.phase == phase }
    }

    func videos(for item: ChecklistItem, phase: String) -> [Video] {
        (videos[item.id] ?? []).filter { $0.phase == phase }
    }

    var isUploading: Bool {
        photos.values.joined().contains { $0.fileURL == nil && !$0.failed }
            || videos.values.joined().contains { !$0.isUploaded && !$0.failed }
            || files.values.joined().contains { $0.fileURL == nil && !$0.failed }
    }

    /// Whether this device has what the item needs. The server's precheck has the final say.
    func isCovered(_ item: ChecklistItem) -> Bool {
        switch item.evidenceType {
        case .photo:
            // One video of the result (or of the "before") covers that side on its own.
            let after = photos(for: item, phase: "after").filter { $0.fileURL != nil }.count
            let before = photos(for: item, phase: "before").filter { $0.fileURL != nil }.count
            let videoAfter = videos(for: item, phase: "after").contains(where: \.isUploaded)
            let videoBefore = videos(for: item, phase: "before").contains(where: \.isUploaded)
            return (videoAfter || after >= (item.photoCount ?? 1)) && (!item.needsBeforePhoto || videoBefore || before >= 1)
        case .checkIn:
            return checkIns[item.id] != nil
        case .link:
            return Self.normalizedLink(links[item.id]) != nil
        case .file:
            return (files[item.id] ?? []).contains { $0.fileURL != nil }
                || (photos[item.id] ?? []).contains { $0.fileURL != nil }
                || (videos[item.id] ?? []).contains(where: \.isUploaded)
        }
    }

    /// One entry per checklist item, as the server requires on every submission.
    func body(for job: PostedJob) -> ProofBody {
        ProofBody(items: job.checklist.map { item in
            let uploaded = (photos[item.id] ?? []).compactMap { photo in
                photo.fileURL.map {
                    ProofBody.PhotoRef(fileURL: $0.absoluteString, capturedAt: photo.capturedAt,
                                       latitude: photo.latitude, longitude: photo.longitude, phase: photo.phase,
                                       sha256: photo.signed?.sha256, signature: photo.signed?.signature)
                }
            }
            let clips = (videos[item.id] ?? []).filter(\.isUploaded).compactMap { video in
                video.upload.map { upload in
                    ProofBody.VideoRef(
                        fileURL: upload.fileURL.absoluteString, capturedAt: video.capturedAt,
                        latitude: video.latitude, longitude: video.longitude, phase: video.phase,
                        sha256: upload.signed.sha256, signature: upload.signed.signature,
                        frames: video.frameUploads.map {
                            ProofBody.FrameRef(fileURL: $0.fileURL.absoluteString, sha256: $0.signed.sha256, signature: $0.signed.signature)
                        }
                    )
                }
            }
            let fileRefs = (files[item.id] ?? []).compactMap { $0.fileURL.map { ProofBody.FileRef(fileURL: $0.absoluteString) } }
            return ProofBody.Item(
                checklistItemId: item.id,
                photos: uploaded.isEmpty ? nil : uploaded,
                videos: clips.isEmpty ? nil : clips,
                link: Self.normalizedLink(links[item.id]),
                files: fileRefs.isEmpty ? nil : fileRefs,
                checkIn: checkIns[item.id].map { ProofBody.CheckInRef(latitude: $0.latitude, longitude: $0.longitude, at: $0.at) }
            )
        })
    }

    /// "github.com/me/site" becomes "https://github.com/me/site"; blank or unparseable is nil.
    static func normalizedLink(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return candidate
    }
}

// MARK: - Wire types

struct ProofBody: Encodable, Sendable {
    let items: [Item]

    struct Item: Encodable, Sendable {
        let checklistItemId: String
        var photos: [PhotoRef]?
        var videos: [VideoRef]?
        var link: String?
        var files: [FileRef]?
        var checkIn: CheckInRef?
    }

    struct PhotoRef: Encodable, Sendable {
        let fileURL: String
        let capturedAt: Date
        let latitude: Double?
        let longitude: Double?
        let phase: String
        let sha256: String?
        let signature: String?
    }

    struct VideoRef: Encodable, Sendable {
        let fileURL: String
        let capturedAt: Date
        let latitude: Double?
        let longitude: Double?
        let phase: String
        let sha256: String
        let signature: String?
        let frames: [FrameRef]
    }

    struct FrameRef: Encodable, Sendable {
        let fileURL: String
        let sha256: String
        let signature: String?
    }

    struct FileRef: Encodable, Sendable {
        let fileURL: String
    }

    struct CheckInRef: Encodable, Sendable {
        let latitude: Double
        let longitude: Double
        let at: Date
    }
}

/// `POST /jobs/{id}/proof/precheck`. Each list holds checklist item IDs.
struct ProofChecks: Decodable, Sendable {
    let ok: Bool
    let missingRequired: [String]
    let outsideTimeWindow: [String]
    let outsideGeofence: [String]
    let duplicates: [String]
    let missingUploads: [String]
    /// Photos or videos the server couldn't verify as taken with the Bounty camera for this job.
    var notCapturedInApp: [String]?
    let warnings: [String]

    /// What's wrong with one item, phrased for the worker. `nil` when nothing is.
    func problem(for itemId: String) -> String? {
        if missingUploads.contains(itemId) { return "An upload didn\u{2019}t finish. Take it again." }
        if notCapturedInApp?.contains(itemId) == true { return "Take this again with the Bounty camera." }
        if missingRequired.contains(itemId) { return "Still needed." }
        if duplicates.contains(itemId) { return "Use a new photo. This one is a repeat." }
        if outsideTimeWindow.contains(itemId) { return "Taken before you started. Take it again." }
        if outsideGeofence.contains(itemId) { return "Taken away from the job location. The reviewer will see this." }
        return nil
    }
}

private struct PrecheckResponse: Decodable, Sendable {
    let checks: ProofChecks
}

/// One row of `GET /jobs/{id}/proofs` (US-42).
struct ProofAttemptResult: Decodable, Sendable {
    let attempt: Int?
    let verdicts: [Verdict]
    let decision: String?
    let workerFeedback: String?
}

extension APIClient {
    /// Presigns, then PUTs the bytes. Returns the file URL to send with the proof.
    func upload(_ data: Data, contentType: String) async throws -> URL {
        let target: PresignedUpload = try await request(.post, "uploads/presign", body: ["contentType": contentType])
        try await target.put(data, contentType: contentType)
        return target.fileURL
    }
}

extension UIImage {
    /// JPEG under the server's 5 MB photo limit, with the long side at most `maxSide` points.
    func proofJPEG(maxSide: CGFloat = 2048) -> Data? {
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.75)
    }
}

// MARK: - 10 Proof capture

struct ProofCaptureView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var services
    @Environment(MarketplaceStore.self) private var marketplace
    @Environment(ProofStore.self) private var proofStore
    @StateObject private var location = JobLocationProvider()
    /// The item and phase the camera is open for.
    @State private var camera: CameraRequest?
    @State private var filePickerItem: ChecklistItem?
    @State private var previousVerdicts: [Verdict] = []

    private struct CameraRequest: Identifiable {
        let item: ChecklistItem
        let phase: String
        let video: Bool
        var id: String { "\(item.id)-\(phase)-\(video)" }
    }

    private var job: PostedJob? {
        marketplace.workingJobs.first { $0.id == router.workerJobId } ?? marketplace.workingJobs.first
    }

    var body: some View {
        if let job {
            content(job: job, draft: proofStore.draft(for: job.id))
        } else {
            BountyScreen {
                NavRow(leadingAction: router.back) { Text("Proof").bountyType(.bodyStrong) } trailing: { EmptyView() }
                Text("This job isn\u{2019}t assigned to you anymore.")
                    .bountyType(.body)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        }
    }

    private func content(job: PostedJob, draft: ProofDraft) -> some View {
        BountyScreen {
            NavRow(leadingAction: router.back) {
                Text("Proof").bountyType(.bodyStrong)
            } trailing: {
                if let attempts = job.attempts, attempts.failed > 0 {
                    Chip(label: "\(attempts.retriesLeft) \(attempts.retriesLeft == 1 ? "retry" : "retries") left", tone: .coral)
                }
            }
            .entrance(.top)

            TitleSubtitle(title: job.title, subtitle: "Due \(job.deadlineText)")
                .entrance(.top)

            Label("Take photos or a short video with the Bounty camera. Each one is verified automatically, so there\u{2019}s nothing to write on your work.", icon: .shieldCheck)
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.inkSecondary)
                .entrance(.rest(0))

            ForEach(Array(job.checklist.enumerated()), id: \.element.id) { index, item in
                EvidenceCard(
                    item: item,
                    draft: draft,
                    problem: draft.checks?.problem(for: item.id),
                    previous: previousVerdicts.first { $0.checklistItemId == item.id && !$0.pass },
                    onCamera: { phase, video in camera = CameraRequest(item: item, phase: phase, video: video) },
                    onFile: { filePickerItem = item },
                    onCheckIn: { Task { await checkIn(item, job: job, draft: draft) } },
                    onRetryUpload: { Task { await retryUploads(job: job, draft: draft) } }
                )
                .entrance(.rest(index + 1))
            }

            if let checks = draft.checks, checks.ok {
                Label(checks.warnings.isEmpty ? "Everything checks out. Ready to submit." : "Ready to submit. The reviewer will see: \(checks.warnings.joined(separator: "; "))",
                      icon: .badgeCheck)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.mintInk)
                    .padding(14)
                    .tintedPanel(BountyColor.mint, radius: BountyRadius.row)
            }
            if let message = draft.message {
                Text(message)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
            }
        } bottom: {
            VStack(spacing: 10) {
                PillButton(title: draft.isBusy ? "Checking…" : "Submit for review", icon: .check, style: .dark) {
                    Task { await submit(job: job, draft: draft) }
                }
                .disabled(draft.isBusy || draft.isUploading)
                .opacity(draft.isBusy || draft.isUploading ? 0.5 : 1)
                Text(draft.isUploading ? "Uploading\u{2026}" : "The AI checks each item, then the poster makes the final call.")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkTertiary)
            }
        }
        .fullScreenCover(item: $camera) { request in
            CameraCapture(
                ghost: request.phase == "after"
                    ? (draft.photos(for: request.item, phase: "before").last?.image ?? draft.videos(for: request.item, phase: "before").last?.thumbnail)
                    : nil,
                hint: request.item.angleHint,
                video: request.video,
                onCapture: { image in
                    camera = nil
                    Task { await addPhoto(image, item: request.item, phase: request.phase, job: job, draft: draft) }
                },
                onVideo: { url in
                    camera = nil
                    Task { await addVideo(url, item: request.item, phase: request.phase, job: job, draft: draft) }
                },
                onCancel: { camera = nil }
            )
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: Binding(get: { filePickerItem != nil }, set: { if !$0 { filePickerItem = nil } }),
                      allowedContentTypes: [.pdf, .jpeg, .png, .zip]) { result in
            guard let item = filePickerItem, case .success(let url) = result else { return }
            Task { await addFile(url, item: item, draft: draft) }
        }
        .task(id: job.id) {
            // A retry shows why each item failed last time.
            if job.status == .inProgress, (job.attempts?.failed ?? 0) > 0, let api = services.api,
               let attempts: [ProofAttemptResult] = try? await api.request(.get, "jobs/\(job.id)/proofs") {
                previousVerdicts = attempts.first?.verdicts ?? []
            }
        }
    }

    // MARK: Actions

    private func addPhoto(_ image: UIImage, item: ChecklistItem, phase: String, job: PostedJob, draft: ProofDraft) async {
        let capturedAt = CaptureSignature.captureTime()
        // In-person photos carry GPS; the server flags photos taken away from the job.
        let coordinate = job.isRemote ? nil : await location.current()?.coordinate
        let photo = ProofDraft.Photo(image: image, phase: phase, capturedAt: capturedAt,
                                     latitude: coordinate?.latitude, longitude: coordinate?.longitude)
        draft.photos[item.id, default: []].append(photo)
        draft.checks = nil
        await upload(photo.id, itemId: item.id, job: job, draft: draft)
    }

    private func upload(_ photoId: UUID, itemId: String, job: PostedJob, draft: ProofDraft) async {
        guard let api = services.api,
              let index = draft.photos[itemId]?.firstIndex(where: { $0.id == photoId }),
              let photo = draft.photos[itemId]?[index],
              let data = photo.image.proofJPEG() else { return }
        draft.photos[itemId]?[index].failed = false
        // Signed over the exact bytes that are uploaded, right after capture.
        let signed = CaptureSignature.sign(data, jobId: job.id, capturedAt: photo.capturedAt,
                                           latitude: photo.latitude, longitude: photo.longitude, key: job.captureKey)
        do {
            let url = try await api.upload(data, contentType: "image/jpeg")
            if let index = draft.photos[itemId]?.firstIndex(where: { $0.id == photoId }) {
                draft.photos[itemId]?[index].fileURL = url
                draft.photos[itemId]?[index].signed = signed
            }
            draft.message = nil
        } catch {
            if let index = draft.photos[itemId]?.firstIndex(where: { $0.id == photoId }) { draft.photos[itemId]?[index].failed = true }
            draft.message = error.localizedDescription
        }
    }

    private func addVideo(_ url: URL, item: ChecklistItem, phase: String, job: PostedJob, draft: ProofDraft) async {
        let capturedAt = CaptureSignature.captureTime()
        let coordinate = job.isRemote ? nil : await location.current()?.coordinate
        let frames = await VideoFrames.extract(from: url)
        guard let thumbnail = frames.first else {
            draft.message = "That video couldn\u{2019}t be read. Record it again."
            return
        }
        let video = ProofDraft.Video(localURL: url, thumbnail: thumbnail, frames: frames, phase: phase, capturedAt: capturedAt,
                                     latitude: coordinate?.latitude, longitude: coordinate?.longitude)
        draft.videos[item.id, default: []].append(video)
        draft.checks = nil
        await uploadVideo(video.id, itemId: item.id, job: job, draft: draft)
    }

    /// Uploads the clip and its stills; each is signed like a photo.
    private func uploadVideo(_ videoId: UUID, itemId: String, job: PostedJob, draft: ProofDraft) async {
        guard let api = services.api,
              let index = draft.videos[itemId]?.firstIndex(where: { $0.id == videoId }),
              let video = draft.videos[itemId]?[index] else { return }
        draft.videos[itemId]?[index].failed = false
        func sign(_ data: Data) -> CaptureSignature.Signed {
            CaptureSignature.sign(data, jobId: job.id, capturedAt: video.capturedAt,
                                  latitude: video.latitude, longitude: video.longitude, key: job.captureKey)
        }
        do {
            let data = try Data(contentsOf: video.localURL)
            guard data.count <= 60 * 1024 * 1024 else { throw JobsAPIError.server("Videos can be up to 60 MB. Record a shorter clip.") }
            var frameUploads: [ProofDraft.Video.Upload] = []
            for frame in video.frames {
                guard let jpeg = frame.proofJPEG(maxSide: 1600) else { continue }
                let url = try await api.upload(jpeg, contentType: "image/jpeg")
                frameUploads.append(.init(fileURL: url, signed: sign(jpeg)))
            }
            let url = try await api.upload(data, contentType: VideoFrames.contentType(of: video.localURL))
            if let index = draft.videos[itemId]?.firstIndex(where: { $0.id == videoId }) {
                draft.videos[itemId]?[index].frameUploads = frameUploads
                draft.videos[itemId]?[index].upload = .init(fileURL: url, signed: sign(data))
            }
            draft.message = nil
        } catch {
            if let index = draft.videos[itemId]?.firstIndex(where: { $0.id == videoId }) { draft.videos[itemId]?[index].failed = true }
            draft.message = error.localizedDescription
        }
    }

    private func retryUploads(job: PostedJob, draft: ProofDraft) async {
        for (itemId, photos) in draft.photos {
            for photo in photos where photo.failed { await upload(photo.id, itemId: itemId, job: job, draft: draft) }
        }
        for (itemId, videos) in draft.videos {
            for video in videos where video.failed { await uploadVideo(video.id, itemId: itemId, job: job, draft: draft) }
        }
    }

    private func addFile(_ url: URL, item: ChecklistItem, draft: ProofDraft) async {
        guard let api = services.api else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        let contentType = type?.preferredMIMEType ?? "application/pdf"
        var file = ProofDraft.File(name: url.lastPathComponent)
        draft.files[item.id, default: []].append(file)
        draft.checks = nil
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 20 * 1024 * 1024 else { throw JobsAPIError.server("Files can be up to 20 MB.") }
            file.fileURL = try await api.upload(data, contentType: contentType)
        } catch {
            file.failed = true
            draft.message = error.localizedDescription
        }
        if let index = draft.files[item.id]?.firstIndex(where: { $0.id == file.id }) { draft.files[item.id]?[index] = file }
    }

    private func checkIn(_ item: ChecklistItem, job: PostedJob, draft: ProofDraft) async {
        guard let coordinate = await location.current()?.coordinate else {
            draft.message = "Location access is needed to check in. Turn it on in Settings."
            return
        }
        draft.checkIns[item.id] = .init(latitude: coordinate.latitude, longitude: coordinate.longitude, at: .now)
        draft.checks = nil
    }

    /// Runs the server checks first so problems show per item (US-39), then submits (US-41).
    private func submit(job: PostedJob, draft: ProofDraft) async {
        guard let api = services.api else { return }
        draft.isBusy = true
        draft.message = nil
        defer { draft.isBusy = false }
        let body = draft.body(for: job)
        do {
            let precheck: PrecheckResponse = try await api.request(.post, "jobs/\(job.id)/proof/precheck", body: body)
            draft.checks = precheck.checks
            guard precheck.checks.ok else {
                draft.message = "Fix the items marked below, then submit again."
                return
            }
            let submitted: PostedJob = try await api.request(.post, "jobs/\(job.id)/proof", body: body)
            marketplace.replace(submitted)
            draft.checks = nil
            router.open(.proofCheck, workerJob: job.id)
        } catch {
            draft.message = error.localizedDescription
        }
    }
}

private struct EvidenceCard: View {
    let item: ChecklistItem
    let draft: ProofDraft
    let problem: String?
    let previous: Verdict?
    /// Phase, and whether to record a video instead of a photo.
    let onCamera: (String, Bool) -> Void
    let onFile: () -> Void
    let onCheckIn: () -> Void
    let onRetryUpload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // On a retry, an item the AI failed needs new evidence even though the old upload still "covers" it.
                StatusBadge(status: previous != nil ? .active : draft.isCovered(item) ? .done : .todo)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text)
                        .bountyType(.subheadStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                    if let hint = item.angleHint, item.evidenceType == .photo {
                        Text(hint).bountyType(.footnote).foregroundStyle(BountyColor.inkSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Chip(label: item.isRequired ? item.evidenceType.displayName : "Optional", tone: .grey)
            }

            if let previous {
                Text("Last time: \(previous.explanation)")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.coral)
            }

            switch item.evidenceType {
            case .photo:
                if item.needsBeforePhoto {
                    photoRow(phase: "before", title: "Before", needed: 1)
                }
                photoRow(phase: "after", title: item.needsBeforePhoto ? "After" : "Photos", needed: item.photoCount ?? 1)
            case .link:
                TextField("https://", text: Binding(get: { draft.links[item.id] ?? "" }, set: { draft.links[item.id] = $0; draft.checks = nil }))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .fieldBackground(height: 46)
            case .file:
                ForEach(draft.files[item.id] ?? []) { file in
                    Label(file.name, systemImage: file.failed ? "exclamationmark.triangle" : file.fileURL == nil ? "arrow.up.circle" : "doc.fill")
                        .bountyType(.footnote)
                        .foregroundStyle(file.failed ? BountyColor.red : BountyColor.inkSecondary)
                }
                HStack {
                    PillButton(title: "Add file", icon: .plus, style: .secondary, action: onFile)
                    PillButton(title: "Photo", icon: .camera, style: .secondary) { onCamera("after", false) }
                }
            case .checkIn:
                if let checkIn = draft.checkIns[item.id] {
                    Label("Checked in at \(checkIn.at.formatted(date: .omitted, time: .shortened))", icon: .mapPin)
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.mintInk)
                } else {
                    PillButton(title: "Check in here", icon: .locate, style: .secondary, action: onCheckIn)
                }
            }

            if let problem {
                Text(problem).bountyType(.footnote).foregroundStyle(BountyColor.red)
            }
        }
        .padding(16)
        .borderedCard()
    }

    private func photoRow(phase: String, title: String, needed: Int) -> some View {
        let photos = draft.photos(for: item, phase: phase)
        let videos = draft.videos(for: item, phase: phase)
        let progress = videos.isEmpty ? "\(min(photos.count, needed)) of \(needed)" : "video"
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(title) · \(progress)")
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.inkSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(photos) { photo in
                        Image(uiImage: photo.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                if photo.failed {
                                    Button(action: onRetryUpload) {
                                        Image(systemName: "arrow.clockwise.circle.fill").font(.title2).foregroundStyle(.white, BountyColor.red)
                                    }
                                    .accessibilityLabel("Retry upload")
                                } else if photo.fileURL == nil {
                                    ProgressView().tint(.white)
                                }
                            }
                    }
                    ForEach(videos) { video in
                        Image(uiImage: video.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                if video.failed {
                                    Button(action: onRetryUpload) {
                                        Image(systemName: "arrow.clockwise.circle.fill").font(.title2).foregroundStyle(.white, BountyColor.red)
                                    }
                                    .accessibilityLabel("Retry upload")
                                } else if !video.isUploaded {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white)
                                }
                            }
                            .accessibilityLabel("\(title) video")
                    }
                    Button { onCamera(phase, false) } label: {
                        IconGlyph(icon: .camera, size: 22)
                            .frame(width: 72, height: 72)
                            .background(BountyColor.field, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Take \(title.lowercased()) photo")
                    Button { onCamera(phase, true) } label: {
                        Image(systemName: "video")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(BountyColor.inkPrimary)
                            .frame(width: 72, height: 72)
                            .background(BountyColor.field, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Record \(title.lowercased()) video")
                }
            }
        }
    }
}

// MARK: - Camera

/// The system camera, with the "before" shot as a ghost overlay for matching the angle (US-38).
/// Library photos and videos are deliberately not offered: proof comes from the camera here.
struct CameraCapture: View {
    let ghost: UIImage?
    let hint: String?
    /// Record a short video instead of taking a photo.
    var video = false
    let onCapture: (UIImage) -> Void
    var onVideo: (URL) -> Void = { _ in }
    let onCancel: () -> Void

    var body: some View {
        // The Simulator's simulated camera shows a preview but can't take a picture.
        #if targetEnvironment(simulator)
        let hasCamera = false
        #else
        let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
        if hasCamera {
            CameraPicker(ghost: ghost, hint: hint, video: video, onCapture: onCapture, onVideo: onVideo, onCancel: onCancel)
        } else {
            NoCameraView(video: video, onCapture: onCapture, onCancel: onCancel)
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    /// Long enough to pan across finished work, short enough to upload quickly.
    static let maxVideoSeconds: TimeInterval = 20

    let ghost: UIImage?
    let hint: String?
    let video: Bool
    let onCapture: (UIImage) -> Void
    let onVideo: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onVideo: onVideo, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if video {
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
            picker.videoMaximumDuration = Self.maxVideoSeconds
            picker.videoQuality = .typeMedium
        } else {
            picker.cameraCaptureMode = .photo
        }
        picker.delegate = context.coordinator
        picker.cameraOverlayView = overlay(bounds: UIScreen.main.bounds)
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    /// A see-through layer: the ghost fills the 4:3 preview under the top bar, the reminder sits above it.
    private func overlay(bounds: CGRect) -> UIView {
        let view = UIView(frame: bounds)
        view.isUserInteractionEnabled = false
        let previewHeight = bounds.width * 4 / 3
        let top = max(0, (bounds.height - previewHeight) / 2 - 40)
        if let ghost {
            let imageView = UIImageView(image: ghost)
            imageView.frame = CGRect(x: 0, y: top, width: bounds.width, height: previewHeight)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.alpha = 0.35
            view.addSubview(imageView)
        }
        let lines = [
            video ? "Slowly show the finished work (up to \(Int(Self.maxVideoSeconds)) s)" : nil,
            hint,
            ghost == nil ? nil : "Line up with the faded before shot",
        ].compactMap { $0 }
        if !lines.isEmpty {
            let label = UILabel()
            label.text = lines.joined(separator: "\n")
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 10
            label.clipsToBounds = true
            let size = label.sizeThatFits(CGSize(width: bounds.width - 48, height: .greatestFiniteMagnitude))
            label.frame = CGRect(x: 24, y: top + 12, width: bounds.width - 48, height: size.height + 16)
            view.addSubview(label)
        }
        return view
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onVideo: (URL) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onVideo: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onVideo = onVideo
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL, let copy = VideoFrames.keepCopy(of: url) {
                onVideo(copy)
            } else if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}

/// The Simulator has no camera. Debug builds can submit a generated test photo so the flow can be
/// exercised end to end; release builds just explain.
private struct NoCameraView: View {
    let video: Bool
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: video ? "video.fill" : "camera.fill").font(.largeTitle)
            Text(video ? "Recording needs a real iPhone." : "This device has no camera.").bountyType(.bodyStrong)
            #if DEBUG
            if !video {
                PillButton(title: "Use a test photo", icon: .images) { onCapture(Self.testPhoto()) }
                    .padding(.horizontal, 24)
            }
            #endif
            Button("Cancel", action: onCancel)
            Spacer()
        }
        .foregroundStyle(BountyColor.inkInverse)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BountyColor.night)
    }

    #if DEBUG
    /// A unique image each time (the server rejects the same image twice) showing the time.
    static func testPhoto() -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: .random(in: 0...1), saturation: 0.25, brightness: 0.95, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "TEST PHOTO\n\(Date.now.formatted(date: .abbreviated, time: .standard))\n\(UUID().uuidString.prefix(8))"
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            (text as NSString).draw(in: CGRect(x: 60, y: 560, width: 1080, height: 600), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 96, weight: .bold),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
            ])
        }
    }
    #endif
}

// MARK: - 11 Proof results

/// After submitting: waits for the AI review, then shows each item's result and what happens next (US-42/43/47).
struct ProofCheckView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var services
    @Environment(MarketplaceStore.self) private var marketplace
    @State private var attempt: ProofAttemptResult?

    private var job: PostedJob? {
        marketplace.workingJobs.first { $0.id == router.workerJobId } ?? marketplace.workingJobs.first
    }

    var body: some View {
        BountyScreen {
            NavRow(leadingAction: { router.finish(on: .home) }) {
                Text("Proof check").bountyType(.bodyStrong)
            } trailing: {
                if let job, !job.verdicts.isEmpty {
                    let passed = job.verdicts.filter(\.pass).count
                    Chip(label: "\(passed) of \(job.verdicts.count) passed", tone: passed == job.verdicts.count ? .mint : .coral)
                }
            }
            .entrance(.top)

            if let job {
                header(job)
                    .entrance(.top)

                if !job.verdicts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(job.checklist) { item in
                            if let verdict = job.verdict(for: item) {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: verdict.pass ? "checkmark.circle.fill" : verdict.verdict == "unclear" ? "questionmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(verdict.pass ? BountyColor.greenInk : verdict.verdict == "unclear" ? BountyColor.yellowDeep : BountyColor.red)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.text).bountyType(.subheadStrong)
                                        Text(verdict.explanation).bountyType(.footnote).foregroundStyle(BountyColor.inkSecondary)
                                        Text("Confidence \(verdict.confidence.formatted(.percent.precision(.fractionLength(0))))")
                                            .bountyType(.caption)
                                            .foregroundStyle(BountyColor.inkTertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .borderedCard()
                    .entrance(.rest(0))
                }

                if let feedback = attempt?.workerFeedback, job.status == .inProgress {
                    Text(feedback)
                        .bountyType(.subhead)
                        .foregroundStyle(BountyColor.creamInk)
                        .padding(14)
                        .tintedPanel(BountyColor.cream, radius: BountyRadius.row)
                }
            }
        } bottom: {
            if let job, job.status == .inProgress, job.allows("submit_proof") {
                PillButton(title: "Fix and resubmit", icon: .camera, style: .dark) {
                    router.open(.proofCapture, workerJob: job.id)
                }
            } else {
                PillButton(title: "Done") { router.finish(on: .home) }
            }
        }
        .task(id: job?.id) { await poll() }
    }

    @ViewBuilder
    private func header(_ job: PostedJob) -> some View {
        switch job.status {
        case .submitted:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("The AI is checking your proof").bountyType(.bodyStrong)
                }
                Text("This usually takes a few seconds. You can leave this screen; we\u{2019}ll notify you.")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
            .padding(16)
            .tintedPanel(BountyColor.lavenderSoft, radius: BountyRadius.row)
        case .inReview:
            VStack(alignment: .leading, spacing: 6) {
                if job.review?.requiresPosterAction == true {
                    Text("\(job.poster?.name ?? "The poster") will decide").bountyType(.bodyStrong)
                    Text("The AI wasn\u{2019}t sure about everything, so the poster reviews it before payment.")
                        .bountyType(.footnote)
                } else {
                    Text("Passed. \(job.poster?.name ?? "The poster") has the final say.").bountyType(.bodyStrong)
                    if let deadline = job.review?.windowEndsAt ?? job.reviewDeadline {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("No answer by \(deadline.formatted(date: .omitted, time: .shortened))? Your \(job.payText) is released automatically\(deadline > context.date ? " in \(Self.remaining(until: deadline, at: context.date))" : "").")
                                .bountyType(.footnote)
                        }
                    }
                }
            }
            .foregroundStyle(BountyColor.mintInk)
            .padding(16)
            .tintedPanel(BountyColor.mint, radius: BountyRadius.row)
        case .inProgress:
            VStack(alignment: .leading, spacing: 6) {
                Text("Some items didn\u{2019}t pass").bountyType(.bodyStrong)
                if let attempts = job.attempts {
                    Text(job.allows("submit_proof")
                         ? "Replace the evidence marked below and resubmit. \(attempts.retriesLeft) \(attempts.retriesLeft == 1 ? "retry" : "retries") left."
                         : "No retries left. The poster will decide.")
                        .bountyType(.footnote)
                }
            }
            .foregroundStyle(BountyColor.creamInk)
            .padding(16)
            .tintedPanel(BountyColor.cream, radius: BountyRadius.row)
        case .released:
            statusPanel("Paid", "\(job.payText) is on its way to you.", BountyColor.mint, BountyColor.mintInk)
        case .refunded:
            statusPanel("Refunded", "The poster was refunded, so this job didn\u{2019}t pay out.", BountyColor.grey, BountyColor.inkPrimary)
        case .disputed:
            statusPanel("Disputed", "The poster disputed an item. An admin will decide.", BountyColor.cream, BountyColor.creamInk)
        default:
            EmptyView()
        }
    }

    private func statusPanel(_ title: String, _ detail: String, _ fill: Color, _ ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).bountyType(.bodyStrong)
            Text(detail).bountyType(.footnote)
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .tintedPanel(fill, radius: BountyRadius.row)
    }

    /// Refreshes the job every 3 s while it's being graded, then loads the attempt's feedback.
    private func poll() async {
        guard let api = services.api, let jobId = job?.id else { return }
        while !Task.isCancelled {
            if let fresh: PostedJob = try? await api.request(.get, "jobs/\(jobId)") {
                marketplace.replace(fresh)
                if fresh.status != .submitted {
                    let attempts: [ProofAttemptResult]? = try? await api.request(.get, "jobs/\(jobId)/proofs")
                    attempt = attempts?.first
                    if fresh.status != .inReview { return }
                }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    static func remaining(until deadline: Date, at now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now)))
        if seconds >= 3600 { return "\(seconds / 3600) h \(seconds % 3600 / 60) min" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
