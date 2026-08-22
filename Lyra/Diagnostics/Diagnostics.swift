import Foundation
import OSLog

/// Local-only diagnostics for Console and attached device sessions. Keep log
/// fields structural: credentials, server URLs, library names, and track paths
/// must never cross this boundary.
enum LyraLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "care.davinci.lyra"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let webDAV = Logger(subsystem: subsystem, category: "webdav")
    static let offline = Logger(subsystem: subsystem, category: "offline")
    static let playback = Logger(subsystem: subsystem, category: "playback")
}

enum DiagnosticValue {
    /// Error descriptions can contain URLs and local paths. Domain and code are
    /// enough to correlate failures without recording a user's library details.
    static func errorCode(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain):\(error.code)"
    }
}
