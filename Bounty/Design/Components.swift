import SwiftUI

// MARK: - Pill button

enum PillStyle {
    case primary
    case secondary
    case dark
    case outline

    fileprivate func background(pressed: Bool) -> Color {
        switch (self, pressed) {
        case (.primary, false): BountyColor.yellow
        case (.primary, true): BountyColor.yellowDeep
        case (.secondary, false): BountyColor.pill
        case (.secondary, true): BountyColor.pillHover
        case (.dark, false): BountyColor.inkPrimary
        case (.dark, true): BountyColor.inkPill
        case (.outline, false): BountyColor.canvas
        case (.outline, true): BountyColor.pill
        }
    }

    fileprivate var foreground: Color {
        switch self {
        case .primary, .outline: BountyColor.inkPrimary
        case .secondary: BountyColor.inkPill
        case .dark: BountyColor.inkInverse
        }
    }
}

/// Capsule button. Darkens over 120 ms and scales to 0.97 while pressed.
struct PillButtonStyle: ButtonStyle {
    let style: PillStyle

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .bountyType(.bodyStrong)
            .foregroundStyle(style.foreground)
            .lineLimit(1)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
            .background(style.background(pressed: pressed), in: Capsule())
            .overlay {
                if style == .outline {
                    Capsule().strokeBorder(BountyColor.inkPrimary, lineWidth: 1.5)
                }
            }
            .animation(Motion.pressTint, value: pressed)
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(Motion.press, value: pressed)
    }
}

/// Scales a tappable surface to 0.97 while pressed, like the pill buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct PillButton: View {
    let title: String
    var icon: BountyIcon?
    var style: PillStyle = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    icon.image
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                Text(title)
            }
        }
        .buttonStyle(PillButtonStyle(style: style))
    }
}

// MARK: - Icons

/// Lucide icons from the Figma file, mapped to the nearest SF Symbol.
enum BountyIcon {
    case apple, bell, briefcase, calendar, camera, check, chevronLeft, clock, ellipsis, flag
    case hourglass, house, images, linkedin, locate, lock, mail, mapPin, navigation, pencil, plus
    case refresh, scanFace, shieldCheck, sliders, sparkles, timer, userRound, wallet, x, zap

    var image: Image {
        switch self {
        case .linkedin: Image("icon-linkedin").renderingMode(.template).resizable()
        default: Image(systemName: symbolName)
        }
    }

    private var symbolName: String {
        switch self {
        case .apple: "apple.logo"
        case .bell: "bell"
        case .briefcase: "briefcase"
        case .calendar: "calendar"
        case .camera: "camera"
        case .check: "checkmark"
        case .chevronLeft: "chevron.left"
        case .clock: "clock"
        case .ellipsis: "ellipsis"
        case .flag: "flag"
        case .hourglass: "hourglass"
        case .house: "house"
        case .images: "photo.on.rectangle"
        case .linkedin: ""
        case .locate: "scope"
        case .lock: "lock"
        case .mail: "envelope"
        case .mapPin: "mappin"
        case .navigation: "location"
        case .pencil: "pencil"
        case .plus: "plus"
        case .refresh: "arrow.triangle.2.circlepath"
        case .scanFace: "faceid"
        case .shieldCheck: "checkmark.shield"
        case .sliders: "slider.horizontal.3"
        case .sparkles: "sparkles"
        case .timer: "timer"
        case .userRound: "person"
        case .wallet: "wallet.bifold"
        case .x: "xmark"
        case .zap: "bolt"
        }
    }
}

struct IconGlyph: View {
    let icon: BountyIcon
    var size: CGFloat = 22
    var weight: Font.Weight = .medium

    var body: some View {
        icon.image
            .font(.system(size: size * 0.8, weight: weight))
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Round 44 pt icon button used in navigation rows.
struct IconButton: View {
    let icon: BountyIcon
    var label: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 22
    var background: Color = BountyColor.pill
    var foreground: Color = BountyColor.inkPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconGlyph(icon: icon, size: iconSize)
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Chip

enum ChipTone {
    case lavender, cream, mint, sky, grey, yellow, dark, coral

    var background: Color {
        switch self {
        case .lavender: BountyColor.lavenderSoft
        case .cream: BountyColor.creamBand
        case .mint: BountyColor.mint
        case .sky: BountyColor.sky
        case .grey: BountyColor.pill
        case .yellow: BountyColor.yellow
        case .dark: BountyColor.navy
        case .coral: BountyColor.coral
        }
    }

    var foreground: Color {
        switch self {
        case .lavender: BountyColor.lavenderInk
        case .cream: BountyColor.creamInk
        case .mint: BountyColor.mintInk
        case .sky: BountyColor.skyInk
        case .grey: BountyColor.inkPill
        case .yellow: BountyColor.inkPrimary
        case .dark, .coral: BountyColor.inkInverse
        }
    }
}

/// Status / meta chip. Lavender = twin, Cream = jobs & proof, Mint = verified/paid,
/// Grey = pending, Yellow = action, Coral = urgent.
struct Chip: View {
    let label: String
    var tone: ChipTone = .lavender

    var body: some View {
        Text(label)
            .bountyType(.footnote)
            .foregroundStyle(tone.foreground)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(tone.background, in: Capsule())
    }
}

/// A chip that can be toggled on (yellow) and off (grey).
struct ChoiceChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Chip(label: label, tone: isSelected ? .yellow : .grey)
                .animation(Motion.pressTint, value: isSelected)
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Stickers

/// Flat, white-outlined sticker art.
enum Sticker: String {
    case twin, calendar, mail, shield, coins, camera, check, coffee, mower, book, poster, phone

    /// The exported art includes its drop shadow, so it overflows the nominal square
    /// to the right and bottom by these factors.
    fileprivate var overflow: CGSize {
        switch self {
        case .twin: CGSize(width: 1.045, height: 1.015)
        case .shield: CGSize(width: 1, height: 1.055)
        case .coins: CGSize(width: 1, height: 1.005)
        case .check: CGSize(width: 1, height: 1.015)
        case .coffee: CGSize(width: 1.0071, height: 1.035)
        case .mower: CGSize(width: 1.025, height: 1.015)
        case .poster: CGSize(width: 1, height: 1.035)
        case .phone: CGSize(width: 1, height: 1.045)
        case .calendar, .mail, .camera, .book: CGSize(width: 1, height: 1)
        }
    }
}

struct StickerView: View {
    let sticker: Sticker
    let size: CGFloat

    var body: some View {
        Image("sticker-\(sticker.rawValue)")
            .resizable()
            .frame(width: size * sticker.overflow.width, height: size * sticker.overflow.height)
            .frame(width: size, height: size, alignment: .topLeading)
            .accessibilityHidden(true)
    }
}

/// A rounded square tile holding a sticker.
struct StickerTile: View {
    let sticker: Sticker
    let background: Color
    var size: CGFloat = 52
    var stickerSize: CGFloat = 42
    var radius: CGFloat = 16

    var body: some View {
        StickerView(sticker: sticker, size: stickerSize)
            .frame(width: size, height: size)
            .background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Stack card

struct StackTone {
    let front: Color
    let back: Color
    let band: Color

    static let lavender = StackTone(front: BountyColor.lavender, back: BountyColor.lavenderBack, band: BountyColor.lavenderBand)
    static let cream = StackTone(front: BountyColor.cream, back: BountyColor.creamBack, band: BountyColor.creamBand)
    static let mint = StackTone(front: BountyColor.mint, back: BountyColor.mintBack, band: BountyColor.mintBand)
    static let grey = StackTone(front: BountyColor.grey, back: BountyColor.greyBack, band: BountyColor.greyBand)
    static let yellow = StackTone(front: BountyColor.yellow, back: BountyColor.creamBack, band: BountyColor.yellowDeep)
}

/// A card with a smaller card peeking out underneath and a curved band across its lower part.
struct StackCard<Content: View>: View {
    let tone: StackTone
    let height: CGFloat
    /// Distance from the top of the card to the top of the band.
    let bandTop: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BountyRadius.stackCard, style: .continuous)
        content
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(alignment: .top) {
                Ellipse()
                    .fill(tone.band)
                    .frame(width: 847.2, height: height * 1.3)
                    .offset(y: bandTop)
            }
            .background(tone.front)
            .clipShape(shape)
            .background(alignment: .top) {
                shape
                    .fill(tone.back)
                    .padding(.horizontal, 12)
                    .offset(y: 12)
            }
            .padding(.bottom, 12)
    }
}

// MARK: - Cards and rows

extension View {
    /// White card with a hairline border.
    func borderedCard(radius: CGFloat = BountyRadius.card, fill: Color = BountyColor.canvas) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(BountyColor.divider, lineWidth: 1)
            }
    }

    /// Solid tinted panel without a border.
    func tintedPanel(_ fill: Color, radius: CGFloat = BountyRadius.card) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct TitleSubtitle: View {
    let title: String
    let subtitle: String
    var titleType: BountyType = .bodyStrong
    var subtitleType: BountyType = .subhead
    var spacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title)
                .bountyType(titleType)
                .foregroundStyle(BountyColor.inkPrimary)
            Text(subtitle)
                .bountyType(subtitleType)
                .foregroundStyle(BountyColor.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A header row with a title on the left and a trailing label or action.
struct SectionHeader: View {
    let title: String
    var trailing: String?
    var trailingColor: Color = BountyColor.inkSecondary
    var trailingType: BountyType = .subheadStrong
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .bountyType(.headline)
                .foregroundStyle(BountyColor.inkPrimary)
            Spacer()
            if let trailing {
                if let action {
                    Button(trailing, action: action)
                        .bountyType(trailingType)
                        .foregroundStyle(trailingColor)
                } else {
                    Text(trailing)
                        .bountyType(trailingType)
                        .foregroundStyle(trailingColor)
                }
            }
        }
    }
}

/// Large screen title with an optional trailing accessory.
struct ScreenTitle<Trailing: View>: View {
    let title: String
    var type: BountyType = .display
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .bountyType(type)
                .foregroundStyle(BountyColor.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension ScreenTitle where Trailing == EmptyView {
    init(_ title: String, type: BountyType = .display) {
        self.title = title
        self.type = type
        self.trailing = EmptyView()
    }
}

/// Back / close button, a centered accessory and a trailing accessory.
struct NavRow<Center: View, Trailing: View>: View {
    var leadingIcon: BountyIcon = .chevronLeft
    var leadingLabel = "Back"
    var leadingBackground: Color = BountyColor.pill
    var leadingForeground: Color = BountyColor.inkPrimary
    let leadingAction: () -> Void
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            center
            HStack {
                IconButton(
                    icon: leadingIcon,
                    label: leadingLabel,
                    background: leadingBackground,
                    foreground: leadingForeground,
                    action: leadingAction
                )
                Spacer()
                trailing
            }
        }
        .frame(height: 44)
    }
}

// MARK: - Meter

/// Progress, confidence and review-window bars. Grows from 0 as the screen settles.
struct Meter: View {
    let value: Double
    var fill: Color = BountyColor.lavender
    var track: Color = BountyColor.pill
    var height: CGFloat = 8

    @State private var shown = false

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(track)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(fill)
                        .frame(width: proxy.size.width * (shown ? min(max(value, 0), 1) : 0))
                }
        }
        .frame(height: height)
        .onAppear {
            withAnimation(Motion.meterFill) { shown = true }
        }
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

// MARK: - Status badge

enum StepStatus {
    case done, active, todo
}

/// 28 pt round status marker used in checklists.
struct StatusBadge: View {
    let status: StepStatus

    var body: some View {
        Group {
            switch status {
            case .done:
                IconGlyph(icon: .check, size: 16, weight: .bold)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .frame(width: 28, height: 28)
                    .background(BountyColor.green, in: Circle())
            case .active:
                IconGlyph(icon: .refresh, size: 16, weight: .semibold)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .frame(width: 28, height: 28)
                    .background(BountyColor.yellow, in: Circle())
            case .todo:
                IconGlyph(icon: .clock, size: 16)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .frame(width: 28, height: 28)
                    .background(BountyColor.pill, in: Circle())
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

// MARK: - Progress dots

/// Step indicator: green dots for done steps, a yellow capsule for the current one.
struct ProgressDots: View {
    let total: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(width: index == current ? 36 : 12, height: 12)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(total)")
    }

    private func color(for index: Int) -> Color {
        if index < current { return BountyColor.green }
        if index == current { return BountyColor.yellow }
        return BountyColor.pill
    }
}

// MARK: - Segmented control

struct SegmentedPill<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(Motion.press) { selection = option.value }
                } label: {
                    Text(option.label)
                        .bountyType(.subheadStrong)
                        .foregroundStyle(selected ? BountyColor.inkPrimary : BountyColor.inkSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(BountyColor.canvas)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(BountyColor.pill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Slider

/// Yellow-filled slider with the white knob from the design.
struct BountySlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var label: String

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let knobX = (width - 24) * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(BountyColor.pill).frame(height: 6)
                Capsule().fill(BountyColor.yellow).frame(width: knobX + 12, height: 6)
                Image("slider-knob")
                    .resizable()
                    .frame(width: 36, height: 36)
                    .offset(x: knobX - 6, y: 2)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let raw = (drag.location.x - 12) / max(width - 24, 1)
                    let clamped = min(max(raw, 0), 1)
                    let span = range.upperBound - range.lowerBound
                    let stepped = range.lowerBound + (clamped * span / step).rounded() * step
                    value = min(max(stepped, range.lowerBound), range.upperBound)
                }
            )
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text(value, format: .number))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

// MARK: - Field

struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .bountyType(.footnote)
            .foregroundStyle(BountyColor.inkSecondary)
    }
}

extension View {
    func fieldBackground(height: CGFloat? = 48) -> some View {
        padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(BountyColor.field, in: RoundedRectangle(cornerRadius: BountyRadius.field, style: .continuous))
    }
}

// MARK: - Avatar

struct InitialsAvatar: View {
    let initials: String
    var background: Color = BountyColor.lavender
    var foreground: Color = BountyColor.inkInverse
    var size: CGFloat = 44

    var body: some View {
        Text(initials)
            .bountyType(.subheadStrong)
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background, in: Circle())
            .accessibilityHidden(true)
    }
}
