import SwiftUI

// Bounty logo (Figma "05 Brand — logo & launch"). Two stacked bowls form a B: lavender top bowl = twin,
// yellow bottom bowl = bounty, sparkle = AI match. Never recolor the bowls, add outlines, or put the mark
// on brand yellow. Minimum size: mark 20 pt, lockup 88 pt wide.

/// The three mark layers, positioned in Figma's 120 × 120 frame. Exposed so the launch animation can
/// move each layer on its own.
enum BountyMarkLayer: CaseIterable {
    case topBowl, bottomBowl, sparkle

    /// Layer frame in the 120 pt master (Logo/Mark, node 56:3866).
    var frame: CGRect {
        switch self {
        case .topBowl: CGRect(x: 19.2, y: 19.2, width: 57.6, height: 43.2)
        case .bottomBowl: CGRect(x: 19.2, y: 58.8, width: 66, height: 50.4)
        case .sparkle: CGRect(x: 74.4, y: 10.8, width: 26.4, height: 26.4)
        }
    }

    var assetName: String {
        switch self {
        case .topBowl: "LogoTopBowl"
        case .bottomBowl: "LogoBottomBowl"
        case .sparkle: "LogoSparkle"
        }
    }

    static let masterSize: CGFloat = 120
}

/// One mark layer at `size`, placed where it sits in the mark. The bowls keep their brand colors;
/// the sparkle is a template image tinted by `sparkle`.
struct BountyMarkLayerView: View {
    let layer: BountyMarkLayer
    let size: CGFloat
    var sparkle: Color = BountyColor.inkPrimary

    var body: some View {
        let scale = size / BountyMarkLayer.masterSize
        let frame = layer.frame
        Image(layer.assetName)
            .resizable()
            .renderingMode(layer == .sparkle ? .template : .original)
            .foregroundStyle(sparkle)
            .frame(width: frame.width * scale, height: frame.height * scale)
            .position(x: frame.midX * scale, y: frame.midY * scale)
    }
}

/// Logo/Mark. On dark surfaces pass `onDark: true` so the sparkle switches to ink/inverse.
struct BountyMark: View {
    var size: CGFloat = 44
    var onDark = false

    var body: some View {
        ZStack {
            // The bottom bowl is drawn over the top bowl.
            ForEach(BountyMarkLayer.allCases, id: \.self) { layer in
                BountyMarkLayerView(layer: layer, size: size, sparkle: onDark ? BountyColor.inkInverse : BountyColor.inkPrimary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Bounty")
    }
}

/// Logo/Wordmark: lowercase "bounty", SF Pro Rounded Heavy (Nunito ExtraBold in Figma), −2% tracking.
struct BountyWordmark: View {
    var size: CGFloat = 34
    var color: Color = BountyColor.inkPrimary

    var body: some View {
        Text("bounty")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .tracking(-size * 0.02)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// Logo/Lockup: mark + wordmark, 6 pt gap at the 44 pt master. `height` scales all three together;
/// the Welcome header uses 30.
struct BountyLockup: View {
    var height: CGFloat = 44
    var onDark = false

    var body: some View {
        let scale = height / 44
        HStack(spacing: 6 * scale) {
            BountyMark(size: height, onDark: onDark)
            BountyWordmark(size: 34 * scale, color: onDark ? BountyColor.inkInverse : BountyColor.inkPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bounty")
    }
}

#Preview("Logo") {
    VStack(spacing: 32) {
        BountyMark(size: 120)
        BountyLockup()
        BountyLockup(height: 30)
        BountyLockup(onDark: true)
            .padding()
            .background(BountyColor.night)
    }
}
