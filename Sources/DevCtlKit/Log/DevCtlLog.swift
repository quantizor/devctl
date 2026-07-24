import Foundation
import os

/** The unified-logging category a message belongs to; the string is the literal
    OSLog category, so `log show --predicate 'subsystem == "dev.quantizor.devctl"'`
    can filter by it. */
public enum DevCtlLogCategory: String, Sendable, Equatable, CaseIterable {
    case app
    case daemon
    case deeplink
    case health
    case supervisor
}

/** Severity, mapped onto the matching `os.Logger` level by the OSLog backend. */
public enum DevCtlLogLevel: String, Sendable, Equatable, CaseIterable {
    case debug
    case error
    case info
}

/** The sink every log call funnels through. The default is `OSLogBackend`; tests
    swap in `RecordingBackend` so an assertion can read back what was emitted. */
public protocol DevCtlLogBackend: Sendable {
    func log(category: DevCtlLogCategory, level: DevCtlLogLevel, message: String)
}

/** Production backend: one `os.Logger` per (subsystem, category), levels mapped
    straight through. Messages are logged `.public` because devctl logs its own
    server names and phases, never resident or third-party data. */
public struct OSLogBackend: DevCtlLogBackend {
    public init() {}

    public func log(category: DevCtlLogCategory, level: DevCtlLogLevel, message: String) {
        let logger = Logger(subsystem: DevCtlLog.subsystem, category: category.rawValue)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        }
    }
}

/** Test backend: a thread-safe append-only record of every emitted message.
    `install`/`reset` bracket a test; read `entries` (or `messages`) to assert. */
public final class RecordingBackend: DevCtlLogBackend {
    public struct Entry: Sendable, Equatable {
        public var category: DevCtlLogCategory
        public var level: DevCtlLogLevel
        public var message: String

        public init(category: DevCtlLogCategory, level: DevCtlLogLevel, message: String) {
            self.category = category
            self.level = level
            self.message = message
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: [Entry]())

    public init() {}

    public var entries: [Entry] {
        state.withLock { $0 }
    }

    public var messages: [String] {
        state.withLock { $0.map(\.message) }
    }

    public func log(category: DevCtlLogCategory, level: DevCtlLogLevel, message: String) {
        state.withLock { $0.append(Entry(category: category, level: level, message: message)) }
    }

    public func reset() {
        state.withLock { $0.removeAll() }
    }

    /** Swaps this recorder in as the active backend and returns it, so a test can
        `let log = RecordingBackend.install()` in one line. */
    @discardableResult
    public static func install() -> RecordingBackend {
        let backend = RecordingBackend()
        DevCtlLog.backend = backend
        return backend
    }
}

/** The logging front door. Call the ergonomic per-category members
    (`DevCtlLog.deeplink.info("…")`) or the category-parameterized statics; both
    reach the swappable `backend`. */
public enum DevCtlLog {
    public static let subsystem = "dev.quantizor.devctl"

    /** A category bound to the front door; the object `DevCtlLog.deeplink` is. */
    public struct CategoryLogger: Sendable {
        public let category: DevCtlLogCategory

        public func debug(_ message: @autoclosure () -> String) {
            DevCtlLog.emit(category: category, level: .debug, message: message())
        }

        public func error(_ message: @autoclosure () -> String) {
            DevCtlLog.emit(category: category, level: .error, message: message())
        }

        public func info(_ message: @autoclosure () -> String) {
            DevCtlLog.emit(category: category, level: .info, message: message())
        }
    }

    public static let app = CategoryLogger(category: .app)
    public static let daemon = CategoryLogger(category: .daemon)
    public static let deeplink = CategoryLogger(category: .deeplink)
    public static let health = CategoryLogger(category: .health)
    public static let supervisor = CategoryLogger(category: .supervisor)

    /** The active backend, guarded by a lock so a test's swap and a concurrent
        log never race. */
    public static var backend: any DevCtlLogBackend {
        get { backendLock.withLock { $0 } }
        set { backendLock.withLock { $0 = newValue } }
    }

    public static func debug(_ category: DevCtlLogCategory, _ message: String) {
        emit(category: category, level: .debug, message: message)
    }

    public static func error(_ category: DevCtlLogCategory, _ message: String) {
        emit(category: category, level: .error, message: message)
    }

    public static func info(_ category: DevCtlLogCategory, _ message: String) {
        emit(category: category, level: .info, message: message)
    }

    private static let backendLock = OSAllocatedUnfairLock<any DevCtlLogBackend>(
        initialState: OSLogBackend())

    private static func emit(category: DevCtlLogCategory, level: DevCtlLogLevel, message: String) {
        backend.log(category: category, level: level, message: message)
    }
}
