import SwiftUI

// Color tokens from the "00 Foundations — Design DNA" page in Figma.
enum BountyColor {
    static let inkPrimary = Color(hex: 0x000000)
    static let inkSecondary = Color(hex: 0x6B6B6B)
    static let inkTertiary = Color(hex: 0x9A9A9A)
    static let inkPill = Color(hex: 0x454545)
    static let inkInverse = Color(hex: 0xFFFFFF)

    static let canvas = Color(hex: 0xFFFFFF)
    static let pill = Color(hex: 0xEEEEEE)
    static let pillHover = Color(hex: 0xE3E3E3)
    static let field = Color(hex: 0xF6F6F7)
    static let divider = Color(hex: 0xEBEBEB)
    static let night = Color(hex: 0x111114)

    static let yellow = Color(hex: 0xFDB517)
    static let yellowDeep = Color(hex: 0xE8A30E)
    static let green = Color(hex: 0x78F00D)
    static let greenInk = Color(hex: 0x2F7A00)
    static let coral = Color(hex: 0xFF5A1F)
    static let red = Color(hex: 0xE5484D)

    static let lavender = Color(hex: 0x8784FF)
    static let lavenderBand = Color(hex: 0x7B78F2)
    static let lavenderBack = Color(hex: 0x6F6AE6)
    static let lavenderSoft = Color(hex: 0xEEEAFE)
    static let lavenderInk = Color(hex: 0x2B2380)

    static let cream = Color(hex: 0xFDF4E3)
    static let creamBand = Color(hex: 0xFAE3A8)
    static let creamBack = Color(hex: 0xF3D58A)
    static let creamInk = Color(hex: 0x4F3A08)

    static let mint = Color(hex: 0xE3F8D2)
    static let mintBand = Color(hex: 0xCDF0B0)
    static let mintBack = Color(hex: 0xB9E796)
    static let mintInk = Color(hex: 0x1F5200)

    static let sky = Color(hex: 0xDCE7FF)
    static let skyBand = Color(hex: 0xC8D9FF)
    static let skyBack = Color(hex: 0xB4C9F7)
    static let skyInk = Color(hex: 0x0B2A6B)

    static let grey = Color(hex: 0xE4E4E4)
    static let greyBand = Color(hex: 0xD8D8D8)
    static let greyBack = Color(hex: 0xC9C9C9)
    static let navy = Color(hex: 0x000B3F)

    // Background glows used at the top of screens.
    static let glowLavender = Color(hex: 0xE9E5FF)
    static let glowYellow = Color(hex: 0xFFF1CC)
    static let glowCream = Color(hex: 0xFDF4E3)
    static let glowMint = Color(hex: 0xE3F8D2)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// Type scale. Figma uses Inter and Nunito; SwiftUI uses SF Pro and SF Pro Rounded.
enum BountyType {
    case display
    case title
    case headline
    case body
    case bodyStrong
    case subhead
    case subheadStrong
    case footnote
    case caption
    case moneyXL
    case moneyL
    case moneyM
    case money(size: CGFloat, lineHeight: CGFloat)

    fileprivate var spec: (size: CGFloat, weight: Font.Weight, design: Font.Design, lineHeight: CGFloat, tracking: CGFloat) {
        switch self {
        case .display: (40, .bold, .default, 44, -0.4)
        case .title: (28, .bold, .default, 34, -0.14)
        case .headline: (20, .semibold, .default, 25, 0)
        case .body: (17, .regular, .default, 22, 0)
        case .bodyStrong: (17, .semibold, .default, 22, 0)
        case .subhead: (15, .regular, .default, 20, 0)
        case .subheadStrong: (15, .semibold, .default, 20, 0)
        case .footnote: (13, .medium, .default, 18, 0)
        case .caption: (11, .semibold, .default, 14, 0.44)
        case .moneyXL: (72, .heavy, .rounded, 76, -0.72)
        case .moneyL: (44, .heavy, .rounded, 48, -0.44)
        case .moneyM: (22, .heavy, .rounded, 28, 0)
        case let .money(size, lineHeight): (size, .heavy, .rounded, lineHeight, -size / 100)
        }
    }

    var font: Font {
        let spec = spec
        return .system(size: spec.size, weight: spec.weight, design: spec.design)
    }
}

extension View {
    /// Applies a Bounty text style: font, tracking and the Figma line height.
    func bountyType(_ type: BountyType) -> some View {
        let spec = type.spec
        // SF Pro's natural line height is roughly 1.19× its point size.
        let extraLeading = max(0, spec.lineHeight - spec.size * 1.19)
        return font(type.font)
            .tracking(spec.tracking)
            .lineSpacing(extraLeading)
    }
}

enum BountyRadius {
    static let card: CGFloat = 24
    static let stackCard: CGFloat = 28
    static let row: CGFloat = 20
    static let field: CGFloat = 16
}
