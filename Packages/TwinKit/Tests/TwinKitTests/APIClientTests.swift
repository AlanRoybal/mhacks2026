import Foundation
@testable import TwinNetworking
import XCTest

final class APIClientTests: XCTestCase {
    func testAuthenticatedRequestAddsBearerTokenAndDecodesResponse() async throws {
        let body = Data(#"{"user_id":"user-1","name":"Alan"}"#.utf8)
        let transport = RecordingTransport(statusCode: 200, body: body)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com/v1/")!,
            transport: transport,
            tokenProvider: StaticTokenProvider(token: "token-123")
        )

        let response: PersonResponse = try await client.request(.get, "profile")
        let recordedRequest = await transport.lastRequest
        let request = try XCTUnwrap(recordedRequest)

        XCTAssertEqual(response, PersonResponse(userId: "user-1", name: "Alan"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/profile")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
    }

    func testAuthenticatedRequestWithoutTokenFailsBeforeTransport() async {
        let transport = RecordingTransport(statusCode: 200, body: Data())
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            transport: transport,
            tokenProvider: StaticTokenProvider(token: nil)
        )

        do {
            let _: PersonResponse = try await client.request(.get, "profile")
            XCTFail("Expected unauthorized error")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testServerErrorDecodesEnvelope() async {
        let body = Data(#"{"error":{"code":"offer_expired","message":"This offer expired."}}"#.utf8)
        let transport = RecordingTransport(statusCode: 409, body: body)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            transport: transport
        )

        do {
            let _: PersonResponse = try await client.request(.get, "offer", authenticated: false)
            XCTFail("Expected server error")
        } catch {
            XCTAssertEqual(
                error as? APIError,
                .server(status: 409, code: "offer_expired", message: "This offer expired.")
            )
        }
    }
}

private struct PersonResponse: Codable, Equatable, Sendable {
    let userId: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
    }
}

private actor RecordingTransport: HTTPTransport {
    private let statusCode: Int
    private let body: Data
    private(set) var requests: [URLRequest] = []

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    var lastRequest: URLRequest? { requests.last }
    var requestCount: Int { requests.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}

private actor StaticTokenProvider: AccessTokenProvider {
    private let token: String?

    init(token: String?) {
        self.token = token
    }

    func accessToken() async -> String? {
        token
    }
}
