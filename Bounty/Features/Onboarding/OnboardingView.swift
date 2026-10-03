import SwiftUI

struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [BountyTheme.accent.opacity(0.18), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(BountyTheme.accent.gradient)
                        .frame(width: 92, height: 92)
                    Image(systemName: "person.fill")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.white)
                        .offset(y: 20)
                    Image(systemName: "sparkles")
                        .font(.title2.bold())
                        .foregroundStyle(BountyTheme.accent)
                        .padding(8)
                        .background(.background, in: Circle())
                        .offset(x: 8, y: -8)
                }
                .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text("Meet your work twin")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Text("Build a profile from your experience, get matched with paid work, and prove each job is done.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 18) {
                    OnboardingFeature(icon: "sparkles", title: "Matched for you", detail: "Your twin filters jobs by skills, time, pay, and distance.")
                    OnboardingFeature(icon: "checkmark.shield.fill", title: "Clear proof", detail: "Both sides agree on what finished work looks like before payment.")
                    OnboardingFeature(icon: "creditcard.fill", title: "Protected payment", detail: "Funded jobs release payment after review.")
                }
                .bountyPanel()

                Spacer()

                Button(action: onContinue) {
                    Text("Get started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
        }
    }
}

private struct OnboardingFeature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(BountyTheme.accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    OnboardingView(onContinue: {})
}
