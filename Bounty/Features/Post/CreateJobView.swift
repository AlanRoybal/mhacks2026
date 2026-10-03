import SwiftUI

// MARK: - 12 Post a job

/// Step 1 of posting (plan feature 8). Alan's layout from the Figma, driven by the shared
/// `CreateJobModel` in `PosterStore`, so the form survives moving to step 2 and back.
struct CreateJobView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var store

    @State private var isPickingLocation = false
    @State private var isPickingDeadline = false
    @FocusState private var isTyping: Bool

    var body: some View {
        @Bindable var form = store.form

        BountyScreen(spacing: 14) {
            ScreenTitle(title: "Post a job") {
                if isTyping {
                    // Multi-line fields and the decimal pad have no return key.
                    Button("Done") { isTyping = false }
                        .bountyType(.subheadStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                } else {
                    Chip(label: "Draft", tone: .grey)
                }
            }
            .entrance(.top)

            PosterPhotoRow(model: form)
                .entrance(.top)

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Title")
                TextField("What do you need done?", text: $form.title)
                    .bountyType(.body)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .focused($isTyping)
                    .fieldBackground()
            }
            .entrance(.top)

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Description")
                TextField("Describe the finished result", text: $form.description, axis: .vertical)
                    .bountyType(.body)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .lineLimit(2...4)
                    .focused($isTyping)
                    .padding(.vertical, 14)
                    .fieldBackground(height: 68)
            }
            .entrance(.rest(0))

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Category")
                FlowLayout(spacing: 8) {
                    ForEach(JobCategory.allCases) { option in
                        ChoiceChip(label: option.displayName, isSelected: option == form.category) {
                            form.category = option
                        }
                    }
                }
            }
            .entrance(.rest(1))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    FieldLabel(text: "Where")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ChoiceChip(label: "In person", isSelected: !form.isRemote) { form.isRemote = false }
                    ChoiceChip(label: "Remote", isSelected: form.isRemote) { form.isRemote = true }
                }
                Button {
                    isPickingLocation = true
                } label: {
                    HStack(spacing: 10) {
                        IconGlyph(icon: .mapPin, size: 20)
                            .foregroundStyle(BountyColor.inkSecondary)
                        Text(form.location?.address ?? "Add the address")
                            .bountyType(.body)
                            .foregroundStyle(form.location == nil ? BountyColor.inkTertiary : BountyColor.inkPrimary)
                            .lineLimit(1)
                    }
                    .fieldBackground()
                }
                .buttonStyle(PressableStyle())
                .opacity(form.isRemote ? 0.4 : 1)
                .disabled(form.isRemote)
                .animation(Motion.pressTint, value: form.isRemote)
            }
            .entrance(.rest(2))

            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Deadline")
                    Button {
                        isPickingDeadline = true
                    } label: {
                        HStack(spacing: 10) {
                            IconGlyph(icon: .clock, size: 20)
                                .foregroundStyle(BountyColor.inkSecondary)
                            Text(form.deadline.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                .bountyType(.body)
                                .foregroundStyle(BountyColor.inkPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .fieldBackground()
                    }
                    .buttonStyle(PressableStyle())
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Pay")
                    HStack(spacing: 10) {
                        HStack(spacing: 0) {
                            if form.currency == .usd {
                                Text("$").bountyType(.moneyM)
                            }
                            TextField("40", value: $form.payAmount, format: .number.precision(.fractionLength(0...2)))
                                .bountyType(.moneyM)
                                .keyboardType(.decimalPad)
                                .focused($isTyping)
                        }
                        .foregroundStyle(BountyColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            form.currency = form.currency == .usd ? .usdc : .usd
                        } label: {
                            Chip(label: form.currency.rawValue, tone: .grey)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Currency \(form.currency.rawValue). Tap to switch.")
                    }
                    .fieldBackground()
                }
            }
            .entrance(.rest(3))

            if let issue = form.blockingIssue {
                Text(issue)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .entrance(.rest(4))
            }
        } bottom: {
            PillButton(
                title: form.isGenerating ? "Drafting your checklist…" : "Draft the proof checklist",
                icon: .sparkles
            ) {
                isTyping = false
                Task {
                    if let job = await form.generateChecklist(store: store) {
                        router.open(.proofChecklist, posterJob: job.id)
                    }
                }
            }
            .disabled(!form.canGenerate)
            .opacity(form.canGenerate ? 1 : 0.45)
        }
        .scrollDismissesKeyboard(.immediately)
        .sheet(isPresented: $isPickingLocation) {
            LocationPicker(location: $form.location)
        }
        .sheet(isPresented: $isPickingDeadline) {
            DeadlinePicker(deadline: $form.deadline)
        }
        .alert("Couldn't draft the checklist", isPresented: Binding(
            get: { form.errorMessage != nil },
            set: { if !$0 { form.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(form.errorMessage ?? "")
        }
    }
}

private struct DeadlinePicker: View {
    @Binding var deadline: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenTitle(title: "Deadline", type: .title) {
                Button("Done") { dismiss() }
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
            }
            DatePicker("Deadline", selection: $deadline, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(BountyColor.yellowDeep)
        }
        .padding(20)
        .presentationDetents([.large])
    }
}

// MARK: - 13 Proof checklist

/// Step 2 of posting: "What counts as done" (plan feature 9). Shows the AI-drafted
/// requirements; the pencil opens an edit sheet, and edits save when the poster continues.
struct ProofChecklistView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var store

    @State private var items: [ChecklistItem] = []
    @State private var hasLoaded = false
    @State private var editing: EditTarget?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var job: Job? { store.job(router.posterJobId) }

    var body: some View {
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

            Text("It locks once the job is funded.")
                .bountyType(.body)
                .foregroundStyle(BountyColor.inkSecondary)
                .entrance(.top)

            HStack(spacing: 10) {
                IconGlyph(icon: .sparkles, size: 18)
                Text("Drafted by AI from your description. Edit anything.")
                    .bountyType(.subhead)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(BountyColor.lavenderInk)
            .padding(12)
            .tintedPanel(BountyColor.lavenderSoft, radius: 16)
            .entrance(.rest(0))

            VStack(spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        editing = EditTarget(item: item, isNew: false)
                    } label: {
                        RequirementCard(item: item)
                    }
                    .buttonStyle(PressableStyle())
                    .entrance(.rest(1 + min(index, 4)))
                }
            }

            Button {
                editing = EditTarget(item: ChecklistItem(text: "", evidenceType: .photo), isNew: true)
            } label: {
                HStack(spacing: 6) {
                    IconGlyph(icon: .plus, size: 18, weight: .semibold)
                    Text("Add a requirement")
                        .bountyType(.bodyStrong)
                }
                .foregroundStyle(BountyColor.lavenderInk)
            }
            .buttonStyle(PressableStyle())
            .entrance(.rest(5))
        } bottom: {
            PillButton(title: isSaving ? "Saving…" : "Looks right") {
                Task { await save() }
            }
            .disabled(items.isEmpty || isSaving)
            .opacity(items.isEmpty ? 0.45 : 1)
        }
        .onAppear {
            guard !hasLoaded, let job else { return }
            items = job.checklist
            hasLoaded = true
        }
        .sheet(item: $editing) { target in
            RequirementEditor(item: target.item, isNew: target.isNew) { result in
                apply(result, to: target)
            }
        }
        .alert("Couldn't save the checklist", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func apply(_ result: RequirementEditor.Result, to target: EditTarget) {
        switch result {
        case .saved(let item):
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
        case .deleted:
            items.removeAll { $0.id == target.item.id }
        }
    }

    private func save() async {
        guard let job else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await store.updateChecklist(jobId: job.id, checklist: items)
            router.open(.fundJob, posterJob: saved.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One requirement card: what must be true, the evidence owed, and the pencil.
private struct RequirementCard: View {
    let item: ChecklistItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Image(systemName: item.evidenceType.symbolName)
                        .font(.system(size: 12, weight: .medium))
                    Text(item.evidenceSummary)
                        .bountyType(.footnote)
                }
                .foregroundStyle(BountyColor.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconGlyph(icon: .pencil, size: 18)
                .foregroundStyle(BountyColor.inkSecondary)
        }
        .padding(14)
        .borderedCard(radius: BountyRadius.row)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit this requirement")
    }
}

// MARK: - 14 Fund the job

/// Step 3 of posting (plan feature 10). The job isn't offered to workers until it's funded.
/// Payment itself goes through `PaymentHandoff`, where Payments plugs in Stripe.
struct FundJobView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var store

    @State private var method = PaymentMethod.card
    @State private var isFunding = false
    @State private var errorMessage: String?

    enum PaymentMethod: Hashable {
        case card, usdc
    }

    private var job: Job? { store.job(router.posterJobId) }

    /// Open decision 4 in the plan: a 10% platform fee paid by the poster, shown at checkout.
    private static let feeRate: Decimal = 0.10

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

            if let job {
                HStack(spacing: 12) {
                    StickerTile(sticker: job.sticker, background: job.tileColor, size: 56, stickerSize: 46, radius: 17)
                    TitleSubtitle(
                        title: job.title,
                        subtitle: "Due \(job.deadlineText) · \(job.checklist.count) proof item\(job.checklist.count == 1 ? "" : "s")"
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .borderedCard(radius: BountyRadius.row)
                .entrance(.top)

                VStack(spacing: 12) {
                    priceRow("Job payment", money(job.payAmount, for: job))
                    priceRow("Platform fee (10%)", money(fee(for: job), for: job))
                    BountyColor.divider.frame(height: 1)
                    HStack {
                        Text("Total").bountyType(.bodyStrong)
                        Spacer()
                        Text(money(total(for: job), for: job)).bountyType(.moneyM)
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
                        Text("The worker gets \(money(job.payAmount, for: job)) only after the proof passes. Nobody finishes by \(job.deadlineText)? Full refund.")
                            .bountyType(.footnote)
                    }
                    .foregroundStyle(BountyColor.mintInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .tintedPanel(BountyColor.mint)
                .entrance(.rest(2))
            }
        } bottom: {
            VStack(spacing: 12) {
                PillButton(
                    title: payButtonTitle,
                    icon: method == .card && !isFunding ? .apple : nil,
                    style: .dark
                ) {
                    Task { await fund() }
                }
                .disabled(job == nil || isFunding)
                Text("Test mode · card 4242 4242 4242 4242")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkTertiary)
            }
        }
        .onAppear {
            if job?.currency == .usdc { method = .usdc }
        }
        .alert("Payment didn't go through", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var payButtonTitle: String {
        if isFunding { return "Confirming payment…" }
        guard let job else { return "Pay" }
        let amount = total(for: job).formatted(.number.precision(.fractionLength(2)))
        return method == .card ? "Pay $\(amount)" : "Pay \(amount) USDC"
    }

    private func fee(for job: Job) -> Decimal { job.payAmount * Self.feeRate }
    private func total(for job: Job) -> Decimal { job.payAmount + fee(for: job) }

    private func money(_ amount: Decimal, for job: Job) -> String {
        job.currency == .usdc
            ? "\(amount.formatted(.number.precision(.fractionLength(2)))) USDC"
            : amount.formatted(.currency(code: "USD"))
    }

    private func priceRow(_ label: String, _ amount: String) -> some View {
        HStack {
            Text(label).foregroundStyle(BountyColor.inkSecondary)
            Spacer()
            Text(amount).foregroundStyle(BountyColor.inkPrimary)
        }
        .bountyType(.body)
    }

    private func fund() async {
        guard let job else { return }
        isFunding = true
        defer { isFunding = false }
        do {
            _ = try await store.fund(job)
            store.form.reset()
            router.jobsSegment = .posted
            router.finish(on: .jobs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("Post a job") {
    CreateJobView()
        .environment(AppRouter())
        .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
