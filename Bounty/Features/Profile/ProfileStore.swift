import Foundation
import Observation
import ImageIO
import UIKit

struct UserProfile: Codable, Equatable {
    var name = "Alan Roybal"
    var email = ""
    var phone = ""
    var location = ""
    var bio = ""
    var avatarData: Data?

    var firstName: String {
        name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "You"
    }

    var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = [words.first, words.count > 1 ? words.last : nil]
            .compactMap { $0?.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    var trimmed: UserProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    var validationMessage: String? {
        let profile = trimmed
        if profile.name.isEmpty { return "Enter your name to save your profile." }
        if profile.name.count > 60 { return "Keep your name to 60 characters or fewer." }
        if !profile.email.isEmpty,
           profile.email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
            return "Enter a valid email address, or leave it blank."
        }
        return nil
    }
}

enum AvatarPhoto {
    /// Downsample before decoding so full-resolution library images aren't kept in memory.
    nonisolated static func prepare(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85)
    }
}

@MainActor
@Observable
final class ProfileStore {
    private(set) var profile: UserProfile
    private let defaults: UserDefaults
    private static let storageKey = "bounty.userProfile"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profile = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) } ?? UserProfile()
    }

    func save(_ updated: UserProfile) throws {
        let updated = updated.trimmed
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: Self.storageKey)
        profile = updated
    }
}
