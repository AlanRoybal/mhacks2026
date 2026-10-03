import SwiftUI

struct RootTabView: View {
    @State private var selection = AppTab.home
    @StateObject private var postedJobs = PostedJobsStore()

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(AppTab.home)

            NavigationStack {
                JobsView()
            }
            .tabItem {
                Label("Jobs", systemImage: "briefcase.fill")
            }
            .tag(AppTab.jobs)

            NavigationStack {
                CreateJobView()
            }
            .tabItem {
                Label("Post", systemImage: "plus.circle.fill")
            }
            .tag(AppTab.post)

            NavigationStack {
                TwinView()
            }
            .tabItem {
                Label("Twin", systemImage: "person.crop.circle.fill")
            }
            .tag(AppTab.twin)

            NavigationStack {
                EarningsView()
            }
            .tabItem {
                Label("Earnings", systemImage: "dollarsign.circle.fill")
            }
            .tag(AppTab.earnings)
        }
        .tint(BountyTheme.accent)
        .environmentObject(postedJobs)
        .task { await postedJobs.refresh() }
        .onAppear(perform:consumePendingPushRoute)
        .onReceive(NotificationCenter.default.publisher(for: .pushRouteChanged)) { _ in
            consumePendingPushRoute()
        }
    }

    private func consumePendingPushRoute() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: PushRoute.destinationKey) == "jobs" else { return }
        selection = .jobs
        defaults.removeObject(forKey: PushRoute.destinationKey)
    }
}

private enum AppTab: Hashable {
    case home
    case jobs
    case post
    case twin
    case earnings
}

#Preview {
    RootTabView()
}
