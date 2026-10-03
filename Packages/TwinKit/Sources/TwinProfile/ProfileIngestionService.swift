import Foundation
import TwinModels
import TwinNetworking

public enum ProfileDocumentSource: String, Codable, CaseIterable, Sendable {
    case resume
    case linkedInPDF = "linkedin_pdf"
    case linkedInExport = "linkedin_export"
}

public struct ProfileUploadRequest: Codable, Equatable, Sendable {
    public let fileName: String
    public let contentType: String
    public let byteCount: Int64
    public let source: ProfileDocumentSource

    public init(fileName: String, contentType: String, byteCount: Int64, source: ProfileDocumentSource) {
        self.fileName = fileName
        self.contentType = contentType
        self.byteCount = byteCount
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case contentType = "content_type"
        case byteCount = "byte_count"
        case source
    }
}

public struct ProfileUploadTarget: Codable, Equatable, Sendable {
    public let uploadURL: URL
    public let objectKey: String
    public let headers: [String: String]

    public init(uploadURL: URL, objectKey: String, headers: [String: String] = [:]) {
        self.uploadURL = uploadURL
        self.objectKey = objectKey
        self.headers = headers
    }

    enum CodingKeys: String, CodingKey {
        case uploadURL = "upload_url"
        case objectKey = "object_key"
        case headers
    }
}

public struct ProfileIngestRequest: Codable, Equatable, Sendable {
    public let objectKey: String
    public let source: ProfileDocumentSource

    public init(objectKey: String, source: ProfileDocumentSource) {
        self.objectKey = objectKey
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case objectKey = "object_key"
        case source
    }
}

public struct ProfileIngestResponse: Codable, Equatable, Sendable {
    public let ingestionID: String
    public let status: String

    public init(ingestionID: String, status: String) {
        self.ingestionID = ingestionID
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case ingestionID = "ingestion_id"
        case status
    }
}

public struct ProfileIngestionEndpoints: Equatable, Sendable {
    public let uploadTargetPath: String
    public let ingestPath: String

    public init(
        uploadTargetPath: String = "profile/upload-url",
        ingestPath: String = "profile/ingest"
    ) {
        self.uploadTargetPath = uploadTargetPath
        self.ingestPath = ingestPath
    }
}

public protocol FileUploadTransport: Sendable {
    func upload(fileURL: URL, to target: ProfileUploadTarget) async throws
}

public struct URLSessionFileUploadTransport: FileUploadTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func upload(fileURL: URL, to target: ProfileUploadTarget) async throws {
        var request = URLRequest(url: target.uploadURL)
        request.httpMethod = "PUT"
        for (name, value) in target.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let response = response as? HTTPURLResponse else {
            throw APIError.transport("Missing upload response")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.server(
                status: response.statusCode,
                code: "upload_\(response.statusCode)",
                message: "The document upload failed."
            )
        }
    }
}

public struct ProfileIngestionService: Sendable {
    private let api: APIClient
    private let uploadTransport: any FileUploadTransport
    private let endpoints: ProfileIngestionEndpoints

    public init(
        api: APIClient,
        uploadTransport: any FileUploadTransport = URLSessionFileUploadTransport(),
        endpoints: ProfileIngestionEndpoints = ProfileIngestionEndpoints()
    ) {
        self.api = api
        self.uploadTransport = uploadTransport
        self.endpoints = endpoints
    }

    public func ingest(fileURL: URL, source: ProfileDocumentSource) async throws -> ProfileIngestResponse {
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .nameKey])
        let byteCount = Int64(values.fileSize ?? 0)
        let fileName = values.name ?? fileURL.lastPathComponent
        let contentType = Self.contentType(for: fileURL)
        let uploadRequest = ProfileUploadRequest(
            fileName: fileName,
            contentType: contentType,
            byteCount: byteCount,
            source: source
        )
        let target: ProfileUploadTarget = try await api.request(
            .post,
            endpoints.uploadTargetPath,
            body: uploadRequest
        )
        try await uploadTransport.upload(fileURL: fileURL, to: target)
        return try await api.request(
            .post,
            endpoints.ingestPath,
            body: ProfileIngestRequest(objectKey: target.objectKey, source: source)
        )
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":
            "application/pdf"
        case "zip":
            "application/zip"
        case "doc":
            "application/msword"
        case "docx":
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        default:
            "application/octet-stream"
        }
    }
}
