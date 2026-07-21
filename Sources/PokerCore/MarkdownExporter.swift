import Foundation

public enum MarkdownExporter {
    public static func data(for sessions: [CaptureSession]) -> Data {
        let dateFormatter = ISO8601DateFormatter()
        let entries = sessions.enumerated().map { index, session in
            entry(
                for: session,
                index: index + 1,
                dateFormatter: dateFormatter
            )
        }
        let markdown = """
        # Poker 日志

        > 导出时间：\(dateFormatter.string(from: Date()))  
        > 日志数量：\(sessions.count)

        \(entries.joined(separator: "\n\n---\n\n"))
        """
        return Data(markdown.utf8)
    }

    private static func entry(
        for session: CaptureSession,
        index: Int,
        dateFormatter: ISO8601DateFormatter
    ) -> String {
        let statusCode = session.statusCode.map(String.init) ?? "—"
        let duration = session.duration.map {
            "\(Int($0 * 1_000)) ms"
        } ?? "—"
        return """
        ## \(index). \(session.method) \(session.url)

        - 状态码：\(statusCode)
        - 开始时间：\(dateFormatter.string(from: session.startedAt))
        - 耗时：\(duration)
        - 状态：\(session.state.rawValue)

        ### 请求头

        \(codeBlock(headersText(session.requestHeaders)))

        ### 请求体

        \(codeBlock(bodyText(session.requestBody)))

        ### 响应头

        \(codeBlock(headersText(session.responseHeaders)))

        ### 响应体

        \(codeBlock(bodyText(session.responseBody)))
        """
    }

    private static func headersText(_ headers: [HTTPHeader]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    private static func bodyText(_ body: Data) -> String {
        guard !body.isEmpty else {
            return ""
        }
        return String(data: body, encoding: .utf8)
            ?? "二进制数据（\(body.count) 字节）"
    }

    private static func codeBlock(_ text: String) -> String {
        guard !text.isEmpty else {
            return "（空）"
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }
}
