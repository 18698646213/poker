import AppKit
import Darwin
import Foundation
import PokerCore

struct SessionDomainGroup: Identifiable {
    let domain: String
    let sessions: [CaptureSession]

    var id: String { domain }
}

@MainActor
final class CaptureViewModel: ObservableObject {
    private enum ConfigurationError: LocalizedError {
        case invalidPort

        var errorDescription: String? {
            "端口必须是 1 到 65535 之间的整数"
        }
    }

    @Published var sessions: [CaptureSession] = []
    @Published var selection: CaptureSession.ID?
    @Published var filter = ""
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var rules: [RewriteRule] = []
    @Published var port = UserDefaults.standard.integer(forKey: "proxyPort")
    @Published private(set) var localIPAddress = "未检测到局域网 IP"
    @Published private(set) var highlightedDomains: Set<String> = []

    private var domainHighlightTokens: [String: UUID] = [:]
    init() {
        if port == 0 {
            port = 8888
        }
        refreshLocalIPAddress()
    }

    private lazy var server = ProxyServer { [weak self] event in
        Task { @MainActor [weak self] in
            self?.apply(event)
        }
    }

    var filteredSessions: [CaptureSession] {
        guard !filter.isEmpty else {
            return sessions
        }
        return sessions.filter {
            $0.url.localizedCaseInsensitiveContains(filter) ||
                $0.method.localizedCaseInsensitiveContains(filter) ||
                String($0.statusCode ?? 0).contains(filter)
        }
    }

    var selectedSession: CaptureSession? {
        sessions.first { $0.id == selection }
    }

    var certificateDownloadURL: String {
        guard localIPAddress != "未检测到局域网 IP" else {
            return "请先连接局域网"
        }
        return "http://\(localIPAddress):\(port)/cert"
    }

    var groupedSessions: [SessionDomainGroup] {
        Dictionary(grouping: filteredSessions, by: Self.domain)
            .map { SessionDomainGroup(domain: $0.key, sessions: $0.value) }
            .sorted {
                ($0.sessions.first?.startedAt ?? .distantPast)
                    > ($1.sessions.first?.startedAt ?? .distantPast)
            }
    }

    func toggleServer() {
        if isRunning {
            server.stop()
            isRunning = false
            return
        }
        do {
            guard let networkPort = UInt16(exactly: port), networkPort > 0 else {
                throw ConfigurationError.invalidPort
            }
            try server.start(port: networkPort)
            server.updateRules(rules)
            UserDefaults.standard.set(port, forKey: "proxyPort")
            refreshLocalIPAddress()
            isRunning = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshLocalIPAddress() {
        localIPAddress = Self.localIPv4Address() ?? "未检测到局域网 IP"
    }

    func clear() {
        sessions.removeAll()
        selection = nil
    }

    func copyCertificateURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            certificateDownloadURL,
            forType: .string
        )
    }

    func addRule() {
        rules.append(
            RewriteRule(
                name: "新规则",
                field: .url,
                pattern: "example\\.com",
                replacement: "localhost"
            )
        )
        server.updateRules(rules)
    }

    func removeRules(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        server.updateRules(rules)
    }

    func rulesDidChange() {
        server.updateRules(rules)
    }

    func exportHAR() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "poker-session.har"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try HARExporter.data(for: sessions).write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case let .inserted(session):
            sessions.insert(session, at: 0)
            selection = selection ?? session.id
            flashDomain(for: session)
        case let .updated(session):
            guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
                return
            }
            sessions[index] = session
        }
    }

    private func flashDomain(for session: CaptureSession) {
        let domain = Self.domain(for: session)
        let token = UUID()
        domainHighlightTokens[domain] = token
        highlightedDomains.insert(domain)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self, self.domainHighlightTokens[domain] == token else {
                return
            }
            self.highlightedDomains.remove(domain)
            self.domainHighlightTokens.removeValue(forKey: domain)
        }
    }

    private static func localIPv4Address() -> String? {
        var firstAddress: String?
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let firstInterface = interfacePointer else {
            return nil
        }
        defer {
            freeifaddrs(interfacePointer)
        }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = pointer {
            defer {
                pointer = interface.pointee.ifa_next
            }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  interface.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }

            let value = String(cString: host)
            let name = String(cString: interface.pointee.ifa_name)
            if name == "en0" {
                return value
            }
            firstAddress = firstAddress ?? value
        }
        return firstAddress
    }

    private static func domain(for session: CaptureSession) -> String {
        URLComponents(string: session.url)?.host ?? "未知域名"
    }
}
