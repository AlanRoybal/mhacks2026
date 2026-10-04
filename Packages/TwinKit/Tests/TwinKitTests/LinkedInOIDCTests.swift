import Foundation
@testable import TwinAuth
import XCTest

final class LinkedInOIDCTests: XCTestCase {
    func testAuthorizationRequestUsesOIDCAndPKCE() throws {
        let configuration = LinkedInOIDCConfiguration(
            clientID: "client-id",
            redirectURI: URL(string: "bounty://oauth/linkedin")!
        )

        let request = try PKCEGenerator.makeAuthorizationRequest(configuration: configuration)
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(query["response_type"]!, "code")
        XCTAssertEqual(query["client_id"]!, "client-id")
        XCTAssertEqual(query["redirect_uri"]!, "bounty://oauth/linkedin")
        XCTAssertEqual(query["scope"]!, "openid profile email")
        XCTAssertEqual(query["code_challenge_method"]!, "S256")
        XCTAssertEqual(query["state"]!, request.state)
        XCTAssertNotNil(query["code_challenge"]!)
        XCTAssertFalse(request.codeVerifier.contains("="))
    }

    func testCallbackRejectsMismatchedState() throws {
        let callback = URL(string: "bounty://oauth/linkedin?code=abc&state=wrong")!

        XCTAssertThrowsError(try LinkedInAuthenticator.validate(callbackURL: callback, expectedState: "expected")) {
            XCTAssertEqual($0 as? LinkedInOIDCError, .stateMismatch)
        }
    }

    func testCallbackSurfacesLinkedInError() throws {
        let callback = URL(string: "bounty://oauth/linkedin?error=access_denied&error_description=Not%20now")!

        XCTAssertThrowsError(try LinkedInAuthenticator.validate(callbackURL: callback, expectedState: "expected")) {
            XCTAssertEqual($0 as? LinkedInOIDCError, .authorizationFailed("Not now"))
        }
    }
}

final class LinkedInServerSignInTests: XCTestCase {
    func testServerCallbackBuildsSession() throws {
        let callback = URL(string: "bounty://auth?token=abc.def.ghi&user_id=u_123&expires_in=2592000")!

        let session = try LinkedInServerAuthenticator.session(fromCallback: callback)

        XCTAssertEqual(session.accessToken, "abc.def.ghi")
        XCTAssertEqual(session.userID, "u_123")
        XCTAssertEqual(session.expiresIn, 2_592_000)
        XCTAssertNil(session.refreshToken)
    }

    func testServerCallbackSurfacesFailure() throws {
        let callback = URL(string: "bounty://auth?error=linkedin_failed")!

        XCTAssertThrowsError(try LinkedInServerAuthenticator.session(fromCallback: callback)) {
            guard case .authorizationFailed = $0 as? LinkedInOIDCError else { return XCTFail("unexpected \($0)") }
        }
    }

    func testServerCallbackRequiresAllValues() throws {
        let callback = URL(string: "bounty://auth?token=abc")!

        XCTAssertThrowsError(try LinkedInServerAuthenticator.session(fromCallback: callback)) {
            XCTAssertEqual($0 as? LinkedInOIDCError, .missingCallbackValues)
        }
    }
}
