import SwiftUI
import TwinKit
import UIKit

/// `GET /me`: identity, payout status and the reliability stats (US-58).
struct MeProfile: Decodable, Sendable {
    let userId: String
    let displayName: String
    let email: String?
    let payouts: Payouts
    let pushEnabled: Bool
    let stats: Stats

    struct Payouts: Decodable, Sendable {
        let stripeConnected: Bool
        let stripeTransfersEnabled: Bool
    }

    struct Stats: Decodable, Sendable {
        let offersReceived: Int
        let jobsCompleted: Int
        /// 0–1, or nil before the first offer.
        let acceptRate: Double?
        let completionRate: Double?
        /// 0–1. Starts at 1 and drops with expired offers, withdrawals and failed jobs.
        let reliability: Double
        let workerRating: Double?
        let posterRating: Double?
    }
}

/// 27 Account and settings: identity, stats, notifications, calendar, work preferences, payouts,
/// account deletion and sign-out. Opened from the profile icon on Twin and Earnings.
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var me: MeProfile?
    @State private var name = ""
    @State private var message: String?
    @State private var isWorking = false
    @State private var showsPreferences = false
    @State private var confirmsDelete = false
    @State private var isSyncingCalendar = false
    @State private var calendarNote: String?
    @State private var calendarAccessOff = false
    @State private var showsCalendarLink = false
    @State private var confirmsUnlink = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                        .onSubmit { Task { await saveName() } }
                        .submitLabel(.done)
                    if let email = me?.email { LabeledContent("Email", value: email) }
                }

                if let stats = me?.stats {
                    Section {
                        LabeledContent("Reliability", value: stats.reliability.formatted(.percent.precision(.fractionLength(0))))
                        LabeledContent("Acceptance rate", value: stats.acceptRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "No offers yet")
                        LabeledContent("Completion rate", value: stats.completionRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "No jobs yet")
                        LabeledContent("Jobs completed", value: "\(stats.jobsCompleted)")
                        if let rating = stats.workerRating { LabeledContent("Rating as a worker", value: "★ \(rating.formatted())") }
                        if let rating = stats.posterRating { LabeledContent("Rating as a poster", value: "★ \(rating.formatted())") }
                    } header: {
                        Text("Your stats")
                    } footer: {
                        Text("Expired offers, withdrawals and failed jobs lower reliability, which affects matching.")
                    }
                }

                Section {
                    Button("Work preferences and availability") { showsPreferences = true }
                    LabeledContent("Calendar", value: calendarStatus)
                    if services.isCalendarLinked {
                        Button {
                            Task { await syncCalendar() }
                        } label: {
                            HStack {
                                Text(isSyncingCalendar ? "Syncing calendar\u{2026}" : "Sync calendar now")
                                if isSyncingCalendar {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isSyncingCalendar)
                        Button("Change linked calendars") { showsCalendarLink = true }
                        Button("Unlink calendar", role: .destructive) { confirmsUnlink = true }
                    } else {
                        Button("Link calendar") { showsCalendarLink = true }
                            .disabled(services.availability == nil)
                    }
                    if calendarAccessOff {
                        Button("Turn on calendar access in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } header: {
                    Text("Work")
                } footer: {
                    Text(calendarNote ?? "Only the start and end of busy times leave your phone, never event names.")
                }

                Section {
                    LabeledContent("Offer notifications", value: me?.pushEnabled == true ? "On" : "Off")
                    Button("Notification settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    LabeledContent("Stripe payouts", value: me?.payouts.stripeTransfersEnabled == true ? "Ready" : me?.payouts.stripeConnected == true ? "Setup unfinished" : "Not set up")
                } header: {
                    Text("Notifications and payouts")
                } footer: {
                    Text("Manage payouts from the Earnings tab.")
                }

                Section {
                    Button("Sign out") { Task { await signOut() } }
                    Button("Delete account", role: .destructive) { confirmsDelete = true }
                } footer: {
                    Text("Deleting removes your name, email, twin and preferences. Records of past jobs stay for the other party and for payment history. You can\u{2019}t delete while a job is still open.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .disabled(isWorking)
            .task { await load() }
            .confirmationDialog("Delete your account?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) { Task { await deleteAccount() } }
            } message: {
                Text("This can\u{2019}t be undone.")
            }
            .sheet(isPresented: $showsCalendarLink) {
                CalendarLinkSheet { outcome in calendarNote = Self.note(for: outcome) }
            }
            .confirmationDialog("Unlink your calendar?", isPresented: $confirmsUnlink, titleVisibility: .visible) {
                Button("Unlink calendar", role: .destructive) {
                    Task {
                        await services.unlinkCalendar()
                        calendarNote = "Calendar unlinked. Your twin now goes by the free times in Work preferences."
                    }
                }
            } message: {
                Text("Bounty stops reading your calendar and removes the busy times it sent.")
            }
            .fullScreenCover(isPresented: $showsPreferences) {
                WorkPreferencesView(inSettings: true, onBack: { showsPreferences = false }, onContinue: { showsPreferences = false })
            }
        }
    }

    private func load() async {
        guard let api = services.api else {
            message = "Not connected to the Bounty server."
            return
        }
        do {
            let profile: MeProfile = try await api.request(.get, "me")
            me = profile
            name = profile.displayName
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveName() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = services.api, !trimmed.isEmpty, trimmed != me?.displayName else { return }
        do {
            me = try await api.request(.patch, "me", body: ["displayName": trimmed])
        } catch {
            message = error.localizedDescription
        }
    }

    private var calendarStatus: String {
        if let status = services.availability?.authorizationStatus, [.denied, .restricted].contains(status) { return "Access off" }
        let linked = services.linkedCalendars
        guard !linked.isEmpty else { return "Not linked" }
        let what = linked.count == 1 ? linked[0].title : "\(linked.count) calendars"
        guard let date = services.calendarSyncedAt else { return what }
        return "\(what) \u{00B7} \(date.formatted(.relative(presentation: .named)))"
    }

    private func syncCalendar() async {
        isSyncingCalendar = true
        defer { isSyncingCalendar = false }
        let outcome = await services.syncCalendar()
        calendarAccessOff = outcome == .accessDenied
        if outcome == .notLinked { showsCalendarLink = true }
        calendarNote = Self.note(for: outcome)
    }

    private static func note(for outcome: AppServices.CalendarSyncOutcome) -> String? {
        switch outcome {
        case .synced(let busy):
            busy == 0
                ? "Calendar synced. Nothing is booked in the next two weeks."
                : "Calendar synced. \(busy) busy \(busy == 1 ? "time" : "times") in the next two weeks. Your twin won\u{2019}t offer jobs then."
        case .accessDenied:
            "Bounty can\u{2019}t read your calendar. Turn on access in Settings \u{203A} Privacy & Security \u{203A} Calendars."
        case .notLinked: nil
        case .failed(let error): "Couldn\u{2019}t sync: \(error)"
        }
    }

    private func signOut() async {
        try? await services.session.signOut()
        services.forgetCalendarSync()
        dismiss()
        hasCompletedOnboarding = false
    }

    private func deleteAccount() async {
        guard let api = services.api else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.send(.delete, "me")
            await signOut()
        } catch {
            message = error.localizedDescription
        }
    }
}
