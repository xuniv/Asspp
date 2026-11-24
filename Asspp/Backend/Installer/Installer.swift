//
//  Installer.swift
//  AppInstaller
//
//  Created by 秋星桥 on 2024/7/10.
//

import ApplePackage
import Foundation
import Logging
#if canImport(UIKit)
    import UIKit
#endif
import Vapor

@Observable
class Installer: Identifiable, @unchecked Sendable {
    @ObservationIgnored let id: UUID
    @ObservationIgnored let app: Application
    @ObservationIgnored let host: InstallationHost
    @ObservationIgnored let archive: AppStore.AppPackage
    @ObservationIgnored let port = Int.random(in: 4000 ... 8000)
    @ObservationIgnored private let shutdownLock = NSLock()
    @ObservationIgnored private var shuttingDown = false

    enum Status {
        case ready
        case sendingManifest
        case sendingPayload
        case completed(Result<Void, Error>)
        case broken(Error)
    }

    @MainActor
    var status: Status = .ready

    init(archive: AppStore.AppPackage, path packagePath: URL) async throws {
        let id: UUID = .init()
        self.id = id
        let metadata = try StorePackageValidator.importedPackage(at: packagePath)
        guard metadata.software.bundleID == archive.software.bundleID else { throw InstallationError.invalidIPA }
        var installationArchive = archive
        // OTA metadata needs CFBundleVersion from the IPA, not the App Store's
        // marketing version. This also rejects a mismatched/non-iOS package.
        installationArchive.software.version = metadata.software.version
        self.archive = installationArchive
        host = InstallationHost.selected
        app = try await Self.setupApp(port: port, tls: Self.setupTLS(host: host))
        logger.info("Installer app setup completed for ID: \(id)")

        app.get("*") { [weak self] req in
            guard let self else { return Response(status: .badGateway) }

            switch req.url.path {
            case "/ping":
                return Response(status: .ok, body: .init(string: "pong"))
            case "/", "/index.html":
                return Response(status: .ok, version: req.version, headers: [
                    "Content-Type": "text/html",
                ], body: .init(string: indexHtml))
            case plistEndpoint.path:
                await MainActor.run { self.status = .sendingManifest }
                logger.info("sending manifest for installer id: \(self.id)")
                return Response(status: .ok, version: req.version, headers: [
                    "Content-Type": "text/xml",
                ], body: .init(data: installManifestData))
            case displayImageSmallEndpoint.path:
                await MainActor.run { self.status = .sendingManifest }
                logger.info("sending small display image for installer id: \(self.id)")
                return Response(status: .ok, version: req.version, headers: [
                    "Content-Type": "image/png",
                ], body: .init(data: displayImageSmallData))
            case displayImageLargeEndpoint.path:
                await MainActor.run { self.status = .sendingManifest }
                logger.info("sending large display image for installer id: \(self.id)")
                return Response(status: .ok, version: req.version, headers: [
                    "Content-Type": "image/png",
                ], body: .init(data: displayImageLargeData))
            case payloadEndpoint.path:
                await MainActor.run { self.status = .sendingPayload }
                logger.info("starting payload transfer for installer id: \(self.id)")

                return try await req.fileio.asyncStreamFile(
                    at: packagePath.path,
                    chunkSize: 64 * 1024,
                ) { result in
                    await MainActor.run {
                        self.status = .completed(result)
                        if case .success = result {
                            logger.info("payload transfer completed for installer id: \(self.id)")
                        } else {
                            logger.error("payload transfer failed for installer id: \(self.id)")
                        }
                    }
                }
            default:
                // 404
                logger.warning("unknown request path: \(req.url.path) for installer id: \(self.id)")
                return Response(status: .notFound)
            }
        }

        do { try app.server.start() }
        catch {
            destroy()
            throw error
        }
        logger.info("installer init at port \(port) for sni \(host.rawValue)")
    }

    deinit {
        destroy()
    }

    func destroy() {
        let shouldShutdown = shutdownLock.withLock {
            guard !shuttingDown, !app.didShutdown else { return false }
            shuttingDown = true
            return true
        }
        guard shouldShutdown else { return }
        logger.info("destroying installer id: \(id)")
        let application = app
        Task.detached {
            await application.server.shutdown()
            do { try await application.asyncShutdown() }
            catch { logger.error("Local installer shutdown failed: \(StoreDiagnostics.errorSummary(error))") }
        }
    }
}
