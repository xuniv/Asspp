//
//  Installer.swift
//  AppInstaller
//
//  Created by 秋星桥 on 2024/7/10.
//

import ApplePackage
import Logging
#if canImport(UIKit)
    import UIKit
#endif
import Vapor

@Observable
class Installer: Identifiable, @unchecked Sendable {
    @ObservationIgnored let id: UUID
    @ObservationIgnored let app: Application
    @ObservationIgnored let archive: AppStore.AppPackage
    @ObservationIgnored let port = Int.random(in: 4000 ... 8000)

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
        self.archive = archive
        app = try await Self.setupApp(port: port, secured: true)
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

        try app.server.start()
        logger.info("installer init at port \(port) for sni \(Self.sni)")
    }

    /// avoid misleading name, default parm Installer.ca is not used
    init(certificateAtPath: String) async throws {
        precondition(Installer.caInstaller == nil)

        let id: UUID = .init()
        self.id = id
        archive = .init(software: .init(
            id: .random(),
            bundleID: "",
            name: "",
            version: "",
            artistName: "",
            sellerName: "",
            description: "",
            averageUserRating: 0,
            userRatingCount: 0,
            artworkUrl: "",
            screenshotUrls: [],
            minimumOsVersion: "",
            releaseDate: "",
            formattedPrice: "",
            primaryGenreName: "",
        ))

        app = try await Self.setupApp(port: port, secured: false)

        let certificate = try InstallationProtocol.certificateDER(pem: Data(contentsOf: URL(fileURLWithPath: certificateAtPath)))
        let profile = try InstallationProtocol.certificateProfile(certificate: certificate)
        app.get("Asspp-Local-Installation.mobileconfig") { _ in
            Response(status: .ok, headers: [
                "Content-Type": "application/x-apple-aspen-config",
                "Content-Disposition": "attachment; filename=Asspp-Local-Installation.mobileconfig",
                "Cache-Control": "no-store",
            ], body: .init(data: profile))
        }
        app.get("ca.cer") { _ in
            Response(status: .ok, headers: ["Content-Type": "application/x-x509-ca-cert", "Cache-Control": "no-store"], body: .init(data: certificate))
        }

        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = port
        comps.path = InstallationProtocol.profilePath
        let url = comps.url!
        try app.server.start()
        Installer.caURL = url
        Installer.caInstaller = self
    }

    deinit {
        destroy()
    }

    func destroy() {
        guard !app.didShutdown else { return }
        logger.info("destroying installer id: \(id)")
        Task.detached {
            await self.app.server.shutdown()
            try await self.app.asyncShutdown()
            withExtendedLifetime(self) { _ in }
            withExtendedLifetime(self.app) { _ in }
        }
    }
}
