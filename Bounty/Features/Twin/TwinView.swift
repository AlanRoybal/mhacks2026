import SwiftUI

struct TwinView: View {
    private let skills = [
        TwinSkill(name: "Graphic design", confidence: 0.94, source: "LinkedIn"),
        TwinSkill(name: "Illustration", confidence: 0.89, source: "Résumé"),
        TwinSkill(name: "Calculus tutoring", confidence: 0.82, source: "Added by you"),
        TwinSkill(name: "Product photography", confidence: 0.76, source: "Résumé")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(BountyTheme.accent.gradient)
                            .frame(width: 92, height: 92)
                        Image(systemName: "person.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.white)
                    }

                    Text("Alan's twin")
                        .font(.title2.bold())
                    Label("Ready to match", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BountyTheme.success)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Skills")
                            .font(.title2.bold())
                        Spacer()
                        Button("Add", systemImage: "plus", action: {})
                    }

                    ForEach(skills) { skill in
                        SkillRow(skill: skill)
                        if skill.id != skills.last?.id {
                            Divider()
                        }
                    }
                }
                .bountyPanel()

                VStack(alignment: .leading, spacing: 14) {
                    Text("Preferences")
                        .font(.title2.bold())
                    LabeledContent("Minimum pay", value: "$15")
                    LabeledContent("Travel radius", value: "5 miles")
                    LabeledContent("Availability", value: "Evenings")
                    LabeledContent("Work type", value: "Remote + nearby")
                }
                .bountyPanel()
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Twin")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit", action: {})
            }
        }
    }
}

private struct TwinSkill: Identifiable {
    let id = UUID()
    let name: String
    let confidence: Double
    let source: String
}

private struct SkillRow: View {
    let skill: TwinSkill

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(skill.name)
                    .font(.headline)
                Spacer()
                Text(skill.confidence, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: skill.confidence)
                .tint(BountyTheme.accent)
            Text("From \(skill.source)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        TwinView()
    }
}
