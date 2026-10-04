import SwiftUI

// MARK: - 12 Post a job

struct CreateJobView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PostDraft.self) private var draft
    @State private var pickingDeadline = false
    @State private var pickingLocation = false

    var body: some View {
        @Bindable var draft = draft
        BountyScreen(spacing: 14) {
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

            HStack(spacing: 10) {
                StickerTile(sticker: draft.sticker, background: draft.tileColor, size: 84, stickerSize: 66, radius: 18)
                Button {} label: {
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
                .buttonStyle(PressableStyle())
            }
            .entrance(.top)

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
        } bottom: {
            PillButton(title: "Draft the proof checklist", icon: .sparkles) { router.open(.proofChecklist) }
                .disabled(draft.problem != nil)
                .opacity(draft.problem == nil ? 1 : 0.4)
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
            DatePicker("Deadline", selection: $draft.deadline, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .padding()
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - 13 Proof checklist

struct ProofChecklistView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PostDraft.self) private var draft

    typealias Requirement = (title: String, evidenceIcon: BountyIcon, evidence: String)

    /// Sample checklists until the backend drafts one before funding (the checkout creates the
    /// job only at payment). The demo's logo job gets its own, so it doesn't show lawn items.
    static func requirements(for draft: PostDraft) -> [Requirement] {
        switch draft.category {
        case "Design":
            [
                ("Hand-drawn logo with a coffee cup", .camera, "1 photo of the sketch"),
                ("Shop name is readable", .camera, "Same photo, checked by AI"),
                ("One-time code written on the page", .camera, "Shows it was drawn for this job")
            ]
        default:
            [
                ("Front lawn mowed, under 3 in", .camera, "4 after photos from marked angles"),
                ("Clippings bagged or mulched", .camera, "1 photo of the bags"),
                ("Sidewalk edges trimmed", .camera, "2 close-up photos"),
                ("On-site check-in and out", .locate, "GPS and time, automatic")
            ]
        }
    }

    private var requirements: [Requirement] { Self.requirements(for: draft) }

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
                ForEach(Array(requirements.enumerated()), id: \.offset) { index, requirement in
                    HStack(alignment: .top, spacing: 10) {
                        GripDots()
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(requirement.title)
                                .bountyType(.bodyStrong)
                                .foregroundStyle(BountyColor.inkPrimary)
                            HStack(spacing: 6) {
                                IconGlyph(icon: requirement.evidenceIcon, size: 14)
                                Text(requirement.evidence)
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
                    .entrance(.rest(1 + index))
                }
            }

            HStack(spacing: 6) {
                IconGlyph(icon: .plus, size: 18, weight: .semibold)
                Text("Add a requirement")
                    .bountyType(.bodyStrong)
            }
            .foregroundStyle(BountyColor.lavenderInk)
            .entrance(.rest(1 + requirements.count))
        } bottom: {
            PillButton(title: "Looks right") { router.open(.fundJob) }
        }
    }
}

/// Lucide grip-vertical: two columns of three dots.
private struct GripDots: View {
    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    Circle().frame(width: 3.5, height: 3.5)
                    Circle().frame(width: 3.5, height: 3.5)
                }
            }
        }
        .foregroundStyle(BountyColor.inkTertiary)
        .accessibilityHidden(true)
    }
}

// MARK: - 14 Fund the job

struct FundJobView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PostDraft.self) private var draft
    @State private var method = PaymentMethod.card
    /// Set to open Stripe's PaymentSheet through the payments server (PaymentCheckoutView).
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
                TitleSubtitle(title: draft.title, subtitle: "Due \(draft.deadlineText) · \(ProofChecklistView.requirements(for: draft).count) proof items")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .borderedCard(radius: BountyRadius.row)
            .entrance(.top)

            VStack(spacing: 12) {
                priceRow("Job payment", money(draft.payCents))
                priceRow("Platform fee (10%)", money(draft.feeCents))
                BountyColor.divider.frame(height: 1)
                HStack {
                    Text("Total").bountyType(.bodyStrong)
                    Spacer()
                    Text(money(draft.totalCents)).bountyType(.moneyM)
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
        } bottom: {
            VStack(spacing: 12) {
                PillButton(
                    title: method == .card ? "Pay \(money(draft.totalCents))" : "Pay \(usdc(draft.totalCents)) USDC",
                    icon: method == .card ? .apple : nil,
                    style: .dark
                ) {
                    if method == .card {
                        checkout = draft.fundingDraft()
                    } else {
                        // USDC escrow isn't built yet; this keeps the original simulated flow.
                        router.jobsSegment = .posted
                        router.finish(on: .jobs)
                    }
                }
                .disabled(!draft.canFund)
                Text("Test mode · card 4242 4242 4242 4242")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkTertiary)
            }
        }
        .sheet(item: $checkout) { funding in
            PaymentCheckoutView(draft: funding) {
                draft.reset()
                router.jobsSegment = .posted
                router.finish(on: .jobs)
            }
        }
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
