import Foundation

enum StoreDiagnostics {
    /// NSError userInfo and localized descriptions may contain account names,
    /// signed URLs or Apple response messages. Keep those out of retained logs.
    static func errorSummary(_ error: Error) -> String {
        if let runtime = error as? StoreRuntimeError { return "runtime=" + runtime.diagnostic }
        return "type=\(String(describing: type(of: error))) code=\((error as NSError).code)"
    }
}
