import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum TunnelError: LocalizedError {
        case forwardingCoreUnavailable

        var errorDescription: String? {
            "本机构建尚未包含 tun-to-proxy 转发核心"
        }
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // 不设置虚拟网络，避免在转发核心未就绪时静默丢弃用户流量。
        completionHandler(TunnelError.forwardingCoreUnavailable)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
