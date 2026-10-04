import AuthenticationServices
import Foundation
import TwinModels

/// LinkedIn sign-in run by the backend. LinkedIn only accepts http(s) redirect URLs, so the app can't receive
/// the authorization code itself: it opens `<api>/auth/linkedin/start`, LinkedIn redirects to the backend's
/// https callback, and the backend (which holds the client secret) ends the flow at
/// `<scheme>://auth?token=…&user_id=…&expires_in=…` or `<scheme>://auth?error=…`.
@MainActor
public final class LinkedInServerAuthenticator {
    private let startURL: URL
    private let callbackScheme: String
    private var webSession: ASWebAuthenticationSession?

    public init(startURL: URL, callbackScheme: String) {
        self.startURL = startURL
        self.callbackScheme = callbackScheme
    }

    public func signIn(
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> AuthSessionResponse {
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: startURL, callbackURLScheme: callbackScheme) { [weak self] url, error in
                self?.webSession = nil
                if let authenticationError = error as? ASWebAuthenticationSessionError,
                   authenticationError.code == .canceledLogin {
                    continuation.resume(throwing: LinkedInOIDCError.cancelled)
                } else if let error {
                    continuation.resume(throwing: LinkedInOIDCError.authorizationFailed(error.localizedDescription))
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: LinkedInOIDCError.missingCallbackValues)
                }
            }
            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = true
            webSession = session
            guard session.start() else {
                webSession = nil
                continuation.resume(throwing: LinkedInOIDCError.authorizationFailed("LinkedIn sign-in could not start."))
                return
            }
        }
        return try Self.session(fromCallback: callbackURL)
    }

    nonisolated static func session(fromCallback url: URL) throws -> AuthSessionResponse {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if values["error"] != nil {
            throw LinkedInOIDCError.authorizationFailed("LinkedIn sign-in could not be completed. Please try again.")
        }
        guard let token = values["token"], !token.isEmpty,
              let userID = values["user_id"], !userID.isEmpty,
              let expiresIn = values["expires_in"].flatMap(Int.init)
        else {
            throw LinkedInOIDCError.missingCallbackValues
        }
        return AuthSessionResponse(accessToken: token, refreshToken: nil, expiresIn: expiresIn, userID: userID)
    }
}
