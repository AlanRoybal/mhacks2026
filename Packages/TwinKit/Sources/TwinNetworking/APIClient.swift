import Foundation
import TwinModels

public enum APIError: Error, Equatable, LocalizedError, Sendable {
    case unauthorized
    case invalidURL
    case server(status: Int, code: String, message: String)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Your session expired. Please sign in again."
        case .invalidURL:
            "The server address is invalid."
        case .server(_, _, let message):
            message
        case .transport:
            "Bounty could not reach the server."
        case .decoding:
            "Bounty could not read the server response."
        }
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw APIError.transport("Missing HTTP response")
        }
        return (data, response)
    }
}

public protocol AccessTokenProvider: Sendable {
    func accessToken() async -> String?
}

public actor APIClient {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    public let baseURL: URL
    private let transport: any HTTPTransport
    private let tokenProvider: (any AccessTokenProvider)?
    private let encoder = TwinJSON.encoder()
    private let decoder = TwinJSON.decoder()

    public init(
        baseURL: URL,
        transport: any HTTPTransport = URLSessionTransport(),
        tokenProvider: (any AccessTokenProvider)? = nil
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokenProvider = tokenProvider
    }

    public func request<Response: Decodable & Sendable>(
        _ method: Method,
        _ path: String,
        query: [URLQueryItem] = [],
        authenticated: Bool = true,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        try await perform(method, path, query: query, body: nil, authenticated: authenticated)
    }

    public func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: Method,
        _ path: String,
        body: Body,
        authenticated: Bool = true,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let data = try encoder.encode(body)
        return try await perform(method, path, query: [], body: data, authenticated: authenticated)
    }

    public func send(_ method: Method, _ path: String, authenticated: Bool = true) async throws {
        let _: EmptyResponse = try await perform(method, path, query: [], body: nil, authenticated: authenticated)
    }

    public func send<Body: Encodable & Sendable>(
        _ method: Method,
        _ path: String,
        body: Body,
        authenticated: Bool = true
    ) async throws {
        let data = try encoder.encode(body)
        let _: EmptyResponse = try await perform(method, path, query: [], body: data, authenticated: authenticated)
    }

    private func perform<Response: Decodable>(
        _ method: Method,
        _ path: String,
        query: [URLQueryItem],
        body: Data?,
        authenticated: Bool
    ) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query
        }
        guard let url = components?.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if authenticated {
            guard let token = await tokenProvider?.accessToken() else {
                throw APIError.unauthorized
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw APIError.unauthorized
            }
            if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
                throw APIError.server(
                    status: response.statusCode,
                    code: envelope.error.code,
                    message: envelope.error.message
                )
            }
            throw APIError.server(
                status: response.statusCode,
                code: "http_\(response.statusCode)",
                message: "Request failed with status \(response.statusCode)."
            )
        }

        if Response.self == EmptyResponse.self {
            return EmptyResponse() as! Response
        }

        do {
            return try decoder.decode(Response.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }
}

public struct EmptyResponse: Decodable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {}
}

private struct APIErrorEnvelope: Decodable {
    let error: APIErrorPayload
}

private struct APIErrorPayload: Decodable {
    let code: String
    let message: String
}
