import ApplePackage
import Foundation

/// All Store operations share the bundled ipatool runtime. Provisioning and
/// two-factor state remain in Keychain between verification-code submissions.
actor StoreAuthenticator {
    private let previous: Account?
    private var busy = false

    init(cookies _: [Cookie] = [], previous: Account? = nil) async throws {
        self.previous = previous
    }

    func authenticate(email: String, password: String, code: String = "") async throws -> Account {
        guard !busy else { throw StoreAuthenticationError.busy }
        busy = true
        defer { busy = false }
        return try await ModernStore.login(email: email, password: password, code: code, previous: previous)
    }
}
