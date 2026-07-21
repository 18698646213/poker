import Foundation

public enum CaptureState: String, Codable, Sendable {
    case pending
    case completed
    case failed
}

public struct HTTPHeader: Codable, Hashable, Sendable {
    public var name: String
    public var value: String

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

public enum InterceptPhase: String, Sendable {
    case request
    case response
}

public struct InterceptedSession: Identifiable, Sendable {
    public let phase: InterceptPhase
    public let session: CaptureSession

    public var id: CaptureSession.ID { session.id }

    public init(phase: InterceptPhase, session: CaptureSession) {
        self.phase = phase
        self.session = session
    }
}

public struct InterceptConfiguration: Sendable {
    public var interceptRequests: Bool
    public var interceptResponses: Bool
    public var domains: [String]

    public init(
        interceptRequests: Bool = false,
        interceptResponses: Bool = false,
        domains: [String] = []
    ) {
        self.interceptRequests = interceptRequests
        self.interceptResponses = interceptResponses
        self.domains = domains
    }

    public func matches(url: String) -> Bool {
        let configuredDomains = domains.compactMap(Self.normalizedDomain)
        guard !configuredDomains.isEmpty else {
            return true
        }
        guard let host = URLComponents(string: url)?.host?.lowercased() else {
            return false
        }
        return configuredDomains.contains {
            host == $0 || host.hasSuffix(".\($0)")
        }
    }

    private static func normalizedDomain(_ domain: String) -> String? {
        let normalized = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }
}

public enum SessionEvent: @unchecked Sendable {
    case inserted(CaptureSession)
    case updated(CaptureSession)
    case intercepted(
        InterceptedSession,
        resume: (CaptureSession) -> Void
    )
}
