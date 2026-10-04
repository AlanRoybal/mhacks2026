import Foundation
import TwinModels
import TwinNetworking

public actor SessionStore: AccessTokenProvider {
    private var session: AuthSession?
    private let keychain: KeychainStore
    private let encoder = TwinJSON.encoder()
    private let decoder = TwinJSON.decoder()

    public init(keychain: KeychainStore = KeychainStore()) {
        let restoredSession: AuthSession?
        do {
            if let data = try keychain.load() {
                restoredSession = try TwinJSON.decoder().decode(AuthSession.self, from: data)
            } else {
                restoredSession = nil
            }
        } catch {
            restoredSession = nil
        }
        self.keychain = keychain
        session = restoredSession
    }

    public var currentSession: AuthSession? {
        session
    }

    public var isSignedIn: Bool {
        guard let session else { return false }
        return session.expiresAt > .now
    }

    public func adopt(_ response: AuthSessionResponse, now: Date = .now) throws {
        try adopt(response.session(now: now))
    }

    public func adopt(_ session: AuthSession) throws {
        let data = try encoder.encode(session)
        try keychain.save(data)
        self.session = session
    }

    public func signOut() throws {
        try keychain.clear()
        session = nil
    }

    public func accessToken() async -> String? {
        guard let session, session.expiresAt.timeIntervalSinceNow > 30 else {
            return nil
        }
        return session.accessToken
    }
}
