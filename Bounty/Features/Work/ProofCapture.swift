import AVFoundation
import CryptoKit
import Foundation
import UIKit

/// Proof that a photo or video came from the Bounty camera, without marking the work itself.
///
/// When the worker starts, the server gives the job a capture key (`PostedJob.captureKey`). Right after each
/// capture the app signs the file's SHA-256, the capture time and the GPS fix with it. The server hashes the
/// uploaded bytes and checks the signature (`backend/src/services/capture.ts`), so camera-roll photos, edited
/// files and captures from other jobs aren't accepted. The signed message must match the backend byte for
/// byte; `backend/src/domain/domain.test.ts` pins a shared test vector.
enum CaptureSignature {
    struct Signed: Sendable {
        let sha256: String
        let signature: String?
    }

    /// Whole seconds, as the proof is encoded (ISO 8601 without fractions) and as the server signs it.
    static func captureTime(_ date: Date = .now) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static func sign(_ data: Data, jobId: String, capturedAt: Date, latitude: Double?, longitude: Double?, key: String?) -> Signed {
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let key, let secret = base64URLDecoded(key) else { return Signed(sha256: sha256, signature: nil) }
        let message = [
            "bounty-capture-v1",
            jobId,
            sha256,
            String(Int(capturedAt.timeIntervalSince1970.rounded(.down))),
            coordinate(latitude),
            coordinate(longitude),
        ].joined(separator: "\n")
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: secret))
        return Signed(sha256: sha256, signature: Data(mac).base64EncodedString())
    }

    /// Five decimals (about a meter), the same text JavaScript's `toFixed(5)` produces.
    private static func coordinate(_ value: Double?) -> String {
        value.map { String(format: "%.5f", $0) } ?? ""
    }

    private static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

/// Stills from a proof video. The grader reads images, so the app sends a few frames with every clip.
enum VideoFrames {
    static func extract(from url: URL, count: Int = 3) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        guard seconds.isFinite, seconds > 0 else { return [] }
        var frames: [UIImage] = []
        for index in 0..<count {
            // Spread across the clip, skipping the very first and last moments.
            let fraction = (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: seconds * fraction, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) { frames.append(UIImage(cgImage: image)) }
        }
        return frames
    }

    /// The picker deletes its file once it's dismissed, so keep a copy for uploading.
    static func keepCopy(of url: URL) -> URL? {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("proof-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    static func contentType(of url: URL) -> String {
        url.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/quicktime"
    }
}
