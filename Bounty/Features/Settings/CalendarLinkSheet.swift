import SwiftUI
import TwinKit

/// "Link your calendar": asks for calendar access, lists the phone's calendars by account, and links the
/// ones the user picks. Opened from Settings, Work preferences ("Fill from calendar") and onboarding.
struct CalendarLinkSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Called after a successful link, with the sync result.
    var onLinked: (AppServices.CalendarSyncOutcome) -> Void = { _ in }

    @State private var access: CalendarAccessStatus = .notDetermined
    @State private var calendars: [DeviceCalendar] = []
    @State private var selection: Set<String> = []
    @State private var isLinking = false
    @State private var error: String?

    private var accounts: [(source: String, calendars: [DeviceCalendar])] {
        Dictionary(grouping: calendars, by: \.source)
            .map { ($0.key, $0.value) }
            .sorted { $0.source < $1.source }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your twin won\u{2019}t offer jobs when you\u{2019}re busy. Only the start and end of events leave your phone, never titles, places or people.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                switch access {
                case .fullAccess where calendars.isEmpty:
                    Section {
                        Label("No calendars on this iPhone", icon: .calendar)
                        Text("Add an account in Settings \u{203A} Apps \u{203A} Calendar \u{203A} Calendar Accounts (iCloud, Google, Outlook\u{2026}), then come back.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .fullAccess:
                    ForEach(accounts, id: \.source) { account in
                        Section(account.source) {
                            ForEach(account.calendars) { calendar in
                                CalendarRow(calendar: calendar, isOn: selection.contains(calendar.id)) {
                                    if selection.contains(calendar.id) { selection.remove(calendar.id) } else { selection.insert(calendar.id) }
                                }
                            }
                        }
                    }
                case .notDetermined:
                    Section {
                        Button {
                            Task { await requestAccess() }
                        } label: {
                            Label("Allow calendar access", icon: .calendar)
                        }
                    } footer: {
                        Text("iOS asks once. Then you choose which calendars to link.")
                    }
                case .denied, .restricted, .writeOnly:
                    Section {
                        Label("Calendar access is off", icon: .lock)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    } footer: {
                        Text("Turn on Calendars \u{203A} Full Access for Bounty, then come back to pick your calendars.")
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Link your calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if access == .fullAccess, !calendars.isEmpty {
                    PillButton(title: linkTitle, icon: .calendar) { Task { await link() } }
                        .disabled(selection.isEmpty || isLinking)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.bar)
                }
            }
            .onAppear(perform: reload)
            // Coming back from Settings after turning access on.
            .onChange(of: scenePhase) { _, phase in if phase == .active { reload() } }
        }
    }

    private var linkTitle: String {
        if isLinking { return "Linking\u{2026}" }
        switch selection.count {
        case 0: return "Choose a calendar"
        case 1: return "Link 1 calendar"
        default: return "Link \(selection.count) calendars"
        }
    }

    private func reload() {
        guard let availability = services.availability else { return }
        access = availability.authorizationStatus
        calendars = availability.calendars
        let linked = services.linkedCalendarIDs.intersection(calendars.map(\.id))
        // Changing calendars starts from what's linked; a first link starts with every calendar chosen.
        selection = linked.isEmpty ? Set(calendars.map(\.id)) : linked
    }

    private func requestAccess() async {
        _ = await services.availability?.requestAccess()
        reload()
    }

    private func link() async {
        isLinking = true
        defer { isLinking = false }
        error = nil
        let outcome = await services.linkCalendars(selection)
        switch outcome {
        case .synced:
            onLinked(outcome)
            dismiss()
        case .failed(let message): error = "Couldn\u{2019}t sync: \(message)"
        case .accessDenied: reload()
        case .notLinked: error = "Choose at least one calendar."
        }
    }
}

private struct CalendarRow: View {
    let calendar: DeviceCalendar
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(.sRGB, red: calendar.color[safe: 0], green: calendar.color[safe: 1], blue: calendar.color[safe: 2]))
                    .frame(width: 12, height: 12)
                Text(calendar.title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? BountyColor.lavender : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private extension Array where Element == Double {
    subscript(safe index: Int) -> Double { indices.contains(index) ? self[index] : 0.5 }
}
