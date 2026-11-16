import Foundation

/// Only errors that supply an explicit, account-free code enter retained logs.
protocol StoreDiagnosticError: Error {
    var diagnostic: String { get }
}

enum StoreDiagnostics {
    /// NSError userInfo and localized descriptions may contain account names,
    /// signed URLs or Apple response messages. Keep those out of retained logs.
    static func errorSummary(_ error: Error) -> String {
        if let runtime = error as? StoreDiagnosticError { return "runtime=" + runtime.diagnostic }
        return "type=\(String(describing: type(of: error))) code=\((error as NSError).code)"
    }
}
