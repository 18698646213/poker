import AppKit
import Darwin
import Foundation
import PokerCore
import UniformTypeIdentifiers

struct SessionDomainGroup: Identifiable {
    let domain: String
    let sessions: [CaptureSession]

    var id: String { domain }
}

struct PendingIntercept {
    let intercepted: InterceptedSession
    let resume: (CaptureSession) -> Void
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
    @Published var exportSelections: Set<CaptureSession.ID> = []
    @Published var filter = ""
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var rules: [RewriteRule] = []
    @Published var interceptRequests = false {
        didSet {
            if !interceptRequests {
                releaseIntercepts(for: .request)
            }
            updateInterceptConfiguration()
        }
    }
    @Published var interceptResponses = false {
        didSet {
            if !interceptResponses {
                releaseIntercepts(for: .response)
            }
            updateInterceptConfiguration()
        }
    }
    @Published var interceptDomainText = "" {
        didSet {
            releaseInterceptsOutsideScope()
            updateInterceptConfiguration()
        }
    }
    @Published var weakNetworkEnabled = false {
        didSet { updateWeakNetworkConfiguration() }
    }
    @Published var uploadLimitKBps = 256 {
        didSet { updateWeakNetworkConfiguration() }
    }
    @Published var downloadLimitKBps = 256 {
        didSet { updateWeakNetworkConfiguration() }
    }
    @Published private(set) var pendingIntercepts:
        [CaptureSession.ID: PendingIntercept] = [:]
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

    var selectedSessionsForExport: [CaptureSession] {
        sessions.filter { exportSelections.contains($0.id) }
    }

    var pendingInterceptCount: Int {
        pendingIntercepts.count
    }

    func pendingIntercept(for id: CaptureSession.ID) -> PendingIntercept? {
        pendingIntercepts[id]
    }

    var certificateDownloadURL: String {
        guard localIPAddress != "未检测到局域网 IP" else {
            return "请先连接局域网"
        }
        return "http://" + localIPAddress + ":" + String(port) + "/cert"
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
            releaseAllIntercepts()
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
            updateInterceptConfiguration()
            updateWeakNetworkConfiguration()
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
        releaseAllIntercepts()
        sessions.removeAll()
        selection = nil
        exportSelections.removeAll()
    }

    func resolveIntercept(
        id: CaptureSession.ID,
        editedSession: CaptureSession? = nil
    ) {
        guard let pending = pendingIntercepts.removeValue(forKey: id) else {
            return
        }
        pending.resume(editedSession ?? pending.intercepted.session)
    }

    func releaseAllIntercepts() {
        let pending = pendingIntercepts.values
        pendingIntercepts.removeAll()
        for intercept in pending {
            intercept.resume(intercept.intercepted.session)
        }
    }

    private func releaseIntercepts(for phase: InterceptPhase) {
        let matching = pendingIntercepts.values.filter {
            $0.intercepted.phase == phase
        }
        for intercept in matching {
            pendingIntercepts.removeValue(forKey: intercept.intercepted.id)
            intercept.resume(intercept.intercepted.session)
        }
    }

    func copyCertificateURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            certificateDownloadURL,
            forType: .string
        )
    }

    func copyCURL(for session: CaptureSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            CURLExporter.command(for: session),
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

    private func updateInterceptConfiguration() {
        server.updateInterceptConfiguration(
            InterceptConfiguration(
                interceptRequests: interceptRequests,
                interceptResponses: interceptResponses,
                domains: interceptDomains
            )
        )
    }

    private func updateWeakNetworkConfiguration() {
        server.updateWeakNetworkConfiguration(
            WeakNetworkConfiguration(
                isEnabled: weakNetworkEnabled,
                uploadBytesPerSecond: max(1, uploadLimitKBps) * 1_024,
                downloadBytesPerSecond: max(1, downloadLimitKBps) * 1_024
            )
        )
    }

    private var interceptDomains: [String] {
        interceptDomainText
            .components(
                separatedBy: CharacterSet(charactersIn: ",;\n")
            )
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private func releaseInterceptsOutsideScope() {
        let configuration = InterceptConfiguration(domains: interceptDomains)
        let matching = pendingIntercepts.values.filter {
            !configuration.matches(url: $0.intercepted.session.url)
        }
        for intercept in matching {
            pendingIntercepts.removeValue(forKey: intercept.intercepted.id)
            intercept.resume(intercept.intercepted.session)
        }
    }

    func exportSelection() {
        guard !selectedSessionsForExport.isEmpty else {
            return
        }

        if selectedSessionsForExport.allSatisfy(isImageSession) {
            let alert = NSAlert()
            alert.messageText = "已选日志均为图片"
            alert.informativeText = "请选择导出图片文件，或保存为 Markdown URL 日志。"
            alert.addButton(withTitle: "保存图片")
            alert.addButton(withTitle: "保存 URL 日志")
            alert.addButton(withTitle: "取消")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                exportImages(selectedSessionsForExport)
            case .alertSecondButtonReturn:
                exportSelectedMarkdown()
            default:
                break
            }
            return
        }

        exportSelectedMarkdown()
    }

    func isImageSession(_ session: CaptureSession) -> Bool {
        imageType(for: session) != nil && !session.responseBody.isEmpty
    }

    func exportImage(_ session: CaptureSession) {
        guard let imageType = imageType(for: session),
              !session.responseBody.isEmpty
        else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [imageType]
        panel.nameFieldStringValue = imageFilename(for: session, type: imageType)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try session.responseBody.write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportSelectedMarkdown() {
        exportMarkdown(
            selectedSessionsForExport,
            filename: "poker-selected-\(selectedSessionsForExport.count).md"
        )
    }

    private func exportImages(_ sessions: [CaptureSession]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "保存"
        panel.message = "选择图片保存文件夹"
        guard panel.runModal() == .OK, let directoryURL = panel.url else {
            return
        }

        do {
            var reservedURLs: Set<URL> = []
            for session in sessions {
                guard let type = imageType(for: session) else {
                    continue
                }
                let filename = imageFilename(for: session, type: type)
                let url = uniqueFileURL(
                    in: directoryURL,
                    filename: filename,
                    reservedURLs: &reservedURLs
                )
                try session.responseBody.write(to: url, options: .atomic)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportMarkdown(
        _ sessions: [CaptureSession],
        filename: String
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText
        ]
        panel.nameFieldStringValue = filename
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try MarkdownExporter.data(for: sessions)
                .write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case let .inserted(session):
            guard session.method != "CONNECT" else {
                return
            }
            sessions.insert(session, at: 0)
            selection = selection ?? session.id
            flashDomain(for: session)
        case let .updated(session):
            guard let index = sessions.firstIndex(where: { $0.id == session.id }) else {
                return
            }
            sessions[index] = session
        case let .intercepted(intercepted, resume):
            if let index = sessions.firstIndex(where: {
                $0.id == intercepted.session.id
            }) {
                sessions[index] = intercepted.session
            } else {
                sessions.insert(intercepted.session, at: 0)
            }
            pendingIntercepts[intercepted.id] = PendingIntercept(
                intercepted: intercepted,
                resume: resume
            )
            selection = intercepted.id
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

    private func imageType(for session: CaptureSession) -> UTType? {
        if let contentType = session.responseHeaders.first(where: {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        })?.value.split(separator: ";").first,
        let type = UTType(mimeType: String(contentType)),
        type.conforms(to: .image) {
            return type
        }

        let pathExtension = URL(string: session.url)?.pathExtension ?? ""
        guard let type = UTType(filenameExtension: pathExtension),
              type.conforms(to: .image)
        else {
            return nil
        }
        return type
    }

    private func imageFilename(for session: CaptureSession, type: UTType) -> String {
        let sourceName = URL(string: session.url)?.lastPathComponent
            .removingPercentEncoding ?? ""
        let sourceURL = URL(fileURLWithPath: sourceName)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let filename = baseName.isEmpty ? "poker-image" : baseName
        let sourceExtension = sourceURL.pathExtension
        let pathExtension = type.preferredFilenameExtension
            ?? (sourceExtension.isEmpty ? "img" : sourceExtension)
        return "\(filename).\(pathExtension)"
    }

    private func uniqueFileURL(
        in directoryURL: URL,
        filename: String,
        reservedURLs: inout Set<URL>
    ) -> URL {
        let filenameURL = URL(fileURLWithPath: filename)
        let baseName = filenameURL.deletingPathExtension().lastPathComponent
        let pathExtension = filenameURL.pathExtension
        var suffix = 1

        while true {
            let candidateName = suffix == 1
                ? filename
                : "\(baseName)-\(suffix).\(pathExtension)"
            let candidateURL = directoryURL.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateURL.path),
               !reservedURLs.contains(candidateURL) {
                reservedURLs.insert(candidateURL)
                return candidateURL
            }
            suffix += 1
        }
    }
}
