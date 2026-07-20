import Foundation

public enum HARExporter {
    public static func data(for sessions: [CaptureSession]) throws -> Data {
        let entries = sessions.map(HAREntry.init)
        let archive = HARArchive(
            log: HARLog(
                version: "1.2",
                creator: HARCreator(name: "Poker", version: "0.1.0"),
                entries: entries
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }
}

private struct HARArchive: Encodable {
    let log: HARLog
}

private struct HARLog: Encodable {
    let version: String
    let creator: HARCreator
    let entries: [HAREntry]
}

private struct HARCreator: Encodable {
    let name: String
    let version: String
}

private struct HAREntry: Encodable {
    let startedDateTime: String
    let time: Double
    let request: HARRequest
    let response: HARResponse
    let cache: [String: String]
    let timings: HARTimings

    init(session: CaptureSession) {
        startedDateTime = ISO8601DateFormatter().string(from: session.startedAt)
        time = (session.duration ?? 0) * 1_000
        request = HARRequest(session: session)
        response = HARResponse(session: session)
        cache = [:]
        timings = HARTimings(wait: time)
    }
}

private struct HARRequest: Encodable {
    let method: String
    let url: String
    let httpVersion: String
    let headers: [HARHeader]
    let queryString: [HARHeader]
    let headersSize: Int
    let bodySize: Int
    let postData: HARPostData?

    init(session: CaptureSession) {
        method = session.method
        url = session.url
        httpVersion = "HTTP/1.1"
        headers = session.requestHeaders.map(HARHeader.init)
        queryString = URLComponents(string: session.url)?.queryItems?.map {
            HARHeader(name: $0.name, value: $0.value ?? "")
        } ?? []
        headersSize = -1
        bodySize = session.requestBody.count
        postData = session.requestBody.isEmpty
            ? nil
            : HARPostData(
                mimeType: session.requestHeaders.contentType,
                text: String(data: session.requestBody, encoding: .utf8) ?? ""
            )
    }
}

private struct HARResponse: Encodable {
    let status: Int
    let statusText: String
    let httpVersion: String
    let headers: [HARHeader]
    let cookies: [String]
    let content: HARContent
    let redirectURL: String
    let headersSize: Int
    let bodySize: Int

    init(session: CaptureSession) {
        status = session.statusCode ?? 0
        statusText = HTTPURLResponse.localizedString(forStatusCode: status)
        httpVersion = "HTTP/1.1"
        headers = session.responseHeaders.map(HARHeader.init)
        cookies = []
        content = HARContent(
            size: session.responseBody.count,
            mimeType: session.responseHeaders.contentType,
            text: String(data: session.responseBody, encoding: .utf8) ?? ""
        )
        redirectURL = session.responseHeaders
            .first { $0.name.caseInsensitiveCompare("Location") == .orderedSame }?
            .value ?? ""
        headersSize = -1
        bodySize = session.responseBody.count
    }
}

private struct HARHeader: Encodable {
    let name: String
    let value: String

    init(_ header: HTTPHeader) {
        name = header.name
        value = header.value
    }

    init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

private struct HARPostData: Encodable {
    let mimeType: String
    let text: String
}

private struct HARContent: Encodable {
    let size: Int
    let mimeType: String
    let text: String
}

private struct HARTimings: Encodable {
    let send: Double = 0
    let wait: Double
    let receive: Double = 0
}

private extension [HTTPHeader] {
    var contentType: String {
        first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?
            .value ?? "application/octet-stream"
    }
}
