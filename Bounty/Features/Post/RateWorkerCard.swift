import SwiftUI

/// Plan step 9: once a job is paid (or refunded after someone worked on it), the poster rates the
/// worker 1–5 stars with an optional note (`POST /jobs/{id}/rating`). Shown under the outcome on
/// the review screen and on the job's timeline. After rating it shows what the poster gave.
struct RateWorkerCard: View {
    let job: PostedJob

    @Environment(PosterStore.self) private var store
    @State private var stars = 0
    @State private var comment = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var isCommentFocused: Bool

    var body: some View {
        if let rating = job.posterRating {
            given(rating)
        } else if job.canRateWorker {
            picker
        }
    }

    private var workerFirstName: String {
        job.worker?.name.split(separator: " ").first.map(String.init) ?? "the worker"
    }

    // MARK: Asking

    private var picker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How did \(workerFirstName) do?")
                .bountyType(.bodyStrong)
                .foregroundStyle(BountyColor.inkPrimary)

            StarRow(stars: stars, size: 34) { picked in
                withAnimation(Motion.press) { stars = picked }
            }
            .disabled(isSubmitting)

            if stars > 0 {
                Text(Self.label(for: stars))
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)

                TextField("Add a note (optional)", text: $comment, axis: .vertical)
                    .bountyType(.body)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .lineLimit(1...4)
                    .focused($isCommentFocused)
                    .padding(.vertical, 14)
                    .fieldBackground()
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { isCommentFocused = false }
                        }
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.red)
                }

                PillButton(title: isSubmitting ? "Sending…" : "Rate \(workerFirstName)", icon: .check) {
                    Task { await submit() }
                }
                .disabled(isSubmitting)
                .opacity(isSubmitting ? 0.5 : 1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .borderedCard()
    }

    private func submit() async {
        guard stars > 0 else { return }
        isCommentFocused = false
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await store.rate(job, stars: stars, comment: comment)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Given

    private func given(_ rating: JobRating) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("You rated \(workerFirstName)")
                    .bountyType(.subheadStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StarRow(stars: rating.stars, size: 18)
            }
            if let note = rating.comment, !note.isEmpty {
                Text("“\(note)”")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .borderedCard(radius: BountyRadius.row)
    }

    static func label(for stars: Int) -> String {
        switch stars {
        case 1: "Not good"
        case 2: "Could be better"
        case 3: "Okay"
        case 4: "Good"
        default: "Great"
        }
    }
}

/// Five stars. Tappable when `onPick` is set, otherwise display only.
private struct StarRow: View {
    let stars: Int
    var size: CGFloat
    var onPick: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: onPick == nil ? 2 : 10) {
            ForEach(1...5, id: \.self) { index in
                let star = Image(systemName: index <= stars ? "star.fill" : "star")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(index <= stars ? BountyColor.yellow : BountyColor.inkTertiary)
                if let onPick {
                    Button { onPick(index) } label: {
                        star.frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("\(index) star\(index == 1 ? "" : "s")")
                    .accessibilityAddTraits(index == stars ? .isSelected : [])
                } else {
                    star
                }
            }
        }
        .accessibilityElement(children: onPick == nil ? .ignore : .contain)
        .accessibilityLabel(onPick == nil ? "\(stars) out of 5 stars" : "Rating")
    }
}

#Preview {
    VStack(spacing: 16) {
        RateWorkerCard(job: PostedJob(
            title: "Mow my lawn", deadline: .now, payAmount: 40, status: .released,
            worker: WorkerSummary(id: "w", name: "Jordan K.", rating: 4.9)
        ))
        RateWorkerCard(job: {
            var job = PostedJob(
                title: "Mow my lawn", deadline: .now, payAmount: 40, status: .released,
                worker: WorkerSummary(id: "w", name: "Jordan K.", rating: 4.9)
            )
            job.ratings = JobRatings(byPoster: JobRating(stars: 4, comment: "Fast and tidy."))
            return job
        }())
    }
    .padding()
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
