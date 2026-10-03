import Foundation

/// Static sample jobs for the worker screens and previews, until they read from the backend.
enum SampleJobs {
    private static func hoursFromNow(_ hours: Double) -> Date {
        .now.addingTimeInterval(hours * 3600)
    }

    static let offer = Job(
        id: "sample_offer",
        title: "Sketch a coffee shop logo",
        category: .design,
        location: JobLocation(latitude: 42.2808, longitude: -83.7430, address: "State St, Ann Arbor, MI"),
        deadline: hoursFromNow(3),
        payAmount: 15,
        status: .offered,
        matchReason: "Your illustration and brand design skills match this job.",
        distanceMiles: 0.4
    )

    static let jobs: [Job] = [
        offer,
        Job(
            id: "sample_desk",
            title: "Photograph a vintage desk",
            category: .photos,
            location: JobLocation(latitude: 42.2770, longitude: -83.7382, address: "S Main St, Ann Arbor, MI"),
            deadline: hoursFromNow(22),
            payAmount: 28,
            status: .accepted,
            matchReason: "You have product photography experience.",
            distanceMiles: 1.2
        ),
        Job(
            id: "sample_calc",
            title: "Review a calculus worksheet",
            category: .tutoring,
            deadline: hoursFromNow(52),
            payAmount: 35,
            status: .inReview,
            matchReason: "Your tutoring history includes calculus."
        ),
        Job(
            id: "sample_poster",
            title: "Create event poster concepts",
            category: .design,
            deadline: hoursFromNow(-24),
            payAmount: 60,
            status: .released,
            matchReason: "Your graphic design experience matched the brief."
        ),
    ]
}
