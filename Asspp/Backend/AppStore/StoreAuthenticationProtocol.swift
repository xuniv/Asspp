import Foundation

enum StoreAuthenticationError: LocalizedError {
    case invalidEndpoint, invalidResponse, busy
    case exhausted([Int])
    case retryLater(Int)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: String(localized: "Apple returned an unapproved authentication endpoint.")
        case .invalidResponse: String(localized: "Apple returned an invalid authentication response.")
        case .busy: String(localized: "Authentication is already in progress.")
        case let .exhausted(statuses):
            String(localized: "Apple did not complete sign-in after eight attempts. Try again later.") + " (HTTP \(statuses.map(String.init).joined(separator: ", ")))"
        case let .retryLater(seconds):
            String(localized: "Apple asked to delay sign-in. Try again later.") + " (\(seconds)s)"
        case let .rejected(message): message
        }
    }
}

/// No credentials or network access: shared by production transport and regression checks.
enum StoreAuthenticationProtocol {
    static let attempts = 8
    static let legacy = URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/")!
    static let native = URL(string: "https://auth.itunes.apple.com/auth/v1/native/fast/")!

    static func approved(_ url: URL, guid: String? = nil) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443
        else { throw StoreAuthenticationError.invalidEndpoint }
        let legacyHost = host == "buy.itunes.apple.com" || host.range(of: #"^p[0-9]+-buy\.itunes\.apple\.com$"#, options: .regularExpression) != nil
        if legacyHost, parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "WebObjects/MZFinance.woa/wa/authenticate" {
            parts.path = legacy.path
        } else if host == "auth.itunes.apple.com", ["/auth/v1/native", "/auth/v1/native/", "/auth/v1/native/fast", "/auth/v1/native/fast/"].contains(parts.path) {
            parts.path = native.path
        } else { throw StoreAuthenticationError.invalidEndpoint }
        parts.host = host
        if let guid {
            parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "guid" } + [URLQueryItem(name: "guid", value: guid)]
        }
        guard let result = parts.url else { throw StoreAuthenticationError.invalidEndpoint }
        return result
    }

    static func endpoints(bag: URL, guid: String) throws -> [URL] {
        var result: [URL] = []
        for url in [bag, legacy, native] {
            let candidate = try approved(url, guid: guid)
            if !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }

    static func isTransient(status: Int, dictionary: [String: Any]?) -> Bool {
        if let dictionary, ["failureType", "customerMessage", "dialog", "accountInfo"].contains(where: { dictionary[$0] != nil }) { return false }
        return [204, 403, 404, 429].contains(status) || status / 100 == 5
    }

    static func retryDelay(_ header: String?, now: Date = Date()) throws -> TimeInterval {
        guard let value = header?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return 2 }
        let delay: TimeInterval?
        if value.allSatisfy({ $0.isASCII && $0.isNumber }) {
            delay = TimeInterval(value) ?? 31
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            delay = formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
        }
        guard let delay else { return 2 }
        guard delay <= 30 else { throw StoreAuthenticationError.retryLater(Int(min(delay, 86_400))) }
        return max(1, delay)
    }
}
