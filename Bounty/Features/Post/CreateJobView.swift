import PhotosUI
import StripePaymentSheet
import SwiftUI

// MARK: - 12 Post a job

struct CreateJobView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PostDraft.self) private var draft
    @Environment(PosterStore.self) private var posterStore
    @State private var pickingDeadline = false
    @State private var pickingLocation = false
    @State private var pickedPhotos: [PhotosPickerItem] = []

    var body: some View {
        @Bindable var draft = draft
        BountyScreen(spacing: 14, alwaysBounces: true) {
            ScreenTitle(title: "Post a job") {
                HStack(spacing: 8) {
                    // Plan step 10: fills in the demo's coffee shop logo job.
                    Button {
                        withAnimation(Motion.press) { draft.fillDemo() }
                    } label: {
                        Chip(label: "Demo job", tone: .lavender)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityHint("Fills in a sample job: sketch a coffee shop logo for $15")
                    Chip(label: "Draft", tone: .grey)
                }
            }
            .entrance(.top)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    StickerTile(sticker: draft.sticker, background: draft.tileColor, size: 84, stickerSize: 66, radius: 18)
                    // Photos help workers see the job and give the AI a "before" reference (US-11).
                    ForEach(draft.photos) { photo in
                        Image(uiImage: photo.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                if photo.failed {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white, BountyColor.red)
                                } else if photo.fileURL == nil {
                                    ProgressView().tint(.white)
                                }
                            }
                            .contextMenu {
                                Button("Remove", role: .destructive) { draft.removePhoto(photo.id) }
                            }
                            .accessibilityLabel("Job photo")
                            .accessibilityAction(named: "Remove") { draft.removePhoto(photo.id) }
                    }
                    if draft.photos.count < 6 {
                        PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 6 - draft.photos.count, matching: .images) {
                            AddPhotoTile()
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .entrance(.top)
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                            await draft.addPhoto(image, api: posterStore.api)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Title")
                TextField("What do you need done?", text: $draft.title)
                    .bountyType(.body)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .fieldBackground()
            }
            .entrance(.top)

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Description")
                TextField("Add details", text: $draft.details, axis: .vertical)
                    .bountyType(.body)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .lineLimit(2...4)
                    .padding(.vertical, 14)
                    .fieldBackground(height: 68)
            }
            .entrance(.rest(0))

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Category")
                FlowLayout(spacing: 8) {
                    ForEach(PostDraft.categories, id: \.self) { option in
                        ChoiceChip(label: option, isSelected: option == draft.category) { draft.category = option }
                    }
                }
            }
            .entrance(.rest(1))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    FieldLabel(text: "Where")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ChoiceChip(label: "In person", isSelected: draft.inPerson) { draft.inPerson = true }
                    ChoiceChip(label: "Remote", isSelected: !draft.inPerson) { draft.inPerson = false }
                }
                HStack(spacing: 10) {
                    IconGlyph(icon: .mapPin, size: 20)
                        .foregroundStyle(BountyColor.inkSecondary)
                    TextField("Address", text: $draft.address)
                        .bountyType(.body)
                        .foregroundStyle(BountyColor.inkPrimary)
                    // Search or use the current location, so the job gets real coordinates.
                    IconButton(
                        icon: draft.location == nil ? .locate : .check,
                        label: draft.location == nil ? "Find the address" : "Address located",
                        size: 32,
                        iconSize: 16,
                        background: draft.location == nil ? BountyColor.pill : BountyColor.green
                    ) {
                        pickingLocation = true
                    }
                }
                .fieldBackground()
                .onChange(of: draft.address) { _, address in
                    // Typing a different address drops coordinates that no longer match it.
                    if let located = draft.location?.address, located != address { draft.location = nil }
                }
                .opacity(draft.inPerson ? 1 : 0.4)
                .disabled(!draft.inPerson)
                .animation(Motion.pressTint, value: draft.inPerson)
            }
            .entrance(.rest(2))

            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Deadline")
                    Button { pickingDeadline = true } label: {
                        HStack(spacing: 10) {
                            IconGlyph(icon: .clock, size: 20)
                                .foregroundStyle(BountyColor.inkSecondary)
                            Text(draft.deadlineText)
                                .bountyType(.body)
                                .foregroundStyle(BountyColor.inkPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .fieldBackground()
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Deadline, \(draft.deadlineText)")
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Pay")
                    HStack(spacing: 10) {
                        HStack(spacing: 0) {
                            Text("$")
                            TextField("40", value: $draft.pay, format: .number)
                                .keyboardType(.numberPad)
                        }
                        .bountyType(.moneyM)
                        .foregroundStyle(BountyColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Chip(label: "USD", tone: .grey)
                    }
                    .fieldBackground()
                }
            }
            .entrance(.rest(3))

            // Says what's missing while the checklist button is disabled.
            if let problem = draft.problem {
                HStack(spacing: 8) {
                    IconGlyph(icon: .pencil, size: 16)
                    Text(problem)
                        .bountyType(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(BountyColor.creamInk)
                .padding(12)
                .tintedPanel(BountyColor.cream, radius: BountyRadius.row)
                .transition(.opacity)
            }
            if let error = draft.syncError {
                Text(error)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
            }
        } bottom: {
            PillButton(title: draft.isSyncing ? "Drafting the checklist\u{2026}" : "Draft the proof checklist", icon: .sparkles) {
                Task { if await draft.syncDraft(api: posterStore.api) { router.open(.proofChecklist) } }
            }
            .disabled(draft.problem != nil || draft.isSyncing)
            .opacity(draft.problem == nil && !draft.isSyncing ? 1 : 0.4)
        }
        .sheet(isPresented: $pickingLocation) {
            LocationPicker(location: Binding(
                get: { draft.location },
                set: { picked in
                    draft.location = picked
                    if let address = picked?.address { draft.address = address }
                }
            ))
        }
        .sheet(isPresented: $pickingDeadline) {
            DatePicker("Deadline", selection: $draft.deadline, in: Date.now.addingTimeInterval(30 * 60)..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .padding()
                .presentationDetents([.medium, .large])
        }
    }
}

/// The dashed "Add photo" tile. Its own view because PhotosPicker builds its label off the main actor.
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
    }
}

// MARK: - 13 Proof checklist

/// The AI checklist for the backend draft, editable until funding locks it (US-13/14).
struct ProofChecklistView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PostDraft.self) private var draft
    @Environment(PosterStore.self) private var posterStore

    var body: some View {
        @Bindable var draft = draft
        BountyScreen(glow: ScreenGlow(BountyColor.glowLavender, height: 300), spacing: 14) {
            NavRow(leadingAction: router.back) {
                ProgressDots(total: 3, current: 1)
            } trailing: {
                Text("Step 2 of 3")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
            .entrance(.top)

            Text("What counts as done")
                .bountyType(.display)
                .foregroundStyle(BountyColor.inkPrimary)
                .entrance(.top)

            Text("Workers see this before accepting, and the AI checks their proof against it. It locks once the job is funded.")
                .bountyType(.body)
                .foregroundStyle(BountyColor.inkSecondary)
                .entrance(.top)

            HStack(spacing: 10) {
                IconGlyph(icon: .sparkles, size: 18)
                Text("Drafted by AI from your description. Edit anything.")
                    .bountyType(.subhead)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await draft.regenerateChecklist(api: posterStore.api) }
                } label: {
                    Text(draft.isSyncing ? "Working\u{2026}" : "Redo").bountyType(.subheadStrong)
                }
                .disabled(draft.isSyncing)
            }
            .foregroundStyle(BountyColor.lavenderInk)
            .padding(12)
            .tintedPanel(BountyColor.lavenderSoft, radius: 16)
            .entrance(.rest(0))

            VStack(spacing: 10) {
                ForEach(Array(draft.checklist.indices), id: \.self) { index in
                    ChecklistItemEditor(
                        item: $draft.checklist[index],
                        canMoveUp: index > 0,
                        canMoveDown: index < draft.checklist.count - 1,
                        onMove: { offset in
                            let target = index + offset
                            guard draft.checklist.indices.contains(target) else { return }
                            withAnimation(Motion.press) { draft.checklist.swapAt(index, target) }
                        },
                        onDelete: { withAnimation(Motion.press) { _ = draft.checklist.remove(at: index) } }
                    )
                }
            }
            .entrance(.rest(1))

            Button {
                withAnimation(Motion.press) { draft.checklist.append(ChecklistItem(text: "", evidenceType: .photo)) }
            } label: {
                HStack(spacing: 6) {
                    IconGlyph(icon: .plus, size: 18, weight: .semibold)
                    Text("Add a requirement")
                        .bountyType(.bodyStrong)
                }
                .foregroundStyle(BountyColor.lavenderInk)
            }
            .buttonStyle(PressableStyle())
            .entrance(.rest(2))

            if let error = draft.syncError {
                Text(error)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
            }
        } bottom: {
            PillButton(title: draft.isSyncing ? "Saving\u{2026}" : "Looks right") {
                Task { if await draft.saveChecklist(api: posterStore.api) { router.open(.fundJob) } }
            }
            .disabled(draft.isSyncing || draft.checklist.isEmpty)
        }
    }
}

/// One checklist item: its text, what evidence proves it, and order and delete controls.
private struct ChecklistItemEditor: View {
    @Binding var item: ChecklistItem
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                TextField("Requirement, e.g. \u{201C}Clippings are bagged\u{201D}", text: $item.text, axis: .vertical)
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .lineLimit(1...3)
                Menu {
                    Button("Move up", systemImage: "arrow.up") { onMove(-1) }.disabled(!canMoveUp)
                    Button("Move down", systemImage: "arrow.down") { onMove(1) }.disabled(!canMoveDown)
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    IconGlyph(icon: .ellipsis, size: 18)
                        .foregroundStyle(BountyColor.inkSecondary)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Requirement options")
            }
            FlowLayout(spacing: 8) {
                Menu {
                    Picker("Evidence", selection: Binding(get: { item.evidenceType }, set: { setEvidence($0) })) {
                        ForEach(EvidenceType.allCases) { Text($0.displayName).tag($0) }
                    }
                } label: {
                    Chip(label: item.evidenceType.displayName, tone: .lavender)
                }
                if item.evidenceType == .photo {
                    Menu {
                        Picker("Photos", selection: Binding(get: { item.photoCount ?? 1 }, set: { item.photoCount = $0 })) {
                            ForEach(1...4, id: \.self) { Text("\($0) photo\($0 == 1 ? "" : "s")").tag($0) }
                        }
                    } label: {
                        Chip(label: "\(item.photoCount ?? 1) photo\((item.photoCount ?? 1) == 1 ? "" : "s")", tone: .grey)
                    }
                    ChoiceChip(label: "Before & after", isSelected: item.beforeAfter == true) { item.beforeAfter = !(item.beforeAfter ?? false) }
                }
                ChoiceChip(label: item.isRequired ? "Required" : "Optional", isSelected: item.isRequired) { item.required = !item.isRequired }
            }
        }
        .padding(14)
        .borderedCard(radius: BountyRadius.row)
    }

    private func setEvidence(_ type: EvidenceType) {
        item.evidenceType = type
        item.photoCount = type == .photo ? (item.photoCount ?? 1) : nil
        if type != .photo { item.beforeAfter = false }
    }
}

// MARK: - 14 Fund the job

struct FundJobView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PostDraft.self) private var draft
    @Environment(PosterStore.self) private var posterStore
    @State private var method = PaymentMethod.card
    /// Card: the backend draft, funded through `JobFundingSheet`.
    @State private var fundingJob: PostedJob?
    /// USDC: the job as the payments server takes it (`CryptoCheckoutView`).
    @State private var checkout: FundingDraft?

    enum PaymentMethod: Hashable {
        case card, usdc
    }

    var body: some View {
        BountyScreen {
            NavRow(leadingAction: router.back) {
                ProgressDots(total: 3, current: 2)
            } trailing: {
                Text("Step 3 of 3")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
            .entrance(.top)

            Text("Fund your job")
                .bountyType(.display)
                .foregroundStyle(BountyColor.inkPrimary)
                .entrance(.top)

            HStack(spacing: 12) {
                StickerTile(sticker: draft.sticker, background: draft.tileColor, size: 56, stickerSize: 46, radius: 17)
                TitleSubtitle(title: draft.title, subtitle: "Due \(draft.deadlineText) · \(draft.checklist.count) proof items")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .borderedCard(radius: BountyRadius.row)
            .entrance(.top)

            VStack(spacing: 12) {
                priceRow("Job payment", method == .card ? money(draft.payCents) : "\(usdc(draft.payCents)) USDC")
                if method == .card { priceRow("Platform fee (10%)", money(draft.feeCents)) }
                BountyColor.divider.frame(height: 1)
                HStack {
                    Text("Total").bountyType(.bodyStrong)
                    Spacer()
                    Text(method == .card ? money(draft.totalCents) : "\(usdc(draft.payCents)) USDC").bountyType(.moneyM)
                }
                .foregroundStyle(BountyColor.inkPrimary)
            }
            .padding(16)
            .borderedCard()
            .entrance(.rest(0))

            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Pay with")
                SegmentedPill(options: [(PaymentMethod.card, "Card or Apple Pay"), (.usdc, "USDC")], selection: $method)
            }
            .entrance(.rest(1))

            HStack(spacing: 14) {
                StickerView(sticker: .shield, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Held until it’s done")
                        .bountyType(.bodyStrong)
                    Text("The worker gets \(money(draft.payCents)) only after the proof passes. Nobody finishes by the deadline? Full refund.")
                        .bountyType(.footnote)
                }
                .foregroundStyle(BountyColor.mintInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .tintedPanel(BountyColor.mint)
            .entrance(.rest(2))

            // The checks that decide whether the escrow is released, from the saved checklist.
            if let plan = draft.job?.verification {
                VerificationPlanCard(plan: plan, audience: .poster)
                    .entrance(.rest(3))
            }
        } bottom: {
            VStack(spacing: 12) {
                PillButton(
                    title: method == .card ? "Pay \(money(draft.totalCents))" : "Pay \(usdc(draft.payCents)) USDC",
                    icon: method == .card ? .apple : nil,
                    style: .dark
                ) {
                    if method == .card {
                        fundingJob = draft.job
                    } else {
                        Task {
                            // USDC escrow runs on the payments server, which keeps its own copy of the job.
                            await draft.discardBackendDraft(api: posterStore.api)
                            checkout = draft.fundingDraft()
                        }
                    }
                }
                .disabled(!draft.canFund || (method == .card && draft.job == nil))
                Text(method == .card ? "Test mode · card 4242 4242 4242 4242" : "Test USDC · Base Sepolia")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkTertiary)
            }
        }
        .sheet(item: $checkout) { funding in
            CryptoCheckoutView(draft: funding, onFunded: finishFunding)
        }
        .sheet(item: $fundingJob) { job in
            JobFundingSheet(job: job) { funded in
                posterStore.upsert(funded)
                finishFunding()
            }
        }
    }

    private func finishFunding() {
        draft.reset()
        router.jobsSegment = .posted
        router.finish(on: .jobs)
    }

    private func money(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "USD"))
    }

    private func usdc(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.number.precision(.fractionLength(2)))
    }

    private func priceRow(_ label: String, _ amount: String) -> some View {
        HStack {
            Text(label).foregroundStyle(BountyColor.inkSecondary)
            Spacer()
            Text(amount).foregroundStyle(BountyColor.inkPrimary)
        }
        .bountyType(.body)
    }
}

#Preview("Post a job") {
    CreateJobView()
        .environment(AppRouter())
        .environment(PostDraft())
}

#Preview("Proof checklist") {
    ProofChecklistView()
        .environment(AppRouter())
        .environment(PostDraft())
}

#Preview("Fund") {
    FundJobView()
        .environment(AppRouter())
        .environment(PostDraft())
        .environmentObject(PostedJobsStore())
}
