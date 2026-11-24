//
//  Installer+TLS.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import Foundation
import NIOSSL
import NIOTLS
import Security
import Vapor

extension Installer {
    static let pem = Bundle.main.url(
        forResource: "localhost.qaq.wiki-key",
        withExtension: "pem",
        subdirectory: "Certificates/localhost.qaq.wiki",
    )
    static let crt = Bundle.main.url(
        forResource: "localhost.qaq.wiki",
        withExtension: "pem",
        subdirectory: "Certificates/localhost.qaq.wiki",
    )
    static let ca = Bundle.main.url(
        forResource: "rootCA",
        withExtension: "pem",
        subdirectory: "Certificates/localhost.qaq.wiki",
    )!

    @MainActor private static var profileServers: [InstallationHost: Task<(Application, URL), Error>] = [:]

    @MainActor
    static func certificateURL(for host: InstallationHost = .selected) async throws -> URL {
        if let task = profileServers[host] { return try await task.value.1 }
        let task = Task {
            // Prepare the certificate before opening the profile URL.
            _ = try Self.certificateChain(for: host)
            let port = Int.random(in: 40000 ... 50000)
            let app = try await Self.setupApp(port: port)
            let token = UUID().uuidString
            app.get(PathComponent(stringLiteral: token), "Asspp-Local-Installation.mobileconfig") { _ in
                let root = try Self.certificateChain(for: host).root
                let profile = try InstallationProtocol.certificateProfile(certificate: root, host: host)
                return Response(status: .ok, headers: [
                    "Content-Type": "application/x-apple-aspen-config",
                    "Content-Disposition": "attachment; filename=Asspp-Local-Installation.mobileconfig",
                    "Cache-Control": "no-store",
                ], body: .init(data: profile))
            }
            do { try app.server.start() }
            catch {
                try? await app.asyncShutdown()
                throw error
            }
            return (app, URL(string: "http://127.0.0.1:\(port)/\(token)\(InstallationProtocol.profilePath)")!)
        }
        profileServers[host] = task
        do { return try await task.value.1 }
        catch { profileServers[host] = nil; throw error }
    }

    private static func certificateChain(for host: InstallationHost) throws -> (leaf: Data, root: Data) {
        #if os(iOS)
            if host == .offline {
                let identity = try OfflineInstallationIdentity.load()
                return (identity.leaf, identity.root)
            }
        #endif
        guard let crt else { throw InstallationError.certificateUnavailable }
        return (
            try InstallationProtocol.certificateDER(pem: Data(contentsOf: crt)),
            try InstallationProtocol.certificateDER(pem: Data(contentsOf: ca)),
        )
    }

    static func checkSystemTrust(host: InstallationHost) throws {
        let certificates = try certificateChain(for: host)
        guard let leaf = SecCertificateCreateWithData(nil, certificates.leaf as CFData),
              let root = SecCertificateCreateWithData(nil, certificates.root as CFData)
        else { throw InstallationError.certificateUnavailable }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, root] as CFArray, SecPolicyCreateSSL(true, host.rawValue as CFString), &trust) == errSecSuccess,
              let trust else { throw InstallationError.certificateTrustRequired }
        SecTrustSetNetworkFetchAllowed(trust, false)
        guard SecTrustEvaluateWithError(trust, nil) else { throw InstallationError.certificateTrustRequired }
    }

    func checkConnection() async throws {
        try Self.checkSystemTrust(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: InstallationProtocol.endpoint(port: port, path: "/ping", host: host))
            guard (response as? HTTPURLResponse)?.statusCode == 200, data == Data("pong".utf8) else { throw InstallationError.unreachable }
        } catch let error as URLError where [-1200, -1201, -1202, -1203, -1204].contains(error.code.rawValue) {
            throw InstallationError.certificateTrustRequired
        } catch { throw host == .offline ? InstallationError.offlineUnreachable : InstallationError.unreachable }
    }

    static func setupTLS(host: InstallationHost) throws -> TLSConfiguration {
        #if os(iOS)
            if host == .offline {
                let identity = try OfflineInstallationIdentity.load()
                return try TLSConfiguration.makeServerConfiguration(
                    certificateChain: [
                        .certificate(NIOSSLCertificate(bytes: Array(identity.leaf), format: .der)),
                        .certificate(NIOSSLCertificate(bytes: Array(identity.root), format: .der)),
                    ],
                    privateKey: .privateKey(NIOSSLPrivateKey(bytes: Array(LocalCertificate.pem(identity.leafKey, label: "RSA PRIVATE KEY")), format: .pem)),
                )
            }
        #endif
        guard let crt, let pem else {
            throw NSError(domain: "Installer", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Failed to load ssl certificates",
            ])
        }
        return try TLSConfiguration.makeServerConfiguration(
            certificateChain: (NIOSSLCertificate
                .fromPEMFile(crt.path) + NIOSSLCertificate.fromPEMFile(ca.path))
                .map { NIOSSLCertificateSource.certificate($0) },
            privateKey: NIOSSLPrivateKeySource.privateKey(NIOSSLPrivateKey(file: pem.path, format: .pem)),
        )
    }
}
