import Foundation

public struct RewriteRule: Identifiable, Codable, Hashable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case url
        case requestHeader
        case responseHeader
        case responseBody
    }

    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var field: Field
    public var pattern: String
    public var replacement: String

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        field: Field,
        pattern: String,
        replacement: String
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.field = field
        self.pattern = pattern
        self.replacement = replacement
    }

    public func replacing(_ value: String) -> String {
        guard isEnabled,
              let expression = try? NSRegularExpression(pattern: pattern)
        else {
            return value
        }

        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }
}

public struct RewriteEngine: Sendable {
    public var rules: [RewriteRule]

    public init(rules: [RewriteRule] = []) {
        self.rules = rules
    }

    public func rewriteURL(_ url: String) -> String {
        rules
            .filter { $0.field == .url }
            .reduce(url) { value, rule in rule.replacing(value) }
    }

    public func rewriteHeaders(
        _ headers: [HTTPHeader],
        field: RewriteRule.Field
    ) -> [HTTPHeader] {
        rules
            .filter { $0.field == field }
            .reduce(headers) { current, rule in
                current.map {
                    HTTPHeader(
                        name: $0.name,
                        value: rule.replacing($0.value)
                    )
                }
            }
    }

    public func rewriteResponseBody(_ body: Data) -> Data {
        guard var value = String(data: body, encoding: .utf8) else {
            return body
        }
        for rule in rules where rule.field == .responseBody {
            value = rule.replacing(value)
        }
        return Data(value.utf8)
    }
}
