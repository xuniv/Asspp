//
//  Installer+Compute.swift
//  Asspp
//
//  Created by 秋星桥 on 2024/7/11.
//

import ApplePackage
import Foundation

extension Installer {
    var plistEndpoint: URL {
        InstallationProtocol.endpoint(port: port, path: "/\(id).plist", host: host)
    }

    var payloadEndpoint: URL {
        InstallationProtocol.endpoint(port: port, path: "/\(id).ipa", host: host)
    }

    var iTunesLink: URL {
        InstallationProtocol.installLink(manifest: plistEndpoint)
    }

    var displayImageSmallEndpoint: URL {
        InstallationProtocol.endpoint(port: port, path: "/app57x57.png", host: host)
    }

    var displayImageSmallData: Data {
        createWhite(57)
    }

    var displayImageLargeEndpoint: URL {
        InstallationProtocol.endpoint(port: port, path: "/app512x512.png", host: host)
    }

    var displayImageLargeData: Data {
        createWhite(512)
    }

    var indexHtml: String {
        """
        <html> <head> <meta http-equiv="refresh" content="0;url=\(iTunesLink.absoluteString)"> </head> </html>
        """
    }

    var installManifest: [String: Any] {
        [
            "items": [
                [
                    "assets": [
                        [
                            "kind": "software-package",
                            "url": payloadEndpoint.absoluteString,
                        ],
                        [
                            "kind": "display-image",
                            "url": displayImageSmallEndpoint.absoluteString,
                        ],
                        [
                            "kind": "full-size-image",
                            "url": displayImageLargeEndpoint.absoluteString,
                        ],
                    ],
                    "metadata": [
                        "bundle-identifier": archive.software.bundleID,
                        "bundle-version": archive.software.version,
                        "kind": "software",
                        "title": archive.software.name,
                    ],
                ],
            ],
        ]
    }

    var installManifestData: Data {
        (try? PropertyListSerialization.data(
            fromPropertyList: installManifest,
            format: .xml,
            options: .zero,
        )) ?? .init()
    }
}
