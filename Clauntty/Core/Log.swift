import Foundation
import os.log

// MARK: - Logger

extension Logger {
    static let clauntty = Logger(subsystem: "com.clauntty", category: "terminal")

    // MARK: - Debug-Only Logging (compiled out in release builds)

    /// Cached at startup - only checked once, not on every log call
    /// Set CLAUNTTY_VERBOSE=1 environment variable to enable verbose logging
    @usableFromInline
    static let isVerbose: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CLAUNTTY_VERBOSE"] != nil
        #else
        return false
        #endif
    }()

    /// Only logs in DEBUG builds - zero cost in release
    /// Use for detailed flow information that's useful during development
    @inline(__always)
    func debugOnly(_ message: @autoclosure () -> String) {
        #if DEBUG
        let msg = message()
        // Public: interpolated messages are otherwise redacted and dropped from device logs
        self.debug("\(msg, privacy: .public)")
        #endif
    }

    /// Verbose logging - only in DEBUG builds AND when CLAUNTTY_VERBOSE=1
    /// Use for expensive operations like hex dumps, per-packet logging, cursor tracking
    /// Performance: Release = zero cost, Debug = single bool check
    @inline(__always)
    func verbose(_ message: @autoclosure () -> String) {
        #if DEBUG
        if Self.isVerbose {
            let msg = message()
            self.info("\(msg, privacy: .public)")
        }
        #endif
    }

    /// Check if verbose logging is enabled (useful for guarding expensive computations)
    @inlinable
    static var verboseLoggingEnabled: Bool {
        #if DEBUG
        return isVerbose
        #else
        return false
        #endif
    }
}
