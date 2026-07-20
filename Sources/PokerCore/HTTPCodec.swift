import Foundation

public struct HTTPRequestHead: Equatable, Sendable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: [HTTPHeader]

    public init(
        method: String,
        target: String,
        version: String,
        headers: [HTTPHeader]
    ) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
    }

    public var isWebSocket: Bool {
        headers.contains {
            $0.name.caseInsensitiveCompare("Upgrade") == .orderedSame &&
                $0.value.caseInsensitiveCompare("websocket") == .orderedSame
        }
    }

    public var hostAndPort: (host: String, port: UInt16)? {
        if method == "CONNECT" {
            return Self.splitHostAndPort(target, defaultPort: 443)
        }

        if let url = URL(string: target), let host = url.host {
            return (host, UInt16(url.port ?? (url.scheme == "https" ? 443 : 80)))
        }

        guard let hostHeader = headers.first(where: {
            $0.name.caseInsensitiveCompare("Host") == .orderedSame
        }) else {
            return nil
        }
        return Self.splitHostAndPort(hostHeader.value, defaultPort: 80)
    }

    public var originFormTarget: String {
        guard let components = URLComponents(string: target),
              components.scheme != nil
        else {
            return target
        }
        let path = components.percentEncodedPath.isEmpty
            ? "/"
            : components.percentEncodedPath
        return components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    }

    public var displayURL: String {
        if method == "CONNECT" {
            return "https://\(target)"
        }
        if URL(string: target)?.scheme != nil {
            return target
        }
        let host = headers.first {
            $0.name.caseInsensitiveCompare("Host") == .orderedSame
        }?.value ?? ""
        return "http://\(host)\(target)"
    }

    public static func parse(_ data: Data) -> (head: HTTPRequestHead, body: Data)? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)),
              let text = String(
                data: data[..<boundary.lowerBound],
                encoding: .utf8
              )
        else {
            return nil
        }

        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count == 3 else {
            return nil
        }
        let headers = lines.dropFirst().compactMap(Self.parseHeader)
        let body = Data(data[boundary.upperBound...])
        let contentLength = headers.first {
            $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame
        }.flatMap { Int($0.value) } ?? 0
        guard body.count >= contentLength else {
            return nil
        }
        return (
            HTTPRequestHead(
                method: requestLine[0],
                target: requestLine[1],
                version: requestLine[2],
                headers: headers
            ),
            Data(body.prefix(contentLength))
        )
    }

    public func serialized(body: Data, closeConnection: Bool) -> Data {
        var outputHeaders = headers.filter {
            $0.name.caseInsensitiveCompare("Proxy-Connection") != .orderedSame &&
                $0.name.caseInsensitiveCompare("Connection") != .orderedSame
        }
        if closeConnection {
            outputHeaders.append(HTTPHeader(name: "Connection", value: "close"))
        } else if isWebSocket {
            outputHeaders.append(HTTPHeader(name: "Connection", value: "Upgrade"))
        }

        var text = "\(method) \(originFormTarget) \(version)\r\n"
        for header in outputHeaders {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8) + body
    }

    private static func parseHeader(_ line: String) -> HTTPHeader? {
        guard let colon = line.firstIndex(of: ":") else {
            return nil
        }
        return HTTPHeader(
            name: String(line[..<colon]),
            value: String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        )
    }

    private static func splitHostAndPort(
        _ value: String,
        defaultPort: UInt16
    ) -> (host: String, port: UInt16)? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard let host = parts.first, !host.isEmpty else {
            return nil
        }
        let port = parts.count == 2 ? UInt16(parts[1]) : defaultPort
        guard let port else {
            return nil
        }
        return (host, port)
    }
}

public struct HTTPResponseHead: Equatable, Sendable {
    public var version: String
    public var statusCode: Int
    public var reason: String
    public var headers: [HTTPHeader]

    public static func parse(_ data: Data) -> (head: HTTPResponseHead, body: Data)? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)),
              let text = String(data: data[..<boundary.lowerBound], encoding: .utf8)
        else {
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
        guard statusLine.count >= 2, let statusCode = Int(statusLine[1]) else {
            return nil
        }
        let headers = lines.dropFirst().compactMap { line -> HTTPHeader? in
            guard let colon = line.firstIndex(of: ":") else {
                return nil
            }
            return HTTPHeader(
                name: String(line[..<colon]),
                value: String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            )
        }
        let encodedBody = Data(data[boundary.upperBound...])
        let isChunked = headers.contains {
            $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame &&
                $0.value.localizedCaseInsensitiveContains("chunked")
        }
        let body = isChunked
            ? decodeChunkedBody(encodedBody) ?? encodedBody
            : encodedBody
        return (
            HTTPResponseHead(
                version: statusLine[0],
                statusCode: statusCode,
                reason: statusLine.count == 3 ? statusLine[2] : "",
                headers: headers
            ),
            body
        )
    }

    public static func isCompleteMessage(_ data: Data) -> Bool {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)),
              let parsed = parse(data)
        else {
            return false
        }
        if (100..<200).contains(parsed.head.statusCode) ||
            parsed.head.statusCode == 204 ||
            parsed.head.statusCode == 304 {
            return true
        }

        let encodedBody = Data(data[boundary.upperBound...])
        if let contentLength = parsed.head.headers.first(where: {
            $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame
        }).flatMap({ Int($0.value) }) {
            return encodedBody.count >= contentLength
        }

        let isChunked = parsed.head.headers.contains {
            $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame &&
                $0.value.localizedCaseInsensitiveContains("chunked")
        }
        return isChunked && decodeChunkedBody(encodedBody) != nil
    }

    public func serialized(body: Data) -> Data {
        var outputHeaders = headers.filter {
            $0.name.caseInsensitiveCompare("Content-Length") != .orderedSame &&
                $0.name.caseInsensitiveCompare("Transfer-Encoding") != .orderedSame
        }
        outputHeaders.append(
            HTTPHeader(name: "Content-Length", value: String(body.count))
        )
        outputHeaders.append(HTTPHeader(name: "Connection", value: "close"))

        var text = "\(version) \(statusCode) \(reason)\r\n"
        for header in outputHeaders {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8) + body
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        var cursor = data.startIndex
        var output = Data()

        while cursor < data.endIndex {
            guard let lineEnd = data.range(
                of: Data("\r\n".utf8),
                in: cursor..<data.endIndex
            ),
            let sizeLine = String(
                data: data[cursor..<lineEnd.lowerBound],
                encoding: .utf8
            ),
            let size = Int(sizeLine.split(separator: ";")[0], radix: 16)
            else {
                return nil
            }
            cursor = lineEnd.upperBound
            if size == 0 {
                guard data.distance(from: cursor, to: data.endIndex) >= 2 else {
                    return nil
                }
                return output
            }
            guard data.distance(from: cursor, to: data.endIndex) >= size + 2 else {
                return nil
            }
            let chunkEnd = data.index(cursor, offsetBy: size)
            output.append(data[cursor..<chunkEnd])
            cursor = data.index(chunkEnd, offsetBy: 2)
        }
        return nil
    }
}
