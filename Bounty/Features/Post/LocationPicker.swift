import CoreLocation
import MapKit
import SwiftUI

/// A sheet for choosing where the job happens: the poster's current spot or an address search.
struct LocationPicker: View {
    @Binding var location: JobLocation?
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [JobLocation] = []
    @State private var isSearching = false
    @State private var isLocating = false
    @State private var errorMessage: String?
    @State private var locationManager = CLLocationManager()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        HStack {
                            Label("Use my current location", systemImage: "location.fill")
                            Spacer()
                            if isLocating { ProgressView() }
                        }
                    }
                    .disabled(isLocating)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.secondary)
                    }
                }

                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results, id: \.self) { result in
                            Button {
                                choose(result)
                            } label: {
                                Text(result.address)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if isSearching { ProgressView() }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search an address or place")
            .onSubmit(of: .search) {
                Task { await search() }
            }
            .navigationTitle("Job location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func choose(_ result: JobLocation) {
        location = result
        dismiss()
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await LocationLookup.search(trimmed)
            errorMessage = results.isEmpty ? "No places found. Try a fuller address." : nil
        } catch {
            results = []
            errorMessage = "Search didn't work. Check your connection and try again."
        }
    }

    private func useCurrentLocation() async {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        isLocating = true
        defer { isLocating = false }
        do {
            choose(try await LocationLookup.current())
        } catch {
            errorMessage = "Couldn't get your location. Allow location access in Settings, or search for the address."
        }
    }
}

/// Location lookups that return plain `JobLocation` values, so no MapKit or CoreLocation
/// objects cross between threads. Runs on the main actor because some MapKit types are
/// main-actor only; the searches themselves are async and don't block the UI.
@MainActor
enum LocationLookup {
    enum LookupError: Error {
        case unavailable
    }

    /// A location fix as plain numbers, so it can safely leave the task that produced it.
    private struct Fix: Sendable {
        let latitude: Double
        let longitude: Double
    }

    static func search(_ query: String) async throws -> [JobLocation] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // Bias results toward Ann Arbor, where the demo's jobs live.
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 42.2808, longitude: -83.7430),
            latitudinalMeters: 30_000,
            longitudinalMeters: 30_000
        )
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(8).map { item -> JobLocation in
            let coordinate = item.placemark.coordinate
            let name = item.name ?? ""
            let address = item.placemark.title ?? ""
            let label = address.hasPrefix(name) || name.isEmpty ? address : "\(name), \(address)"
            return JobLocation(latitude: coordinate.latitude, longitude: coordinate.longitude, address: label)
        }
    }

    /// Waits for the first location fix (up to 10 seconds) and turns it into a street address.
    static func current() async throws -> JobLocation {
        // CLLocation isn't Sendable, so each child task hands back plain numbers instead.
        let fix = try await withThrowingTaskGroup(of: Fix?.self, returning: Fix?.self) { group in
            group.addTask {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let location = update.location {
                        return Fix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let fix else { throw LookupError.unavailable }

        let location = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        let address = [placemark?.subThoroughfare, placemark?.thoroughfare, placemark?.locality]
            .compactMap { $0 }
            .joined(separator: " ")
        return JobLocation(
            latitude: fix.latitude,
            longitude: fix.longitude,
            address: address.isEmpty ? "Current location" : address
        )
    }
}
