import AuthenticationServices
import CryptoKit
import Foundation
import Security
import TwinKit

/// Gmail import (US-9). Runs Google's PKCE flow for an iOS OAuth client (no secret) with the read-only
/// Gmail scope and hands the code to `POST /twin/gmail`. The backend reads recent sent mail once, revokes
/// the token and extracts skills in the background, so the caller polls `GET /twin` like a file import.
@MainActor
final class GmailConnector {
    enum ConnectError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "Gmail connection was cancelled."
            case .failed(let message): message
            }
        }
    }

    private let clientID: String
    private let api: APIClient
    private var webSession: ASWebAuthenticationSession?

    /// `clientID` is `<prefix>.apps.googleusercontent.com`; Google's iOS redirect is its reverse.
    init(clientID: String, api: APIClient) {
        self.clientID = clientID
        self.api = api
    }

    private var callbackScheme: String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    private var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    func connect(presentationContextProvider: any ASWebAuthenticationPresentationContextProviding) async throws {
        let verifier = try Self.randomURLSafe(byteCount: 32)
        let state = try Self.randomURLSafe(byteCount: 24)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/gmail.readonly"),
            URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        let callback = try await authorize(url: components.url!, presentationContextProvider: presentationContextProvider)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if let error = values["error"] {
            throw error == "access_denied" ? ConnectError.cancelled : ConnectError.failed("Google sign-in failed (\(error)).")
        }
        guard values["state"] == state, let code = values["code"], !code.isEmpty else {
            throw ConnectError.failed("Google sign-in could not be verified. Try again.")
        }
        try await api.send(.post, "twin/gmail", body: GmailExchangeRequest(code: code, codeVerifier: verifier, redirectUri: redirectURI))
    }

    private func authorize(url: URL, presentationContextProvider: any ASWebAuthenticationPresentationContextProviding) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
                self?.webSession = nil
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: ConnectError.cancelled)
                } else if let error {
                    continuation.resume(throwing: ConnectError.failed(error.localizedDescription))
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: ConnectError.failed("Google didn't return to Bounty."))
                }
            }
            session.presentationContextProvider = presentationContextProvider
            webSession = session
            if !session.start() {
                webSession = nil
                continuation.resume(throwing: ConnectError.failed("Google sign-in could not start."))
            }
        }
    }

    private static func randomURLSafe(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw ConnectError.failed("Secure sign-in setup failed.")
        }
        return Data(bytes).base64URL
    }
}

private struct GmailExchangeRequest: Encodable, Sendable {
    let code: String
    let codeVerifier: String
    let redirectUri: String
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
