import SwiftUI

/// 04 Twin review.
struct TwinView: View {
    private let skills = [
        TwinSkill(name: "Logo & brand design", evidence: "Sent 3 logo invoices this year", source: "Gmail", confidence: 0.94),
        TwinSkill(name: "Graphic design", evidence: "Freelance designer · 2 yrs", source: "LinkedIn", confidence: 0.90),
        TwinSkill(name: "Calculus tutoring", evidence: "12 tutoring threads since 2025", source: "Gmail", confidence: 0.82),
        TwinSkill(name: "Product photography", evidence: "Etsy listing photos in your sent mail", source: "Gmail", confidence: 0.76)
    ]

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowLavender, height: 320), spacing: 8) {
            ScreenTitle(title: "Your twin", type: .title) {
                Chip(label: "Ready to match", tone: .mint)
            }
            .entrance(.top)

            StackCard(tone: .lavender, height: 124, bandTop: 90) {
                HStack(alignment: .top, spacing: 16) {
                    StickerView(sticker: .twin, size: 80)
                        .padding(.top, 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alan’s twin")
                            .bountyType(.headline)
                        Text("Designer & tutor · Ann Arbor")
                            .bountyType(.subhead)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        HStack(alignment: .top, spacing: 18) {
                            TwinStat(value: "14", label: "skills")
                            TwinStat(value: "3", label: "sources")
                            TwinStat(value: "92%", label: "confident")
                        }
                        .padding(.top, 6)
                    }
                    .foregroundStyle(BountyColor.inkPrimary)
                    .padding(.top, 12)
                }
                .padding(.leading, 14)
            }
            .entrance(.top)

            SectionHeader(title: "Skills it found", trailing: "Edit", trailingColor: BountyColor.lavenderInk, trailingType: .bodyStrong) {}
                .entrance(.rest(0))

            VStack(spacing: 0) {
                ForEach(skills) { skill in
                    SkillRow(skill: skill)
                    if skill.id != skills.last?.id {
                        BountyColor.divider.frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .borderedCard()
            .entrance(.rest(1))

            PillButton(title: "Add a skill", icon: .plus, style: .secondary) {}
                .entrance(.rest(2))
        }
    }
}

private struct TwinSkill: Identifiable {
    var id: String { name }
    let name: String
    let evidence: String
    let source: String
    let confidence: Double
}

private struct TwinStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).bountyType(.moneyM)
            Text(label).bountyType(.footnote)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SkillRow: View {
    let skill: TwinSkill

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(skill.name)
                    .bountyType(.subheadStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Chip(label: skill.source, tone: skill.source == "LinkedIn" ? .lavender : .sky)
            }
            Text(skill.evidence)
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.inkSecondary)
            HStack(spacing: 10) {
                Meter(value: skill.confidence)
                Text(skill.confidence, format: .percent.precision(.fractionLength(0)))
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    TwinView()
}
