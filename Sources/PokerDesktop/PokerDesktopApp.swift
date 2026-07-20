import PokerCore
import SwiftUI

#Preview {
    ContentView()
        .environmentObject(CaptureViewModel())
}

@main
struct PokerDesktopApp: App {
    @StateObject private var model = CaptureViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1300, minHeight: 760)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRunning ? "停止代理" : "启动代理") {
                    model.toggleServer()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("导出 HAR…") {
                    model.exportHAR()
                }
                .keyboardShortcut("e", modifiers: [.command])
            }
        }
    }
}

private struct ContentView: View {
    @EnvironmentObject private var model: CaptureViewModel
    @State private var showingRules = false
    @State private var showingCertificateSetup = false
    @State private var expandedDomains: Set<String> = []

    var body: some View {
        NavigationSplitView {
            sessionList
                .navigationSplitViewColumnWidth(min: 330, ideal: 420)
        } detail: {
            if let session = model.selectedSession {
                SessionDetail(session: session)
            } else {
                ContentUnavailableView(
                    "暂无请求",
                    systemImage: "network",
                    description: Text(
                        "启动代理后，将手机代理设置为 \(model.localIPAddress):\(model.port)"
                    )
                )
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.toggleServer()
                } label: {
                    Label(
                        model.isRunning ? "停止" : "启动",
                        systemImage: model.isRunning ? "stop.fill" : "play.fill"
                    )
                }
                .tint(model.isRunning ? .red : .green)

                Button {
                    showingRules = true
                } label: {
                    Label("重写规则", systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    showingCertificateSetup = true
                } label: {
                    Label("安装证书", systemImage: "checkmark.shield")
                }

                Button {
                    model.clear()
                } label: {
                    Label("清空", systemImage: "trash")
                }

                Button {
                    model.exportHAR()
                } label: {
                    Label("导出 HAR", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingRules) {
            RulesView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showingCertificateSetup) {
            CertificateSetupView()
                .environmentObject(model)
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好") {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(model.isRunning ? .green : .secondary)
                    .frame(width: 9, height: 9)
                Text(
                    model.isRunning
                        ? "代理运行中"
                        : "代理已停止"
                )
                .font(.caption)
                Divider()
                    .frame(height: 14)
                Text(model.localIPAddress)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(":")
                    .font(.caption)
                TextField(
                    "端口",
                    value: $model.port,
                    format: .number.grouping(.never)
                )
                    .font(.caption.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .disabled(model.isRunning)
                    .help(model.isRunning ? "停止代理后可修改端口" : "代理监听端口")
                Button {
                    model.refreshLocalIPAddress()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("重新检测局域网 IP")
                Spacer()
                Text("\(model.sessions.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 9)

            Divider()

            List(selection: $model.selection) {
                ForEach(model.groupedSessions) { group in
                    Button {
                        toggleDomainExpansion(group.domain)
                    } label: {
                        HStack {
                            Image(
                                systemName: expandedDomains.contains(group.domain)
                                    ? "chevron.down"
                                    : "chevron.right"
                            )
                            Image(systemName: "globe")
                            Text(group.domain)
                            Spacer()
                            Text("\(group.sessions.count)")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(
                                    model.highlightedDomains.contains(group.domain)
                                        ? Color.accentColor.opacity(0.35)
                                        : .clear
                                )
                        )
                        .animation(
                            .easeInOut(duration: 0.2),
                            value: model.highlightedDomains.contains(group.domain)
                        )
                    }
                    .buttonStyle(.plain)

                    if expandedDomains.contains(group.domain) {
                        ForEach(group.sessions) { session in
                            SessionRow(session: session)
                                .tag(session.id)
                        }
                    }
                }
            }
            .searchable(text: $model.filter, prompt: "URL、方法或状态码")
        }
    }

    private func toggleDomainExpansion(_ domain: String) {
        if expandedDomains.contains(domain) {
            expandedDomains.remove(domain)
        } else {
            expandedDomains.insert(domain)
        }
    }
}

private struct SessionRow: View {
    let session: CaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(session.method)
                    .font(.caption.bold())
                    .foregroundStyle(methodColor)
                Text(session.url)
                    .lineLimit(1)
                Spacer()
                if session.isWebSocket {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(.purple)
                }
            }
            HStack {
                Text(session.statusCode.map(String.init) ?? "…")
                    .foregroundStyle(statusColor)
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(session.responseBody.count),
                    countStyle: .file
                ))
                Spacer()
                if let duration = session.duration {
                    Text("\(Int(duration * 1_000)) ms")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var methodColor: Color {
        switch session.method {
        case "GET": .blue
        case "POST": .green
        case "DELETE": .red
        default: .orange
        }
    }

    private var statusColor: Color {
        guard let status = session.statusCode else {
            return .secondary
        }
        return status < 400 ? .green : .red
    }
}

private struct SessionDetail: View {
    let session: CaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(session.method)
                        .font(.headline)
                    Text(session.url)
                        .textSelection(.enabled)
                }
                if let error = session.errorDescription {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .padding()

            Divider()

            if session.method == "CONNECT" {
                ContentUnavailableView {
                    Label("HTTPS 隧道已建立", systemImage: "lock.open.fill")
                } description: {
                    Text(
                        "MITM 解密后的具体请求会作为该域名下的独立接口显示。若没有出现，请确认手机已安装并完全信任 Poker 根证书。"
                    )
                }
            } else {
                TabView {
                    MessageView(
                        headers: session.requestHeaders,
                        payload: session.requestBody
                    )
                    .tabItem { Text("请求") }

                    MessageView(
                        headers: session.responseHeaders,
                        payload: session.responseBody
                    )
                    .tabItem { Text("响应") }

                    Text(session.url)
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .padding()
                        .tabItem { Text("概览") }
                }
                .padding()
            }
        }
    }
}

private struct CertificateSetupView: View {
    @EnvironmentObject private var model: CaptureViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label("在 iPhone 上安装 Poker CA", systemImage: "iphone")
                    .font(.title2.bold())

                Text("1. 保持手机与 Mac 在同一 Wi-Fi，并先配置 Poker 代理。")
                Text("2. 用手机 Safari 打开下面的地址并允许下载描述文件。")

                HStack {
                    Text(model.certificateDownloadURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("复制") {
                        model.copyCertificateURL()
                    }
                }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                Text("3. 前往“设置 → 通用 → VPN 与设备管理”安装描述文件。")
                Text("4. 前往“设置 → 通用 → 关于本机 → 证书信任设置”，打开对 Poker Local CA 的完全信任。")

                Label(
                    "只在测试设备安装。完成抓包后应删除该证书。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)

                Spacer()
            }
            .padding(24)
            .frame(minWidth: 620, minHeight: 420)
            .navigationTitle("HTTPS 解密证书")
            .toolbar {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }
}

private struct MessageView: View {
    let headers: [HTTPHeader]
    let payload: Data

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Headers")
                    .font(.headline)
                if headers.isEmpty {
                    Text("（空）")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(headers, id: \.self) { header in
                            GridRow {
                                Text(header.name)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 170, alignment: .trailing)
                                Text(header.value)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                Divider()
                Text("Body")
                    .font(.headline)
                Text(bodyText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }

    private var bodyText: String {
        if payload.isEmpty {
            return "（空）"
        }
        if let text = String(data: payload, encoding: .utf8) {
            return text
        }
        return """
        二进制数据（\(payload.count) 字节，以下为完整十六进制内容）

        \(hexDump)
        """
    }

    private var hexDump: String {
        let bytes = [UInt8](payload)
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let end = min(offset + 16, bytes.count)
            let line = bytes[offset..<end]
            let hexadecimal = line
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
                .padding(
                    toLength: 47,
                    withPad: " ",
                    startingAt: 0
                )
            let characters = line.map {
                (32...126).contains($0) ? String(UnicodeScalar($0)) : "."
            }
            .joined()
            return String(format: "%08X", offset) +
                "  \(hexadecimal)  |\(characters)|"
        }
        .joined(separator: "\n")
    }
}

private struct RulesView: View {
    @EnvironmentObject private var model: CaptureViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach($model.rules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("", isOn: $rule.isEnabled)
                                .labelsHidden()
                            TextField("名称", text: $rule.name)
                            Picker("字段", selection: $rule.field) {
                                ForEach(RewriteRule.Field.allCases, id: \.self) {
                                    Text(fieldName($0)).tag($0)
                                }
                            }
                            .frame(width: 150)
                        }
                        TextField("正则表达式", text: $rule.pattern)
                            .font(.system(.body, design: .monospaced))
                        TextField("替换内容", text: $rule.replacement)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.vertical, 6)
                    .onChange(of: rule) {
                        model.rulesDidChange()
                    }
                }
                .onDelete(perform: model.removeRules)
            }
            .navigationTitle("重写规则")
            .frame(minWidth: 650, minHeight: 400)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("添加", systemImage: "plus") {
                        model.addRule()
                    }
                }
            }
        }
    }

    private func fieldName(_ field: RewriteRule.Field) -> String {
        switch field {
        case .url: "URL"
        case .requestHeader: "请求头"
        case .responseHeader: "响应头"
        case .responseBody: "响应体"
        }
    }
}
