import Foundation
import Testing
@testable import PokerCore

private final class TestTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod ==
                NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private final class SessionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [CaptureSession] = []

    func append(_ session: CaptureSession) {
        lock.withLock {
            sessions.append(session)
        }
    }

    func snapshot() -> [CaptureSession] {
        lock.withLock {
            sessions
        }
    }
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["POKER_RUN_NETWORK_TESTS"] == "1"
    ),
    .timeLimit(.minutes(1))
)
func decryptsHTTPSRequestAndResponse() async throws {
    let recorder = SessionRecorder()
    let server = ProxyServer { event in
        if case let .updated(session) = event, session.method == "GET" {
            recorder.append(session)
        }
    }
    let port: UInt16 = 18_889
    try server.start(port: port)
    defer {
        server.stop()
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [
        "HTTPEnable": true,
        "HTTPProxy": "127.0.0.1",
        "HTTPPort": Int(port),
        "HTTPSEnable": true,
        "HTTPSProxy": "127.0.0.1",
        "HTTPSPort": Int(port)
    ]
    let session = URLSession(
        configuration: configuration,
        delegate: TestTrustDelegate(),
        delegateQueue: nil
    )
    let (_, response) = try await session.data(
        from: try #require(URL(string: "https://example.com/"))
    )
    #expect((response as? HTTPURLResponse)?.statusCode == 200)

    try await Task.sleep(for: .milliseconds(100))
    let result = recorder.snapshot()

    #expect(result.contains {
        $0.url == "https://example.com/" &&
            $0.statusCode == 200 &&
            !$0.responseBody.isEmpty
    })
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["POKER_RUN_NETWORK_TESTS"] == "1"
    ),
    .timeLimit(.minutes(1))
)
func modifiesInterceptedHTTPSRequestAndResponse() async throws {
    let recorder = SessionRecorder()
    let server = ProxyServer { event in
        switch event {
        case let .intercepted(intercepted, resume):
            var edited = intercepted.session
            switch intercepted.phase {
            case .request:
                var components = URLComponents(string: edited.url)
                components?.queryItems = [
                    URLQueryItem(name: "intercepted", value: "true")
                ]
                edited.url = components?.url?.absoluteString ?? edited.url
                edited.requestHeaders.append(
                    HTTPHeader(name: "X-Poker-Intercepted", value: "true")
                )
            case .response:
                edited.statusCode = 202
                edited.responseHeaders = [
                    HTTPHeader(
                        name: "Content-Type",
                        value: "text/plain; charset=utf-8"
                    )
                ]
                edited.responseBody = Data("modified response".utf8)
            }
            resume(edited)
        case let .updated(session):
            if session.method == "GET", session.state == .completed {
                recorder.append(session)
            }
        case .inserted:
            break
        }
    }
    server.updateInterceptConfiguration(
        InterceptConfiguration(
            interceptRequests: true,
            interceptResponses: true
        )
    )
    let port: UInt16 = 18_890
    try server.start(port: port)
    defer {
        server.stop()
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [
        "HTTPEnable": true,
        "HTTPProxy": "127.0.0.1",
        "HTTPPort": Int(port),
        "HTTPSEnable": true,
        "HTTPSProxy": "127.0.0.1",
        "HTTPSPort": Int(port)
    ]
    let session = URLSession(
        configuration: configuration,
        delegate: TestTrustDelegate(),
        delegateQueue: nil
    )
    let (data, response) = try await session.data(
        from: try #require(URL(string: "https://example.com/"))
    )

    #expect((response as? HTTPURLResponse)?.statusCode == 202)
    #expect(String(data: data, encoding: .utf8) == "modified response")

    try await Task.sleep(for: .milliseconds(100))
    let result = recorder.snapshot()
    #expect(result.contains {
        $0.url == "https://example.com/?intercepted=true" &&
            $0.requestHeaders.contains {
                $0.name == "X-Poker-Intercepted" && $0.value == "true"
            } &&
            $0.statusCode == 202 &&
            String(data: $0.responseBody, encoding: .utf8) == "modified response"
    })
}
