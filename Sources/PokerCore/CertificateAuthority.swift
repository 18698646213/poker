import Foundation
import NIOSSL

public enum CertificateAuthorityError: LocalizedError {
    case unsupportedPlatform
    case invalidHost
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "当前平台不支持创建 MITM 证书"
        case .invalidHost:
            return "无法为无效域名签发证书"
        case let .commandFailed(message):
            return "证书生成失败：\(message)"
        }
    }
}

public struct TLSIdentity {
    public let certificateChain: [NIOSSLCertificate]
    public let privateKey: NIOSSLPrivateKey
}

public final class CertificateAuthority: @unchecked Sendable {
    private static let certificateFormatVersion = "2"

    public let directoryURL: URL
    public let rootCertificateURL: URL

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private var identityCache: [String: TLSIdentity] = [:]

    public init(directoryURL: URL? = nil) throws {
        #if os(macOS)
        let defaultDirectory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Poker", isDirectory: true)
        .appendingPathComponent("Certificates", isDirectory: true)
        self.directoryURL = directoryURL ?? defaultDirectory
        rootCertificateURL = self.directoryURL.appendingPathComponent("PokerCA.cer")
        try prepareRootCertificate()
        #else
        throw CertificateAuthorityError.unsupportedPlatform
        #endif
    }

    public func rootCertificateData() throws -> Data {
        try Data(contentsOf: rootCertificateURL)
    }

    public func identity(for host: String) throws -> TLSIdentity {
        lock.lock()
        defer {
            lock.unlock()
        }
        if let cached = identityCache[host] {
            return cached
        }
        let identity = try createIdentity(for: host)
        identityCache[host] = identity
        return identity
    }

    #if os(macOS)
    private var rootKeyURL: URL {
        directoryURL.appendingPathComponent("PokerCA.key")
    }

    private var rootPEMURL: URL {
        directoryURL.appendingPathComponent("PokerCA.pem")
    }

    private var versionURL: URL {
        directoryURL.appendingPathComponent("VERSION")
    }

    private func prepareRootCertificate() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let installedVersion = try? String(
            contentsOf: versionURL,
            encoding: .utf8
        )
        if installedVersion != Self.certificateFormatVersion {
            for url in try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) {
                try fileManager.removeItem(at: url)
            }
        }
        if !fileManager.fileExists(atPath: rootKeyURL.path) ||
            !fileManager.fileExists(atPath: rootPEMURL.path) {
            let configurationURL = directoryURL
                .appendingPathComponent("PokerCA.cnf")
            let configuration = """
            [req]
            distinguished_name=distinguished_name
            x509_extensions=v3_ca
            prompt=no

            [distinguished_name]
            CN=Poker Local CA
            O=Poker

            [v3_ca]
            subjectKeyIdentifier=hash
            authorityKeyIdentifier=keyid:always,issuer
            basicConstraints=critical,CA:TRUE
            keyUsage=critical,keyCertSign,cRLSign
            """
            try Data(configuration.utf8).write(
                to: configurationURL,
                options: .atomic
            )
            defer {
                try? fileManager.removeItem(at: configurationURL)
            }
            try runOpenSSL([
                "req", "-x509", "-newkey", "rsa:3072", "-sha256",
                "-days", "3650", "-nodes",
                "-keyout", rootKeyURL.path,
                "-out", rootPEMURL.path,
                "-config", configurationURL.path,
                "-extensions", "v3_ca"
            ])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: rootKeyURL.path
            )
        }
        if !fileManager.fileExists(atPath: rootCertificateURL.path) {
            try runOpenSSL([
                "x509", "-in", rootPEMURL.path,
                "-outform", "der",
                "-out", rootCertificateURL.path
            ])
        }
        try Data(Self.certificateFormatVersion.utf8).write(
            to: versionURL,
            options: .atomic
        )
    }

    private func createIdentity(for host: String) throws -> TLSIdentity {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty,
              host.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw CertificateAuthorityError.invalidHost
        }

        let name = Data(host.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let certificateURL = directoryURL.appendingPathComponent("\(name).pem")
        let keyURL = directoryURL.appendingPathComponent("\(name).key")

        if !fileManager.fileExists(atPath: certificateURL.path) ||
            !fileManager.fileExists(atPath: keyURL.path) {
            let requestURL = directoryURL.appendingPathComponent("\(name).csr")
            let extensionsURL = directoryURL.appendingPathComponent("\(name).ext")
            let subjectType = host.contains(":") ||
                host.split(separator: ".").allSatisfy { Int($0) != nil }
                ? "IP"
                : "DNS"
            let extensions = """
            subjectAltName=\(subjectType):\(host)
            basicConstraints=critical,CA:FALSE
            keyUsage=critical,digitalSignature,keyEncipherment
            extendedKeyUsage=serverAuth
            """
            try Data(extensions.utf8).write(to: extensionsURL, options: .atomic)
            defer {
                try? fileManager.removeItem(at: requestURL)
                try? fileManager.removeItem(at: extensionsURL)
            }

            try runOpenSSL([
                "req", "-new", "-newkey", "rsa:2048", "-nodes",
                "-keyout", keyURL.path,
                "-out", requestURL.path,
                "-subj", "/CN=\(host)"
            ])
            try runOpenSSL([
                "x509", "-req",
                "-in", requestURL.path,
                "-CA", rootPEMURL.path,
                "-CAkey", rootKeyURL.path,
                "-set_serial", "0x\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                "-days", "397", "-sha256",
                "-extfile", extensionsURL.path,
                "-out", certificateURL.path
            ])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyURL.path
            )
        }

        return TLSIdentity(
            certificateChain: try NIOSSLCertificate.fromPEMFile(certificateURL.path),
            privateKey: try NIOSSLPrivateKey(file: keyURL.path, format: .pem)
        )
    }

    private func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "openssl 退出码 \(process.terminationStatus)"
            throw CertificateAuthorityError.commandFailed(message)
        }
    }
    #else
    private func createIdentity(for host: String) throws -> TLSIdentity {
        throw CertificateAuthorityError.unsupportedPlatform
    }
    #endif
}
