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
    static let sni = InstallationProtocol.hostname
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

    static var caURL: URL?
    static var caInstaller: Installer?
    private static var caStartup: Task<URL, Error>?

    @MainActor
    static func certificateURL() async throws -> URL {
        if let caURL { return caURL }
        let task: Task<URL, Error>
        if let caStartup { task = caStartup }
        else {
            task = Task {
                _ = try await Installer(certificateAtPath: ca.path)
                guard let caURL else { throw InstallationError.certificateUnavailable }
                return caURL
            }
            caStartup = task
        }
        do { return try await task.value }
        catch { caStartup = nil; throw error }
    }

    static func checkSystemTrust() throws {
        guard let crt,
              let leaf = SecCertificateCreateWithData(nil, try InstallationProtocol.certificateDER(pem: Data(contentsOf: crt)) as CFData),
              let root = SecCertificateCreateWithData(nil, try InstallationProtocol.certificateDER(pem: Data(contentsOf: ca)) as CFData)
        else { throw InstallationError.certificateUnavailable }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, root] as CFArray, SecPolicyCreateSSL(true, sni as CFString), &trust) == errSecSuccess,
              let trust, SecTrustEvaluateWithError(trust, nil)
        else { throw InstallationError.certificateTrustRequired }
    }

    func checkConnection() async throws {
        try Self.checkSystemTrust()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: InstallationProtocol.endpoint(port: port, path: "/ping"))
            guard (response as? HTTPURLResponse)?.statusCode == 200, data == Data("pong".utf8) else { throw InstallationError.unreachable }
        } catch let error as URLError where [-1200, -1201, -1202, -1203, -1204].contains(error.code.rawValue) {
            throw InstallationError.certificateTrustRequired
        } catch { throw InstallationError.unreachable }
    }

    static func setupTLS() throws -> TLSConfiguration {
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
