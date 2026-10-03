import Foundation

/// Sample jobs for the worker screens and previews, until they read from the backend.
/// Names match the ones Alan's screens use.
enum SampleJobs {
    private static func hoursFromNow(_ hours: Double) -> Date {
        .now.addingTimeInterval(hours * 3600)
    }

    private static let annArbor = JobLocation(latitude: 42.2808, longitude: -83.7430, address: "State St, Ann Arbor, MI")

    static let coffeeLogo = Job(
        id: "coffee-logo",
        title: "Sketch a coffee shop logo",
        category: .design,
        location: annArbor,
        deadline: hoursFromNow(3),
        payAmount: 15,
        status: .offered,
        matchReason: "Your illustration and brand design skills match this job.",
        distanceMiles: 0.4
    )

    static let vintageDesk = Job(
        id: "vintage-desk",
        title: "Photograph a vintage desk",
        category: .photos,
        location: JobLocation(latitude: 42.2770, longitude: -83.7382, address: "S Main St, Ann Arbor, MI"),
        deadline: hoursFromNow(22),
        payAmount: 28,
        status: .accepted,
        matchReason: "You have product photography experience.",
        distanceMiles: 1.2
    )

    static let calculus = Job(
        id: "calculus",
        title: "Review a calculus worksheet",
        category: .tutoring,
        deadline: hoursFromNow(52),
        payAmount: 35,
        status: .inReview,
        matchReason: "Your tutoring history includes calculus."
    )

    static let poster = Job(
        id: "poster",
        title: "Event poster concepts",
        category: .design,
        deadline: hoursFromNow(-24),
        payAmount: 60,
        status: .released,
        matchReason: "Your graphic design experience matched the brief."
    )

    static let working = [coffeeLogo, vintageDesk, calculus, poster]

    /// Kept for previews; the Posted list itself comes from `PosterStore`.
    static let lawn = Job(
        id: "lawn",
        title: "Mow my front lawn",
        category: .yardWork,
        location: JobLocation(latitude: 42.2741, longitude: -83.7365, address: "1200 S University Ave"),
        deadline: hoursFromNow(40),
        payAmount: 40,
        status: .inReview
    )

    static let posted = [lawn]
}
