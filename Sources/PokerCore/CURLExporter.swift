import Foundation

public enum CURLExporter {
    public static func command(for session: CaptureSession) -> String {
        var arguments = [
            "curl",
            "--request \(shellQuote(session.method))",
            shellQuote(session.url)
        ]

        arguments.append(contentsOf: session.requestHeaders.compactMap { header in
            guard !ignoredHeaderNames.contains(header.name.lowercased()) else {
                return nil
            }
            return "--header \(shellQuote("\(header.name): \(header.value)"))"
        })

        if !session.requestBody.isEmpty {
            if let text = String(data: session.requestBody, encoding: .utf8) {
                arguments.append("--data-raw \(shellQuote(text))")
            } else {
                let escapedBytes = session.requestBody
                    .map { String(format: "\\x%02X", $0) }
                    .joined()
                arguments.append("--data-binary $'\(escapedBytes)'")
            }
        }

        return arguments.joined(separator: " \\\n  ")
    }

    private static let ignoredHeaderNames: Set<String> = [
        "connection",
        "content-length",
        "host",
        "transfer-encoding"
    ]

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
