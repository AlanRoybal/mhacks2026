import AuthenticationServices
import CryptoKit
import Foundation
import Security
import TwinModels
import TwinNetworking

public struct LinkedInOIDCConfiguration: Equatable, Sendable {
    public let clientID: String
    public let redirectURI: URL
    public let authorizationEndpoint: URL
    public let callbackPath: String
    public let scopes: [String]

    public init(
        clientID: String,
        redirectURI: URL,
        authorizationEndpoint: URL = URL(string: "https://www.linkedin.com/oauth/v2/authorization")!,
        callbackPath: String = "auth/linkedin-callback",
        scopes: [String] = ["openid", "profile", "email"]
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.authorizationEndpoint = authorizationEndpoint
        self.callbackPath = callbackPath
        self.scopes = scopes
    }
}

public struct LinkedInAuthorizationRequest: Equatable, Sendable {
    public let url: URL
    public let state: String
    public let codeVerifier: String

    public init(url: URL, state: String, codeVerifier: String) {
        self.url = url
        self.state = state
        self.codeVerifier = codeVerifier
    }
}

public enum LinkedInOIDCError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case authorizationFailed(String)
    case missingCallbackValues
    case stateMismatch
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "LinkedIn sign-in is not configured."
        case .authorizationFailed(let message):
            message
        case .missingCallbackValues:
            "LinkedIn did not return the information needed to sign in."
        case .stateMismatch:
            "LinkedIn sign-in could not be verified."
        case .cancelled:
            "LinkedIn sign-in was cancelled."
        }
    }
}

public enum PKCEGenerator {
    public static func makeAuthorizationRequest(configuration: LinkedInOIDCConfiguration) throws -> LinkedInAuthorizationRequest {
        guard !configuration.clientID.isEmpty,
              configuration.redirectURI.scheme != nil,
              var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)
        else {
            throw LinkedInOIDCError.invalidConfiguration
        }

        let state = try randomURLSafeString(byteCount: 24)
        let verifier = try randomURLSafeString(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let url = components.url else {
            throw LinkedInOIDCError.invalidConfiguration
        }
        return LinkedInAuthorizationRequest(url: url, state: state, codeVerifier: verifier)
    }

    private static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw LinkedInOIDCError.authorizationFailed("Secure sign-in setup failed.")
        }
        return Data(bytes).base64URLEncodedString()
    }
}

@MainActor
public final class LinkedInAuthenticator {
    private let configuration: LinkedInOIDCConfiguration
    private let api: APIClient
    private var webSession: ASWebAuthenticationSession?

    public init(configuration: LinkedInOIDCConfiguration, api: APIClient) {
        self.configuration = configuration
        self.api = api
    }

    public func signIn(
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> AuthSessionResponse {
        let request = try PKCEGenerator.makeAuthorizationRequest(configuration: configuration)
        let callbackURL = try await authorize(
            request: request,
            presentationContextProvider: presentationContextProvider
        )
        let callback = try Self.validate(callbackURL: callbackURL, expectedState: request.state)
        let body = LinkedInExchangeRequest(
            code: callback.code,
            codeVerifier: request.codeVerifier,
            redirectURI: configuration.redirectURI.absoluteString
        )
        return try await api.request(
            .post,
            configuration.callbackPath,
            body: body,
            authenticated: false
        )
    }

    private func authorize(
        request: LinkedInAuthorizationRequest,
        presentationContextProvider: any ASWebAuthenticationPresentationContextProviding
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: request.url,
                callbackURLScheme: configuration.redirectURI.scheme
            ) { [weak self] url, error in
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
    }

    nonisolated static func validate(callbackURL: URL, expectedState: String) throws -> (code: String, state: String) {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw LinkedInOIDCError.missingCallbackValues
        }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let error = values["error"] {
            throw LinkedInOIDCError.authorizationFailed(values["error_description"] ?? error)
        }
        guard let code = values["code"], let state = values["state"] else {
            throw LinkedInOIDCError.missingCallbackValues
        }
        guard state == expectedState else {
            throw LinkedInOIDCError.stateMismatch
        }
        return (code, state)
    }
}

public struct LinkedInExchangeRequest: Codable, Equatable, Sendable {
    public let code: String
    public let codeVerifier: String
    public let redirectURI: String

    public init(code: String, codeVerifier: String, redirectURI: String) {
        self.code = code
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
    }

    enum CodingKeys: String, CodingKey {
        case code
        case codeVerifier = "code_verifier"
        case redirectURI = "redirect_uri"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
