import Foundation
import os

/// Timed intervals: each one is a signpost interval (Instruments) and one log line `perf <name> <ms>`,
/// which `scripts/measure.sh` reads with `log show`. Callable from any thread.
enum Perf {
    struct Token: Sendable {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
        fileprivate let start: UInt64  // uptime nanoseconds
    }

    private static let subsystem = "com.math2it.cmdtab"
    private static let logger = Logger(subsystem: subsystem, category: "Perf")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "Perf")

    static func begin(_ name: StaticString) -> Token {
        // An id per interval: intervals of one name overlap (`capture`, `focus`).
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        return Token(name: name, state: state, start: DispatchTime.now().uptimeNanoseconds)
    }

    static func end(_ token: Token) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - token.start) / 1_000_000
        signposter.endInterval(token.name, token.state)
        // The name is public: `log show` prints `<private>` otherwise.
        logger.notice("perf \(token.name, privacy: .public) \(ms, format: .fixed(precision: 2))")
    }
}
