import Foundation

public struct WeakNetworkConfiguration: Sendable {
    public var isEnabled: Bool
    public var uploadBytesPerSecond: Int
    public var downloadBytesPerSecond: Int

    public init(
        isEnabled: Bool = false,
        uploadBytesPerSecond: Int = 256 * 1_024,
        downloadBytesPerSecond: Int = 256 * 1_024
    ) {
        self.isEnabled = isEnabled
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
    }

    var effectiveUploadBytesPerSecond: Int? {
        effectiveSpeed(uploadBytesPerSecond)
    }

    var effectiveDownloadBytesPerSecond: Int? {
        effectiveSpeed(downloadBytesPerSecond)
    }

    private func effectiveSpeed(_ speed: Int) -> Int? {
        guard isEnabled, speed > 0 else {
            return nil
        }
        return speed
    }
}
