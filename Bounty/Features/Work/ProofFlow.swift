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
        var failed = false
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

    var isUploading: Bool {
        photos.values.joined().contains { $0.fileURL == nil && !$0.failed }
            || files.values.joined().contains { $0.fileURL == nil && !$0.failed }
    }

    /// Whether this device has what the item needs. The server's precheck has the final say.
    func isCovered(_ item: ChecklistItem) -> Bool {
        switch item.evidenceType {
        case .photo:
            let after = photos(for: item, phase: "after").filter { $0.fileURL != nil }.count
            let before = photos(for: item, phase: "before").filter { $0.fileURL != nil }.count
            return after >= (item.photoCount ?? 1) && (!item.needsBeforePhoto || before >= 1)
        case .checkIn:
            return checkIns[item.id] != nil
        case .link:
            return Self.normalizedLink(links[item.id]) != nil
        case .file:
            return (files[item.id] ?? []).contains { $0.fileURL != nil }
                || (photos[item.id] ?? []).contains { $0.fileURL != nil }
        }
    }

    /// One entry per checklist item, as the server requires on every submission.
    func body(for job: PostedJob) -> ProofBody {
        ProofBody(items: job.checklist.map { item in
            let uploaded = (photos[item.id] ?? []).compactMap { photo in
                photo.fileURL.map {
                    ProofBody.PhotoRef(fileURL: $0.absoluteString, capturedAt: photo.capturedAt,
                                       latitude: photo.latitude, longitude: photo.longitude, phase: photo.phase)
                }
            }
            let fileRefs = (files[item.id] ?? []).compactMap { $0.fileURL.map { ProofBody.FileRef(fileURL: $0.absoluteString) } }
            return ProofBody.Item(
                checklistItemId: item.id,
                photos: uploaded.isEmpty ? nil : uploaded,
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
    let warnings: [String]

    /// What's wrong with one item, phrased for the worker. `nil` when nothing is.
    func problem(for itemId: String) -> String? {
        if missingUploads.contains(itemId) { return "An upload didn\u{2019}t finish. Take it again." }
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
        var id: String { "\(item.id)-\(phase)" }
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

            if let code = job.challengeCode {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("One-time code").bountyType(.bodyStrong)
                        Spacer()
                        Text(code).font(.system(.title2, design: .monospaced).bold())
                    }
                    Text("Write it on paper or show it on a screen so it\u{2019}s visible in your photos. Library photos aren\u{2019}t accepted, so every photo comes from the camera here.")
                        .bountyType(.footnote)
                }
                .foregroundStyle(BountyColor.creamInk)
                .padding(16)
                .tintedPanel(BountyColor.cream, radius: BountyRadius.row)
                .entrance(.rest(0))
            }

            ForEach(Array(job.checklist.enumerated()), id: \.element.id) { index, item in
                EvidenceCard(
                    item: item,
                    draft: draft,
                    problem: draft.checks?.problem(for: item.id),
                    previous: previousVerdicts.first { $0.checklistItemId == item.id && !$0.pass },
                    onCamera: { phase in camera = CameraRequest(item: item, phase: phase) },
                    onFile: { filePickerItem = item },
                    onCheckIn: { Task { await checkIn(item, job: job, draft: draft) } },
                    onRetryUpload: { Task { await retryUploads(draft) } }
                )
                .entrance(.rest(index + 1))
            }

            if let checks = draft.checks, checks.ok {
                Label(checks.warnings.isEmpty ? "Everything checks out. Ready to submit." : "Ready to submit. The reviewer will see: \(checks.warnings.joined(separator: "; "))",
                      systemImage: "checkmark.seal.fill")
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
                ghost: request.phase == "after" ? draft.photos(for: request.item, phase: "before").last?.image : nil,
                hint: request.item.angleHint,
                code: job.challengeCode,
                onCapture: { image in
                    camera = nil
                    Task { await addPhoto(image, item: request.item, phase: request.phase, job: job, draft: draft) }
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
        let capturedAt = Date.now
        // In-person photos carry GPS; the server flags photos taken away from the job.
        let coordinate = job.isRemote ? nil : await location.current()?.coordinate
        let photo = ProofDraft.Photo(image: image, phase: phase, capturedAt: capturedAt,
                                     latitude: coordinate?.latitude, longitude: coordinate?.longitude)
        draft.photos[item.id, default: []].append(photo)
        draft.checks = nil
        await upload(photo.id, itemId: item.id, draft: draft)
    }

    private func upload(_ photoId: UUID, itemId: String, draft: ProofDraft) async {
        guard let api = services.api,
              let index = draft.photos[itemId]?.firstIndex(where: { $0.id == photoId }),
              let data = draft.photos[itemId]?[index].image.proofJPEG() else { return }
        draft.photos[itemId]?[index].failed = false
        do {
            let url = try await api.upload(data, contentType: "image/jpeg")
            if let index = draft.photos[itemId]?.firstIndex(where: { $0.id == photoId }) { draft.photos[itemId]?[index].fileURL = url }
            draft.message = nil
        } catch {
            if let index = draft.photos[itemId]?.firstIndex(where: { $0.id == photoId }) { draft.photos[itemId]?[index].failed = true }
            draft.message = error.localizedDescription
        }
    }

    private func retryUploads(_ draft: ProofDraft) async {
        for (itemId, photos) in draft.photos {
            for photo in photos where photo.failed { await upload(photo.id, itemId: itemId, draft: draft) }
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
    let onCamera: (String) -> Void
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
                    PillButton(title: "Photo", icon: .camera, style: .secondary) { onCamera("after") }
                }
            case .checkIn:
                if let checkIn = draft.checkIns[item.id] {
                    Label("Checked in at \(checkIn.at.formatted(date: .omitted, time: .shortened))", systemImage: "mappin.circle.fill")
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
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(title) · \(min(photos.count, needed)) of \(needed)")
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
                    Button { onCamera(phase) } label: {
                        IconGlyph(icon: .camera, size: 22)
                            .frame(width: 72, height: 72)
                            .background(BountyColor.field, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Take \(title.lowercased()) photo")
                }
            }
        }
    }
}

// MARK: - Camera

/// The system camera, with the "before" shot as a ghost overlay for matching the angle (US-38)
/// and the one-time code as a reminder. Library photos are deliberately not offered.
struct CameraCapture: View {
    let ghost: UIImage?
    let hint: String?
    let code: String?
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    var body: some View {
        // The Simulator's simulated camera shows a preview but can't take a picture.
        #if targetEnvironment(simulator)
        let hasCamera = false
        #else
        let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
        if hasCamera {
            CameraPicker(ghost: ghost, hint: hint, code: code, onCapture: onCapture, onCancel: onCancel)
        } else {
            NoCameraView(code: code, onCapture: onCapture, onCancel: onCancel)
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let ghost: UIImage?
    let hint: String?
    let code: String?
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
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
        let lines = [code.map { "Code \($0) must be visible" }, hint, ghost == nil ? nil : "Line up with the faded before photo"].compactMap { $0 }
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
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) } else { onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}

/// The Simulator has no camera. Debug builds can submit a generated test photo so the flow can be
/// exercised end to end; release builds just explain.
private struct NoCameraView: View {
    let code: String?
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("This device has no camera.").bountyType(.bodyStrong)
            #if DEBUG
            PillButton(title: "Use a test photo", icon: .images) { onCapture(Self.testPhoto(code: code)) }
                .padding(.horizontal, 24)
            #endif
            Button("Cancel", action: onCancel)
            Spacer()
        }
        .foregroundStyle(BountyColor.inkInverse)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BountyColor.night)
    }

    #if DEBUG
    /// A unique image each time (the server rejects the same image twice) showing the code and time.
    static func testPhoto(code: String?) -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: .random(in: 0...1), saturation: 0.25, brightness: 0.95, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "TEST PHOTO\n\(code ?? "")\n\(Date.now.formatted(date: .abbreviated, time: .standard))\n\(UUID().uuidString.prefix(8))"
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
