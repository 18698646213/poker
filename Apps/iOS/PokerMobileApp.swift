import PokerCore
import SwiftUI

@main
struct PokerMobileApp: App {
    var body: some Scene {
        WindowGroup {
            MobileSetupView()
        }
    }
}

private struct MobileSetupView: View {
    @AppStorage("proxyHost") private var proxyHost = ""
    @AppStorage("proxyPort") private var proxyPort = 8888
    @State private var showingTunnelHelp = false
    @State private var connectionStatus = "未测试"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Mac 局域网 IP", text: $proxyHost)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", value: $proxyPort, format: .number)
                        .keyboardType(.numberPad)
                } header: {
                    Text("连接 Mac 代理")
                } footer: {
                    Text("在“设置 → 无线局域网 → 当前网络 → 配置代理”中选择手动，并填写以上地址。")
                }

                Section("连接状态") {
                    LabeledContent("代理地址") {
                        Text(proxyAddress)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("测试结果") {
                        Text(connectionStatus)
                            .foregroundStyle(.secondary)
                    }
                    Button("测试代理连接") {
                        testProxy()
                    }
                    .disabled(proxyHost.isEmpty)
                }

                Section {
                    Button {
                        showingTunnelHelp = true
                    } label: {
                        Label("配置本机 VPN 抓包", systemImage: "network.badge.shield.half.filled")
                    }
                } footer: {
                    Text("本机模式需要包含 Network Extension 权限的开发者签名。")
                }

                Section("HTTPS") {
                    Label(
                        "当前版本记录 HTTPS CONNECT 隧道，不解密 TLS 正文",
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Poker Mobile")
            .sheet(isPresented: $showingTunnelHelp) {
                NavigationStack {
                    VStack(spacing: 18) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 52))
                            .foregroundStyle(.blue)
                        Text("Packet Tunnel")
                            .font(.title2.bold())
                        Text("工程已包含 PacketTunnelProvider 骨架。启用对应 entitlement 并完成 tun 到代理的转发后，可在本机模式捕获流量。")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(30)
                    .toolbar {
                        Button("完成") {
                            showingTunnelHelp = false
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private var proxyAddress: String {
        proxyHost.isEmpty ? "尚未配置" : "\(proxyHost):\(proxyPort)"
    }

    private func testProxy() {
        guard let url = URL(string: "http://example.com/") else {
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": true,
            "HTTPProxy": proxyHost,
            "HTTPPort": proxyPort
        ]
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        connectionStatus = "测试中…"
        URLSession(configuration: configuration).dataTask(with: request) {
            _, response, error in
            Task { @MainActor in
                if let error {
                    connectionStatus = "失败：\(error.localizedDescription)"
                } else if let response = response as? HTTPURLResponse {
                    connectionStatus = "已连接（HTTP \(response.statusCode)）"
                } else {
                    connectionStatus = "已连接"
                }
            }
        }.resume()
    }
}
