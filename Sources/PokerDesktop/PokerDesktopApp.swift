import AppKit
import PokerCore
import SwiftUI

#Preview {
    ContentView()
        .environmentObject(CaptureViewModel())
}

@main
struct PokerDesktopApp: App {
    @StateObject private var model = CaptureViewModel()

    init() {
        if let iconURL = Bundle.main.url(
            forResource: "AppIcon",
            withExtension: "icns"
        ),
        let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

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

                Button("导出已选…") {
                    model.exportSelection()
                }
                .disabled(model.exportSelections.isEmpty)
                .keyboardShortcut("e", modifiers: [.command])
            }
            UserGuideCommands()
        }

        Window("Poker 使用说明", id: "user-guide") {
            UserGuideView()
                .environmentObject(model)
        }
    }
}

private struct UserGuideCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Poker 使用说明") {
                openWindow(id: "user-guide")
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
    }
}

private struct UserGuideView: View {
    @EnvironmentObject private var model: CaptureViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Poker 使用说明", systemImage: "questionmark.circle")
                    .font(.largeTitle.bold())

                guideSection("开始抓包", systemImage: "play.circle") {
                    Text("1. 点击工具栏“启动”，开启本机代理。")
                    Text("2. 将待抓包设备与 Mac 连接到同一 Wi-Fi。")
                    Text("3. 在设备的 Wi-Fi 设置中，将 HTTP 代理设为“手动”：")
                    addressView
                    Text("4. 打开目标 App 或网页，请求会自动显示在主窗口。")
                }

                guideSection("抓取 HTTPS", systemImage: "lock.shield") {
                    Text("点击工具栏“安装证书”，按照页面提示在测试设备上下载、安装并完全信任 Poker Local CA。")
                    Text("证书固定（Certificate Pinning）的 App 无法通过 Poker 解密。")
                        .foregroundStyle(.secondary)
                }

                guideSection("查看与筛选", systemImage: "list.bullet.rectangle") {
                    Text("展开域名后选择请求，可查看请求头、请求体、响应头和响应体。")
                    Text("使用列表上方的搜索框，可按 URL、HTTP 方法或状态码筛选。")
                }

                guideSection("重写与导出", systemImage: "arrow.triangle.2.circlepath") {
                    Text("“重写规则”支持用正则表达式修改 URL、请求头、响应头和响应体。")
                    Text("开启“请求拦截”或“响应拦截”后，可在详情区修改数据并手动放行。")
                    Text("“拦截范围”可按域名限制需要拦截的接口，留空时拦截全部域名。")
                    Text("“弱网模式”可分别限制请求上传和响应下载速度。")
                    Text("勾选多条请求后，点击“导出已选”可批量保存为一个 Markdown 文件。")
                    Text("若勾选项全部为图片，可选择保存图片文件或 Markdown URL 日志；混合类型直接保存日志。")
                }

                Label(
                    "仅在你拥有或获准测试的设备与网络上使用。抓包结束后，请关闭设备代理并删除不再需要的根证书。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560)
    }

    private var addressView: some View {
        Text(model.localIPAddress + ":" + String(model.port))
            .font(.system(.body, design: .monospaced).bold())
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func guideSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.title3.bold())
            content()
        }
    }
}

private struct ContentView: View {
    @EnvironmentObject private var model: CaptureViewModel
    @State private var showingRules = false
    @State private var showingCertificateSetup = false
    @State private var showingInterceptSettings = false
    @State private var showingWeakNetworkSettings = false
    @State private var expandedDomains: Set<String> = []

    var body: some View {
        NavigationSplitView {
            sessionList
                .navigationSplitViewColumnWidth(min: 330, ideal: 420)
        } detail: {
            if let selection = model.selection,
               let pending = model.pendingIntercept(for: selection) {
                InterceptEditorView(
                    pending: pending,
                    onApply: { editedSession in
                        model.resolveIntercept(
                            id: pending.intercepted.id,
                            editedSession: editedSession
                        )
                    },
                    onForward: {
                        model.resolveIntercept(id: pending.intercepted.id)
                    }
                )
                .id(
                    "\(pending.intercepted.id)-\(pending.intercepted.phase.rawValue)"
                )
            } else if let session = model.selectedSession {
                SessionDetail(
                    session: session,
                    onExportImage: model.isImageSession(session)
                        ? { model.exportImage(session) }
                        : nil
                )
            } else {
                ContentUnavailableView(
                    "暂无请求",
                    systemImage: "network",
                    description: Text(
                        verbatim: "启动代理后，将手机代理设置为 " +
                            model.localIPAddress + ":" + String(model.port)
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
                    model.interceptRequests.toggle()
                } label: {
                    Text(
                        model.interceptRequests
                            ? "请求拦截：开"
                            : "请求拦截：关"
                    )
                }
                .buttonStyle(.bordered)
                .tint(model.interceptRequests ? .orange : nil)

                Button {
                    model.interceptResponses.toggle()
                } label: {
                    Text(
                        model.interceptResponses
                            ? "响应拦截：开"
                            : "响应拦截：关"
                    )
                }
                .buttonStyle(.bordered)
                .tint(model.interceptResponses ? .orange : nil)

                if model.pendingInterceptCount > 0 {
                    Text("待处理 \(model.pendingInterceptCount)")
                        .foregroundStyle(.orange)
                }

                Button("拦截范围") {
                    showingInterceptSettings = true
                }

                Button(
                    model.weakNetworkEnabled
                        ? "弱网：开"
                        : "弱网：关"
                ) {
                    showingWeakNetworkSettings = true
                }
                .buttonStyle(.bordered)
                .tint(model.weakNetworkEnabled ? .orange : nil)

                Button {
                    showingRules = true
                } label: {
                    Label("重写规则", systemImage: "arrow.triangle.2.circlepath")
                }

//                Button {
//                    showingCertificateSetup = true
//                } label: {
//                    Label("安装证书", systemImage: "checkmark.shield")
//                }

                Button {
                    model.clear()
                } label: {
                    Label("清空", systemImage: "trash")
                }

                Button {
                    model.exportSelection()
                } label: {
                    Label(
                        model.exportSelections.isEmpty
                            ? "导出已选"
                            : "导出已选 (\(model.exportSelections.count))",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .disabled(model.exportSelections.isEmpty)
            }
        }
        .sheet(isPresented: $showingRules) {
            RulesView()
                .environmentObject(model)
        }
        // .sheet(isPresented: $showingCertificateSetup) {
        //     CertificateSetupView()
        //         .environmentObject(model)
        // }
        .sheet(isPresented: $showingInterceptSettings) {
            InterceptSettingsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showingWeakNetworkSettings) {
            WeakNetworkSettingsView()
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
                            SessionRow(
                                session: session,
                                isSelectedForExport: Binding(
                                    get: {
                                        model.exportSelections.contains(session.id)
                                    },
                                    set: { isSelected in
                                        if isSelected {
                                            model.exportSelections.insert(session.id)
                                        } else {
                                            model.exportSelections.remove(session.id)
                                        }
                                    }
                                ),
                                interceptPhase: model.pendingIntercept(
                                    for: session.id
                                )?.intercepted.phase,
                                onCopyCURL: {
                                    model.copyCURL(for: session)
                                },
                                onExportImage: model.isImageSession(session)
                                    ? { model.exportImage(session) }
                                    : nil
                            )
                                .tag(session.id)
                        }
                    }
                }
            }
            .searchable(
                text: $model.filter,
                placement: .sidebar,
                prompt: "URL、方法或状态码"
            )
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
    @Binding var isSelectedForExport: Bool
    let interceptPhase: InterceptPhase?
    let onCopyCURL: () -> Void
    let onExportImage: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Toggle("选择导出", isOn: $isSelectedForExport)
                .labelsHidden()
                .toggleStyle(.checkbox)

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
                    if let interceptPhase {
                        Text(
                            interceptPhase == .request
                                ? "等待请求"
                                : "等待响应"
                        )
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                    }
                    if let onExportImage {
                        Button(action: onExportImage) {
                            Image(systemName: "arrow.down.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("导出图片")
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
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("复制为 cURL", systemImage: "terminal") {
                onCopyCURL()
            }
        }
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

private struct EditableQueryItem: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}

private struct InterceptEditorView: View {
    let pending: PendingIntercept
    let onApply: (CaptureSession) -> Void
    let onForward: () -> Void

    @State private var draft: CaptureSession
    @State private var queryItems: [EditableQueryItem]
    @State private var requestBodyText: String
    @State private var responseBodyText: String

    init(
        pending: PendingIntercept,
        onApply: @escaping (CaptureSession) -> Void,
        onForward: @escaping () -> Void
    ) {
        self.pending = pending
        self.onApply = onApply
        self.onForward = onForward

        let session = pending.intercepted.session
        _draft = State(initialValue: session)
        _queryItems = State(
            initialValue: URLComponents(string: session.url)?
                .queryItems?
                .map {
                    EditableQueryItem(
                        name: $0.name,
                        value: $0.value ?? ""
                    )
                } ?? []
        )
        _requestBodyText = State(
            initialValue: String(
                data: session.requestBody,
                encoding: .utf8
            ) ?? ""
        )
        _responseBodyText = State(
            initialValue: String(
                data: session.responseBody,
                encoding: .utf8
            ) ?? ""
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(
                    phase == .request ? "请求已拦截" : "响应已拦截",
                    systemImage: "pause.circle.fill"
                )
                .font(.title2.bold())
                .foregroundStyle(.orange)
                Spacer()
                Text("客户端正在等待")
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if phase == .request {
                        requestEditor
                    } else {
                        responseEditor
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Button("原样放行") {
                    onForward()
                }
                Spacer()
                Button("应用修改并放行") {
                    apply()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private var phase: InterceptPhase {
        pending.intercepted.phase
    }

    private var requestEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            editorSection("请求") {
                HStack {
                    TextField("方法", text: $draft.method)
                        .frame(width: 90)
                    TextField("URL", text: $draft.url)
                        .font(.system(.body, design: .monospaced))
                }
            }

            editorSection("Query 参数") {
                ForEach($queryItems) { $item in
                    HStack {
                        TextField("名称", text: $item.name)
                        TextField("值", text: $item.value)
                        Button {
                            queryItems.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("添加参数", systemImage: "plus") {
                    queryItems.append(
                        EditableQueryItem(name: "", value: "")
                    )
                }
            }

            headerEditor(
                title: "请求头",
                headers: $draft.requestHeaders
            )
            bodyEditor(title: "请求体", text: $requestBodyText)
        }
    }

    private var responseEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            editorSection("响应") {
                HStack {
                    Text("状态码")
                    TextField(
                        "200",
                        text: Binding(
                            get: {
                                draft.statusCode.map(String.init) ?? ""
                            },
                            set: { draft.statusCode = Int($0) }
                        )
                    )
                    .frame(width: 90)
                }
                Text(draft.url)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            headerEditor(
                title: "响应头",
                headers: $draft.responseHeaders
            )
            bodyEditor(title: "响应体", text: $responseBodyText)
        }
    }

    private func headerEditor(
        title: String,
        headers: Binding<[HTTPHeader]>
    ) -> some View {
        editorSection(title) {
            ForEach(headers.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField("名称", text: headers[index].name)
                        .frame(width: 180)
                    TextField("值", text: headers[index].value)
                    Button {
                        headers.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("添加 Header", systemImage: "plus") {
                headers.wrappedValue.append(
                    HTTPHeader(name: "", value: "")
                )
            }
        }
    }

    private func bodyEditor(
        title: String,
        text: Binding<String>
    ) -> some View {
        editorSection(title) {
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .padding(6)
                .background(
                    .quaternary,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
    }

    private func editorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func apply() {
        var edited = draft
        if phase == .request {
            if var components = URLComponents(string: edited.url) {
                components.queryItems = queryItems.isEmpty
                    ? nil
                    : queryItems.map {
                        URLQueryItem(name: $0.name, value: $0.value)
                    }
                edited.url = components.url?.absoluteString ?? edited.url
            }
            edited.requestBody = Data(requestBodyText.utf8)
        } else {
            edited.responseBody = Data(responseBodyText.utf8)
        }
        onApply(edited)
    }
}

private struct SessionDetail: View {
    let session: CaptureSession
    let onExportImage: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(session.method)
                        .font(.headline)
                    Text(session.url)
                        .textSelection(.enabled)
                    Spacer()
                    if let onExportImage {
                        Button("导出图片", systemImage: "arrow.down.circle") {
                            onExportImage()
                        }
                    }
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

private struct InterceptSettingsView: View {
    @EnvironmentObject private var model: CaptureViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("每行填写一个域名，也可使用逗号或分号分隔。匹配该域名及其所有子域名。")
                    .foregroundStyle(.secondary)

                TextEditor(text: $model.interceptDomainText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .padding(6)
                    .background(
                        .quaternary,
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                Text(
                    model.interceptDomainText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                        ? "当前范围：全部域名"
                        : "当前范围：指定域名"
                )
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(minWidth: 520, minHeight: 340)
            .navigationTitle("拦截范围")
            .toolbar {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }
}

private struct WeakNetworkSettingsView: View {
    @EnvironmentObject private var model: CaptureViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Toggle("启用弱网模式", isOn: $model.weakNetworkEnabled)

                LabeledContent("上传速度") {
                    HStack {
                        TextField(
                            "256",
                            value: $model.uploadLimitKBps,
                            format: .number.grouping(.never)
                        )
                        .frame(width: 110)
                        Text("KB/s")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("下载速度") {
                    HStack {
                        TextField(
                            "256",
                            value: $model.downloadLimitKBps,
                            format: .number.grouping(.never)
                        )
                        .frame(width: 110)
                        Text("KB/s")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("限速对新的请求和响应立即生效，速度最小按 1 KB/s 处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding()
            .frame(minWidth: 460, minHeight: 300)
            .navigationTitle("弱网模式")
            .toolbar {
                Button("完成") {
                    dismiss()
                }
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
