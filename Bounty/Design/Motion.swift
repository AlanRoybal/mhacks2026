import SwiftUI

// Motion tokens from the "Motion" frame in Figma.
enum Motion {
    /// Page enter, step 1: the top half rises and fades in.
    static let enterTop = Animation.easeOut(duration: 0.22)
    static let enterTopDuration = Duration.milliseconds(220)
    /// Page enter, step 2: the rest of the page and the buttons.
    static let enterRest = Animation.spring(response: 0.5, dampingFraction: 0.82)
    static let stagger = 0.06
    /// Page exit: content lifts and fades, bottom actions drop.
    static let exit = Animation.easeIn(duration: 0.2)
    static let exitDuration = Duration.milliseconds(200)
    static let tabSwitch = Animation.easeOut(duration: 0.15)
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
    static let pressTint = Animation.easeOut(duration: 0.12)
    static let meterFill = Animation.spring(response: 0.6, dampingFraction: 0.9).delay(0.1)
    static let autoAdvance = Duration.seconds(2.5)
}

/// Where a screen is in its enter / exit choreography.
enum EntrancePhase {
    /// Before anything shows: content sits 36 pt low, fully transparent.
    case hidden
    /// After step 1: content is 12 pt low and the top sections are visible.
    case top
    /// Fully on screen.
    case settled
    /// Leaving: content lifts 24 pt and fades, bottom actions drop 40 pt.
    case exiting

    var contentOffset: CGFloat {
        switch self {
        case .hidden: 36
        case .top: 12
        case .settled: 0
        case .exiting: -24
        }
    }

    var bottomOffset: CGFloat {
        switch self {
        case .hidden: 48
        case .top: 24
        case .settled: 0
        case .exiting: 40
        }
    }

    var glowOpacity: Double {
        switch self {
        case .hidden, .exiting: 0
        case .top: 0.6
        case .settled: 1
        }
    }
}

/// Which step of the page enter a section belongs to.
enum EntranceGroup {
    /// Revealed by step 1.
    case top
    /// Revealed by step 2, staggered by `order` × 60 ms.
    case rest(Int)
}

private struct EntrancePhaseKey: EnvironmentKey {
    static let defaultValue = EntrancePhase.settled
}

private struct ScreenExitingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var entrancePhase: EntrancePhase {
        get { self[EntrancePhaseKey.self] }
        set { self[EntrancePhaseKey.self] = newValue }
    }

    /// Set by a `ScreenTransition` while the current screen plays its exit.
    var screenExiting: Bool {
        get { self[ScreenExitingKey.self] }
        set { self[ScreenExitingKey.self] = newValue }
    }
}

private struct EntranceModifier: ViewModifier {
    @Environment(\.entrancePhase) private var phase
    let group: EntranceGroup

    private var isVisible: Bool {
        switch (group, phase) {
        case (_, .settled), (.top, .top): true
        default: false
        }
    }

    private var animation: Animation {
        switch (group, phase) {
        case (_, .exiting): Motion.exit
        case (.top, _): Motion.enterTop
        case let (.rest(order), _): Motion.enterRest.delay(Double(order) * Motion.stagger)
        }
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .animation(animation, value: isVisible)
    }
}

extension View {
    /// Marks a section of a screen so it fades in with the page enter choreography.
    func entrance(_ group: EntranceGroup) -> some View {
        modifier(EntranceModifier(group: group))
    }
}

/// Plays the current screen's exit, then swaps to the next screen, which runs its own enter.
@MainActor
@Observable
final class ScreenTransition {
    private(set) var isExiting = false

    func perform(_ change: @escaping @MainActor () -> Void) {
        guard !isExiting else { return }
        isExiting = true
        Task { @MainActor in
            try? await Task.sleep(for: Motion.exitDuration)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                change()
                isExiting = false
            }
        }
    }
}

/// Runs the two-step page enter for a screen and reacts to its exit.
private struct EntranceDriver: ViewModifier {
    @Environment(\.screenExiting) private var exiting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var phase: EntrancePhase

    func body(content: Content) -> some View {
        content
            .environment(\.entrancePhase, phase)
            .task {
                guard phase == .hidden else { return }
                if reduceMotion {
                    phase = .settled
                    return
                }
                withAnimation(Motion.enterTop) { phase = .top }
                try? await Task.sleep(for: Motion.enterTopDuration)
                withAnimation(Motion.enterRest) { phase = .settled }
            }
            .onChange(of: exiting) { _, isExiting in
                guard isExiting else { return }
                withAnimation(Motion.exit) { phase = .exiting }
            }
    }
}

extension View {
    func entranceDriver(_ phase: Binding<EntrancePhase>) -> some View {
        modifier(EntranceDriver(phase: phase))
    }
}
