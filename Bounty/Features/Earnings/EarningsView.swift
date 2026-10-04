import SwiftUI

/// 17 Earnings.
struct EarningsView: View {
    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowYellow, height: 360), spacing: 8) {
            ScreenTitle(title: "Earnings", type: .title) {
                IconButton(icon: .userRound, label: "Account") {}
            }
            .entrance(.top)

            StackCard(tone: .yellow, height: 156, bandTop: 116) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This week")
                        .bountyType(.subheadStrong)
                    Text("$124.00")
                        .bountyType(.moneyL)
                    Text("USD $99 · USDC $25")
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkPill)
                    Chip(label: "+$60 since Monday", tone: .dark)
                        .padding(.top, 6)
                }
                .foregroundStyle(BountyColor.inkPrimary)
                .padding(.leading, 20)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    StickerView(sticker: .coins, size: 96)
                        .padding(.top, 12)
                        .padding(.trailing, 15)
                }
            }
            .entrance(.top)

            HStack(spacing: 10) {
                BalanceTile(label: "In escrow", amount: "$50", background: BountyColor.grey, foreground: BountyColor.navy)
                BalanceTile(label: "Releasing", amount: "$15", background: BountyColor.cream, foreground: BountyColor.creamInk)
                BalanceTile(label: "Paid out", amount: "$74", background: BountyColor.mint, foreground: BountyColor.mintInk)
            }
            .entrance(.top)

            SectionHeader(title: "Activity", trailing: "Bank ••4821")
                .entrance(.rest(0))

            VStack(spacing: 0) {
                ActivityRow(sticker: .poster, tile: BountyColor.lavender, title: "Event poster concepts", detail: "Stripe · paid out Oct 1", amount: "+$60.00", settled: true)
                ActivityRow(sticker: .book, tile: BountyColor.sky, title: "Calculus worksheet", detail: "USDC · Base Sepolia · 0x8f3…a21", amount: "+$25.00", settled: true)
                ActivityRow(sticker: .coffee, tile: BountyColor.cream, title: "Coffee shop logo", detail: "Stripe · releases in 1h 58m", amount: "$15.00", settled: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .borderedCard()
            .entrance(.rest(1))
        }
    }
}

private struct BalanceTile: View {
    let label: String
    let amount: String
    let background: Color
    let foreground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).bountyType(.footnote)
            Text(amount).bountyType(.moneyM)
        }
        .foregroundStyle(foreground)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tintedPanel(background, radius: BountyRadius.row)
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityRow: View {
    let sticker: Sticker
    let tile: Color
    let title: String
    let detail: String
    let amount: String
    let settled: Bool

    var body: some View {
        HStack(spacing: 12) {
            StickerTile(sticker: sticker, background: tile, size: 44, stickerSize: 34, radius: 13)
            TitleSubtitle(title: title, subtitle: detail, titleType: .subheadStrong, subtitleType: .footnote)
            Text(amount)
                .bountyType(.subheadStrong)
                .foregroundStyle(settled ? BountyColor.greenInk : BountyColor.inkSecondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    EarningsView()
}
