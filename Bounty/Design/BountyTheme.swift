import SwiftUI

@MainActor
enum BountyTheme {
    static let accent = Color(red: 0.12, green: 0.45, blue: 0.98)
    static let success = Color(red: 0.12, green: 0.65, blue: 0.42)
    static let warning = Color(red: 0.96, green: 0.55, blue: 0.12)
}

struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension View {
    func bountyPanel() -> some View {
        modifier(PanelModifier())
    }
}
