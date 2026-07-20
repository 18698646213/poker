import Foundation

public enum CaptureState: String, Codable, Sendable {
    case pending
    case completed
    case failed
}

public struct HTTPHeader: Codable, Hashable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct CaptureSession: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var duration: TimeInterval?
    public var method: String
    public var url: String
    public var requestHeaders: [HTTPHeader]
    public var requestBody: Data
    public var statusCode: Int?
    public var responseHeaders: [HTTPHeader]
    public var responseBody: Data
    public var state: CaptureState
    public var errorDescription: String?
    public var isWebSocket: Bool

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        duration: TimeInterval? = nil,
        method: String,
        url: String,
        requestHeaders: [HTTPHeader] = [],
        requestBody: Data = Data(),
        statusCode: Int? = nil,
        responseHeaders: [HTTPHeader] = [],
        responseBody: Data = Data(),
        state: CaptureState = .pending,
        errorDescription: String? = nil,
        isWebSocket: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.state = state
        self.errorDescription = errorDescription
        self.isWebSocket = isWebSocket
    }
}

public enum SessionEvent: Sendable {
    case inserted(CaptureSession)
    case updated(CaptureSession)
}
