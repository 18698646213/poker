import Foundation
import Testing
@testable import PokerCore

@Test func parsesAbsoluteHTTPProxyRequest() throws {
    let data = Data(
        "GET http://example.com/api?q=1 HTTP/1.1\r\nHost: example.com\r\nX-Test: yes\r\n\r\n"
            .utf8
    )
    let parsed = try #require(HTTPRequestHead.parse(data))

    #expect(parsed.head.method == "GET")
    #expect(parsed.head.originFormTarget == "/api?q=1")
    #expect(parsed.head.hostAndPort?.host == "example.com")
    #expect(parsed.head.hostAndPort?.port == 80)
}

@Test func parsesConnectTunnel() throws {
    let parsed = try #require(
        HTTPRequestHead.parse(
            Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8)
        )
    )

    #expect(parsed.head.displayURL == "https://example.com:443")
    #expect(parsed.head.hostAndPort?.port == 443)
}

@Test func waitsForCompleteRequestBody() throws {
    let incomplete = Data(
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nabc"
            .utf8
    )
    #expect(HTTPRequestHead.parse(incomplete) == nil)

    let complete = incomplete + Data("de".utf8)
    let parsed = try #require(HTTPRequestHead.parse(complete))
    #expect(String(data: parsed.body, encoding: .utf8) == "abcde")
}

@Test func decodesChunkedResponse() throws {
    let response = Data(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
            .utf8
    )
    let parsed = try #require(HTTPResponseHead.parse(response))

    #expect(String(data: parsed.body, encoding: .utf8) == "Wikipedia")
}

@Test func detectsCompleteResponseWithoutWaitingForSocketClose() {
    let incomplete = Data(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc".utf8
    )
    let complete = incomplete + Data("de".utf8)

    #expect(!HTTPResponseHead.isCompleteMessage(incomplete))
    #expect(HTTPResponseHead.isCompleteMessage(complete))
    #expect(
        HTTPResponseHead.isCompleteMessage(
            Data(
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\n\r\n"
                    .utf8
            )
        )
    )
}

@Test func rewritesMatchingURL() {
    let engine = RewriteEngine(
        rules: [
            RewriteRule(
                name: "API",
                field: .url,
                pattern: "api\\.example\\.com",
                replacement: "localhost:8080"
            )
        ]
    )

    #expect(
        engine.rewriteURL("http://api.example.com/users")
            == "http://localhost:8080/users"
    )
}

@Test func exportsHARArchive() throws {
    let session = CaptureSession(
        method: "GET",
        url: "http://example.com/",
        statusCode: 200,
        state: .completed
    )
    let data = try HARExporter.data(for: [session])
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(object["log"] != nil)
}

@Test func createsRootAndHostCertificates() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let authority = try CertificateAuthority(directoryURL: directory)
    let root = try authority.rootCertificateData()
    let identity = try authority.identity(for: "api.example.com")

    #expect(!root.isEmpty)
    #expect(!identity.certificateChain.isEmpty)
}
