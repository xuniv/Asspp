import Foundation

enum DownloadVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func components(_ version: String) -> [Substring]? {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48 ... 57).contains($0) } }) else { return nil }
            return parts.map { $0.drop(while: { $0 == "0" }) }
        }

        if let lhs = components(lhs), let rhs = components(rhs) {
            for index in 0 ..< max(lhs.count, rhs.count) {
                let a = index < lhs.count ? lhs[index] : ""
                let b = index < rhs.count ? rhs[index] : ""
                if a.count != b.count { return a.count < b.count ? .orderedAscending : .orderedDescending }
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            }
            return .orderedSame
        }
        return lhs.compare(rhs, options: [.numeric, .caseInsensitive, .literal], locale: Locale(identifier: "en_US_POSIX"))
    }
}
