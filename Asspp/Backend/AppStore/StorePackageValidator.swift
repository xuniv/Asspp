import ApplePackage
import Foundation
import ZIPFoundation

enum StorePackageValidator {
    static func validate(at url: URL, package: AppStore.AppPackage) throws {
        let info = try readInfo(at: url)
        try StoreDownloadProtocol.validatePackageInfo(
            info, bundleID: package.software.bundleID,
            platform: package.entityType == .appleTV ? "AppleTVOS" : "iPhoneOS",
        )
    }

    static func importedPackage(at url: URL) throws -> AppStore.AppPackage {
        let info = try readInfo(at: url)
        let metadata = try InstallationProtocol.importedMetadata(info)
        return .init(software: .init(
            id: 0, bundleID: metadata.bundleID, name: metadata.name,
            version: metadata.build, artistName: "", sellerName: "", description: "",
            averageUserRating: 0, userRatingCount: 0, artworkUrl: "", screenshotUrls: [],
            minimumOsVersion: info["MinimumOSVersion"] as? String ?? "", releaseDate: "",
            formattedPrice: "", primaryGenreName: "",
        ), entityType: .iPhone)
    }

    static func marketingVersion(at url: URL) throws -> String? {
        let version = try readInfo(at: url)["CFBundleShortVersionString"] as? String
        return version.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func readInfo(at url: URL) throws -> [String: Any] {
        let archive = try Archive(url: url, accessMode: .read)
        let entries = archive.filter { StoreDownloadProtocol.isMainInfoPlist($0.path) }
        guard entries.count == 1, let entry = entries.first, entry.uncompressedSize <= 1024 * 1024 else {
            throw StoreDownloadError.invalidPackage
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard chunk.count <= 1024 * 1024 - data.count else { throw StoreDownloadError.invalidPackage }
            data.append(chunk)
        }
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw StoreDownloadError.invalidPackage
        }
        return info
    }
}
