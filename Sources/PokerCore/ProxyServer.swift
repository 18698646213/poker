import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import NIOSSL

public enum ProxyServerError: LocalizedError {
    case invalidPort
    case invalidRequest
    case missingHost

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "代理端口无效或已在运行"
        case .invalidRequest:
            return "无法解析 HTTP 请求"
        case .missingHost:
            return "请求缺少目标主机"
        }
    }
}

public final class ProxyServer: @unchecked Sendable {
    public typealias EventHandler = @Sendable (SessionEvent) -> Void

    private let lock = NSLock()
    private let eventHandler: EventHandler
    private var rules: [RewriteRule] = []
    private var serverChannel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var blockingPool: NIOThreadPool?

    public init(eventHandler: @escaping EventHandler) {
        self.eventHandler = eventHandler
    }

    public func start(port: UInt16 = 8888) throws {
        lock.lock()
        defer { lock.unlock() }
        guard port > 0, serverChannel == nil else {
            throw ProxyServerError.invalidPort
        }

        let certificateAuthority = try CertificateAuthority()
        let rootCertificate = try certificateAuthority.rootCertificateData()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let pool = NIOThreadPool(numberOfThreads: 2)
        pool.start()

        do {
            var clientTLS = TLSConfiguration.makeClientConfiguration()
            clientTLS.applicationProtocols = ["http/1.1"]
            let clientTLSContext = try NIOSSLContext(configuration: clientTLS)

            let channel = try ServerBootstrap(group: group)
                .serverChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: 1
                )
                .childChannelOption(
                    ChannelOptions.socketOption(.so_reuseaddr),
                    value: 1
                )
                .childChannelInitializer { [weak self] channel in
                    guard let self else {
                        return channel.eventLoop.makeFailedFuture(
                            ChannelError.ioOnClosedChannel
                        )
                    }
                    var encoderConfiguration = HTTPResponseEncoder.Configuration()
                    encoderConfiguration.automaticallySetFramingHeaders = false
                    let encoder = HTTPResponseEncoder(
                        configuration: encoderConfiguration
                    )
                    let decoder = ByteToMessageHandler(
                        HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)
                    )
                    let handler = ProxyFrontendHandler(
                        certificateAuthority: certificateAuthority,
                        rootCertificate: rootCertificate,
                        blockingPool: pool,
                        clientTLSContext: clientTLSContext,
                        plainEncoder: encoder,
                        plainDecoder: decoder,
                        rulesProvider: { [weak self] in self?.rulesSnapshot() ?? [] },
                        eventHandler: self.eventHandler
                    )
                    do {
                        try channel.pipeline.syncOperations.addHandlers(
                            encoder,
                            decoder,
                            handler
                        )
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .bind(host: "0.0.0.0", port: Int(port))
                .wait()

            eventLoopGroup = group
            blockingPool = pool
            serverChannel = channel
        } catch {
            try? pool.syncShutdownGracefully()
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let channel = serverChannel
        let pool = blockingPool
        let group = eventLoopGroup
        serverChannel = nil
        blockingPool = nil
        eventLoopGroup = nil
        lock.unlock()

        try? channel?.close().wait()
        try? pool?.syncShutdownGracefully()
        try? group?.syncShutdownGracefully()
    }

    public func updateRules(_ rules: [RewriteRule]) {
        lock.lock()
        self.rules = rules
        lock.unlock()
    }

    public func rootCertificateData() throws -> Data {
        try CertificateAuthority().rootCertificateData()
    }

    private func rulesSnapshot() -> [RewriteRule] {
        lock.lock()
        defer { lock.unlock() }
        return rules
    }
}

private final class ProxyFrontendHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum Mode {
        case forwardProxy
        case preparingTunnel
        case tunnel(host: String, port: Int)
    }

    private struct PendingRequest {
        var head: NIOHTTP1.HTTPRequestHead
        var body: ByteBuffer
        let host: String
        let port: Int
        let usesTLS: Bool
        let session: CaptureSession
    }

    private let certificateAuthority: CertificateAuthority
    private let rootCertificate: Data
    private let blockingPool: NIOThreadPool
    private let clientTLSContext: NIOSSLContext
    private let plainEncoder: HTTPResponseEncoder
    private let plainDecoder: ByteToMessageHandler<HTTPRequestDecoder>
    private let rulesProvider: @Sendable () -> [RewriteRule]
    private let eventHandler: ProxyServer.EventHandler

    private var mode: Mode = .forwardProxy
    private var requestHead: NIOHTTP1.HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var pendingRequests: [PendingRequest] = []
    private var requestInFlight = false

    init(
        certificateAuthority: CertificateAuthority,
        rootCertificate: Data,
        blockingPool: NIOThreadPool,
        clientTLSContext: NIOSSLContext,
        plainEncoder: HTTPResponseEncoder,
        plainDecoder: ByteToMessageHandler<HTTPRequestDecoder>,
        rulesProvider: @escaping @Sendable () -> [RewriteRule],
        eventHandler: @escaping ProxyServer.EventHandler
    ) {
        self.certificateAuthority = certificateAuthority
        self.rootCertificate = rootCertificate
        self.blockingPool = blockingPool
        self.clientTLSContext = clientTLSContext
        self.plainEncoder = plainEncoder
        self.plainDecoder = plainDecoder
        self.rulesProvider = rulesProvider
        self.eventHandler = eventHandler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            requestHead = head
            requestBody = context.channel.allocator.buffer(capacity: 0)
        case var .body(body):
            requestBody?.writeBuffer(&body)
        case .end:
            guard let head = requestHead else {
                sendError(.badRequest, message: "请求头缺失", context: context)
                return
            }
            let body = requestBody ?? context.channel.allocator.buffer(capacity: 0)
            requestHead = nil
            requestBody = nil
            handle(head: head, body: body, context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func handle(
        head: NIOHTTP1.HTTPRequestHead,
        body: ByteBuffer,
        context: ChannelHandlerContext
    ) {
        if head.method == .CONNECT {
            beginCONNECT(head: head, context: context)
            return
        }
        if isCertificateRequest(head) {
            sendRootCertificate(context: context)
            return
        }
        guard let baseDestination = destination(for: head) else {
            sendError(.badRequest, message: "请求缺少目标主机", context: context)
            return
        }

        let engine = RewriteEngine(rules: rulesProvider())
        let originalURL = displayURL(
            head: head,
            host: baseDestination.host,
            port: baseDestination.port,
            usesTLS: baseDestination.usesTLS
        )
        let rewrittenURL = engine.rewriteURL(originalURL)
        let rewrittenDestination = destination(
            from: rewrittenURL,
            fallback: baseDestination
        )
        var headers = engine.rewriteHeaders(
            captureHeaders(head.headers),
            field: .requestHeader
        )
        headers.removeAll {
            $0.name.caseInsensitiveCompare("Proxy-Connection") == .orderedSame
        }
        let bodyData = body.getData(
            at: body.readerIndex,
            length: body.readableBytes
        ) ?? Data()
        let session = CaptureSession(
            method: head.method.rawValue,
            url: rewrittenURL,
            requestHeaders: headers,
            requestBody: bodyData,
            isWebSocket: headers.contains {
                $0.name.caseInsensitiveCompare("Upgrade") == .orderedSame &&
                    $0.value.caseInsensitiveCompare("websocket") == .orderedSame
            }
        )
        eventHandler(.inserted(session))

        var upstreamHead = head
        upstreamHead.uri = originForm(rewrittenURL)
        upstreamHead.headers = nioHeaders(headers)
        upstreamHead.headers.remove(name: "Proxy-Connection")
        upstreamHead.headers.replaceOrAdd(
            name: "Host",
            value: authority(
                host: rewrittenDestination.host,
                port: rewrittenDestination.port,
                usesTLS: rewrittenDestination.usesTLS
            )
        )
        upstreamHead.headers.replaceOrAdd(name: "Connection", value: "close")
        upstreamHead.headers.replaceOrAdd(
            name: "Accept-Encoding",
            value: "identity"
        )
        if bodyData.isEmpty {
            upstreamHead.headers.remove(name: "Content-Length")
        } else {
            upstreamHead.headers.replaceOrAdd(
                name: "Content-Length",
                value: String(bodyData.count)
            )
        }

        pendingRequests.append(
            PendingRequest(
                head: upstreamHead,
                body: body,
                host: rewrittenDestination.host,
                port: rewrittenDestination.port,
                usesTLS: rewrittenDestination.usesTLS,
                session: session
            )
        )
        pump(context: context)
    }

    private func beginCONNECT(
        head: NIOHTTP1.HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        guard case .forwardProxy = mode,
              let target = parseAuthority(head.uri, defaultPort: 443)
        else {
            sendError(.badRequest, message: "CONNECT 目标无效", context: context)
            return
        }
        mode = .preparingTunnel
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure {
            context.fireErrorCaught($0)
        }

        let session = CaptureSession(
            method: "CONNECT",
            url: "https://\(head.uri)"
        )
        eventHandler(.inserted(session))

        blockingPool.runIfActive(eventLoop: context.eventLoop) {
            [certificateAuthority] in
            let identity = try certificateAuthority.identity(for: target.host)
            var configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: identity.certificateChain.map {
                    .certificate($0)
                },
                privateKey: .privateKey(identity.privateKey)
            )
            configuration.applicationProtocols = ["http/1.1"]
            return try NIOSSLContext(configuration: configuration)
        }.whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(tlsContext):
                self.sendCONNECTEstablished(
                    session: session,
                    host: target.host,
                    port: target.port,
                    tlsContext: tlsContext,
                    context: context
                )
            case let .failure(error):
                self.fail(session: session, error: error, context: context)
            }
        }
    }

    private func sendCONNECTEstablished(
        session: CaptureSession,
        host: String,
        port: Int,
        tlsContext: NIOSSLContext,
        context: ChannelHandlerContext
    ) {
        let response = NIOHTTP1.HTTPResponseHead(
            version: .http1_1,
            status: .ok
        )
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        promise.futureResult.whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.installTLS(
                    host: host,
                    port: port,
                    tlsContext: tlsContext,
                    context: context
                )
                var completed = session
                completed.statusCode = 200
                completed.state = .completed
                completed.duration = Date().timeIntervalSince(session.startedAt)
                self.eventHandler(.updated(completed))
            case let .failure(error):
                self.fail(session: session, error: error, context: context)
            }
        }
    }

    private func installTLS(
        host: String,
        port: Int,
        tlsContext: NIOSSLContext,
        context: ChannelHandlerContext
    ) {
        context.pipeline.syncOperations.removeHandler(plainEncoder).whenComplete {
            [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                context.close(promise: nil)
                return
            }
            do {
                var configuration = HTTPResponseEncoder.Configuration()
                configuration.automaticallySetFramingHeaders = false
                let secureEncoder = HTTPResponseEncoder(configuration: configuration)
                let secureDecoder = ByteToMessageHandler(HTTPRequestDecoder())
                let tlsHandler = NIOSSLServerHandler(context: tlsContext)
                let pipeline = context.pipeline.syncOperations
                try pipeline.addHandler(secureEncoder, position: .before(self))
                try pipeline.addHandler(
                    secureDecoder,
                    position: .after(secureEncoder)
                )
                try pipeline.addHandler(tlsHandler, position: .before(secureEncoder))
            } catch {
                context.fireErrorCaught(error)
                context.close(promise: nil)
                return
            }

            context.pipeline.syncOperations.removeHandler(self.plainDecoder).whenComplete {
                [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.mode = .tunnel(host: host, port: port)
                    context.channel.setOption(
                        ChannelOptions.autoRead,
                        value: true
                    ).whenComplete { _ in
                        context.read()
                    }
                case let .failure(error):
                    context.fireErrorCaught(error)
                    context.close(promise: nil)
                }
            }
        }
    }

    private func pump(context: ChannelHandlerContext) {
        guard !requestInFlight, !pendingRequests.isEmpty else {
            return
        }
        requestInFlight = true
        let request = pendingRequests.removeFirst()

        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelInitializer { [clientTLSContext] channel in
                do {
                    if request.usesTLS {
                        let serverHostname = request.host.contains(":")
                            ? nil
                            : request.host
                        let tlsHandler = try NIOSSLClientHandler(
                            context: clientTLSContext,
                            serverHostname: serverHostname
                        )
                        try channel.pipeline.syncOperations.addHandler(tlsHandler)
                    }
                    let responseHandler = UpstreamResponseHandler {
                        [weak self, weak context] result in
                        guard let self, let context else { return }
                        context.eventLoop.execute {
                            self.handleUpstreamResult(
                                result,
                                request: request,
                                context: context
                            )
                        }
                    }
                    try channel.pipeline.syncOperations.addHandlers(
                        HTTPRequestEncoder(),
                        ByteToMessageHandler(HTTPResponseDecoder()),
                        responseHandler
                    )
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        bootstrap.connect(host: request.host, port: request.port).whenComplete {
            [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(channel):
                channel.write(
                    HTTPClientRequestPart.head(request.head),
                    promise: nil
                )
                if request.body.readableBytes > 0 {
                    channel.write(
                        HTTPClientRequestPart.body(.byteBuffer(request.body)),
                        promise: nil
                    )
                }
                channel.writeAndFlush(
                    HTTPClientRequestPart.end(nil),
                    promise: nil
                )
            case let .failure(error):
                self.handleUpstreamResult(
                    .failure(error),
                    request: request,
                    context: context
                )
            }
        }
    }

    private func handleUpstreamResult(
        _ result: Result<UpstreamResponse, Error>,
        request: PendingRequest,
        context: ChannelHandlerContext
    ) {
        switch result {
        case let .success(response):
            let engine = RewriteEngine(rules: rulesProvider())
            var headers = engine.rewriteHeaders(
                captureHeaders(response.head.headers),
                field: .responseHeader
            )
            let originalBody = response.body.getData(
                at: response.body.readerIndex,
                length: response.body.readableBytes
            ) ?? Data()
            let body = engine.rewriteResponseBody(originalBody)
            headers.removeAll {
                $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame ||
                    $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame ||
                    $0.name.caseInsensitiveCompare("Connection") == .orderedSame
            }

            let hasBody = responseMayHaveBody(
                method: request.head.method,
                status: response.head.status
            )
            if hasBody {
                headers.append(
                    HTTPHeader(name: "Content-Length", value: String(body.count))
                )
            }
            headers.append(HTTPHeader(name: "Connection", value: "keep-alive"))

            let responseHead = NIOHTTP1.HTTPResponseHead(
                version: response.head.version,
                status: response.head.status,
                headers: nioHeaders(headers)
            )
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            if hasBody, !body.isEmpty {
                context.write(
                    wrapOutboundOut(
                        .body(.byteBuffer(context.channel.allocator.buffer(bytes: body)))
                    ),
                    promise: nil
                )
            }
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
            promise.futureResult.whenComplete { [weak self] writeResult in
                guard let self else { return }
                var completed = request.session
                completed.duration = Date().timeIntervalSince(
                    request.session.startedAt
                )
                completed.statusCode = Int(response.head.status.code)
                completed.responseHeaders = headers
                completed.responseBody = hasBody ? body : Data()
                completed.state = writeResult.isSuccess ? .completed : .failed
                if case let .failure(error) = writeResult {
                    completed.errorDescription = error.localizedDescription
                }
                self.eventHandler(.updated(completed))
                self.requestInFlight = false
                self.pump(context: context)
            }
        case let .failure(error):
            fail(session: request.session, error: error, context: context)
            requestInFlight = false
            pump(context: context)
        }
    }

    private func sendRootCertificate(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/x-x509-ca-cert")
        headers.add(
            name: "Content-Disposition",
            value: "attachment; filename=\"PokerCA.cer\""
        )
        headers.add(name: "Content-Length", value: String(rootCertificate.count))
        let response = NIOHTTP1.HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: headers
        )
        context.write(wrapOutboundOut(.head(response)), promise: nil)
        context.write(
            wrapOutboundOut(
                .body(
                    .byteBuffer(
                        context.channel.allocator.buffer(bytes: rootCertificate)
                    )
                )
            ),
            promise: nil
        )
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendError(
        _ status: HTTPResponseStatus,
        message: String,
        context: ChannelHandlerContext
    ) {
        let body = Data(message.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.count))
        headers.add(name: "Connection", value: "close")
        let head = NIOHTTP1.HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: headers
        )
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(
            wrapOutboundOut(
                .body(.byteBuffer(context.channel.allocator.buffer(bytes: body)))
            ),
            promise: nil
        )
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private func fail(
        session: CaptureSession,
        error: Error,
        context: ChannelHandlerContext
    ) {
        var failed = session
        failed.duration = Date().timeIntervalSince(session.startedAt)
        failed.state = .failed
        failed.errorDescription = error.localizedDescription
        eventHandler(.updated(failed))
        sendError(.badGateway, message: error.localizedDescription, context: context)
    }

    private func destination(
        for head: NIOHTTP1.HTTPRequestHead
    ) -> (host: String, port: Int, usesTLS: Bool)? {
        if case let .tunnel(host, port) = mode {
            return (host, port, true)
        }
        if let components = URLComponents(string: head.uri),
           let scheme = components.scheme,
           let host = components.host {
            let usesTLS = scheme.lowercased() == "https"
            return (host, components.port ?? (usesTLS ? 443 : 80), usesTLS)
        }
        guard let hostHeader = head.headers.first(name: "Host"),
              let target = parseAuthority(hostHeader, defaultPort: 80)
        else {
            return nil
        }
        return (target.host, target.port, false)
    }

    private func destination(
        from url: String,
        fallback: (host: String, port: Int, usesTLS: Bool)
    ) -> (host: String, port: Int, usesTLS: Bool) {
        guard let components = URLComponents(string: url),
              let host = components.host
        else {
            return fallback
        }
        let usesTLS = components.scheme?.lowercased() == "https"
        return (
            host,
            components.port ?? (usesTLS ? 443 : 80),
            usesTLS
        )
    }

    private func displayURL(
        head: NIOHTTP1.HTTPRequestHead,
        host: String,
        port: Int,
        usesTLS: Bool
    ) -> String {
        if URLComponents(string: head.uri)?.scheme != nil {
            return head.uri
        }
        let path = head.uri.hasPrefix("/") ? head.uri : "/\(head.uri)"
        return "\(usesTLS ? "https" : "http")://\(authority(host: host, port: port, usesTLS: usesTLS))\(path)"
    }

    private func originForm(_ url: String) -> String {
        guard let components = URLComponents(string: url),
              components.scheme != nil
        else {
            return url.hasPrefix("/") ? url : "/\(url)"
        }
        let path = components.percentEncodedPath.isEmpty
            ? "/"
            : components.percentEncodedPath
        return components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    }

    private func parseAuthority(
        _ value: String,
        defaultPort: Int
    ) -> (host: String, port: Int)? {
        if value.first == "[", let end = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<end])
            let suffix = value[value.index(after: end)...]
            let port = suffix.first == ":" ? Int(suffix.dropFirst()) : defaultPort
            return port.map { (host, $0) }
        }
        if let colon = value.lastIndex(of: ":"),
           let port = Int(value[value.index(after: colon)...]) {
            return (String(value[..<colon]), port)
        }
        return value.isEmpty ? nil : (value, defaultPort)
    }

    private func authority(host: String, port: Int, usesTLS: Bool) -> String {
        let defaultPort = usesTLS ? 443 : 80
        return port == defaultPort ? host : "\(host):\(port)"
    }

    private func isCertificateRequest(_ head: NIOHTTP1.HTTPRequestHead) -> Bool {
        guard head.method == .GET else { return false }
        if let components = URLComponents(string: head.uri),
           components.scheme != nil {
            return components.path == "/cert"
        }
        return head.uri.split(separator: "?", maxSplits: 1).first == "/cert"
    }

    private func captureHeaders(_ headers: HTTPHeaders) -> [HTTPHeader] {
        headers.map { HTTPHeader(name: $0.name, value: $0.value) }
    }

    private func nioHeaders(_ headers: [HTTPHeader]) -> HTTPHeaders {
        HTTPHeaders(headers.map { ($0.name, $0.value) })
    }

    private func responseMayHaveBody(
        method: HTTPMethod,
        status: HTTPResponseStatus
    ) -> Bool {
        method != .HEAD &&
            !(100..<200).contains(Int(status.code)) &&
            status != .noContent &&
            status != .notModified
    }
}

private struct UpstreamResponse {
    let head: NIOHTTP1.HTTPResponseHead
    let body: ByteBuffer
}

private final class UpstreamResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let completion: (Result<UpstreamResponse, Error>) -> Void
    private var responseHead: NIOHTTP1.HTTPResponseHead?
    private var responseBody: ByteBuffer?
    private var completed = false

    init(completion: @escaping (Result<UpstreamResponse, Error>) -> Void) {
        self.completion = completion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            responseHead = head
            responseBody = context.channel.allocator.buffer(capacity: 0)
        case var .body(body):
            responseBody?.writeBuffer(&body)
        case .end:
            guard let head = responseHead, let body = responseBody else {
                finish(.failure(ProxyServerError.invalidRequest), context: context)
                return
            }
            finish(
                .success(UpstreamResponse(head: head, body: body)),
                context: context
            )
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error), context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            finish(.failure(ChannelError.eof), context: context)
        }
    }

    private func finish(
        _ result: Result<UpstreamResponse, Error>,
        context: ChannelHandlerContext
    ) {
        guard !completed else { return }
        completed = true
        completion(result)
        context.close(promise: nil)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}
