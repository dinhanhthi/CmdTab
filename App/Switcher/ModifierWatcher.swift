import CoreGraphics
import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "com.math2it.cmdtab", category: "Input")

/// Reports the release of the switcher's modifier, once per session.
/// Two detectors run between `begin` and `end`: a listen-only `flagsChanged` tap on its own thread,
/// and a 50 ms watchdog that reads the modifier state (it covers a tap that went silent).
/// Outside a session the tap is disabled and the watchdog does not exist.
/// There is one watcher for the life of the process: the tap thread keeps it alive.
final class ModifierWatcher: @unchecked Sendable {
    /// What the tap thread shares with the main thread.
    private struct Session {
        var id: UInt64 = 0
        var mask: CGEventFlags = []
        var active = false  // between `begin` and `end`
        var fired = false  // a detector saw the release
    }

    private let onRelease: @MainActor () -> Void
    private let session = Mutex(Session())
    /// Set once in `init`, before the tap thread starts.
    private var tap: CFMachPort!
    @MainActor private var watchdog: DispatchSourceTimer?

    /// Nil when the tap cannot be created: Accessibility is not granted.
    @MainActor
    init?(onRelease: @escaping @MainActor () -> Void) {
        self.onRelease = onRelease
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
            callback: tapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log.error("modifier tap not created")
            return nil
        }
        CGEvent.tapEnable(tap: port, enable: false)
        tap = port
        let thread = Thread { [self] in
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CFRunLoopRun()
        }
        thread.name = "com.math2it.cmdtab.modifier-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Starts a session. `onRelease` runs once, on a later turn of the main queue (never inside this call),
    /// when no flag of `mask` is down any more: at once if the modifier is already up.
    @MainActor
    func begin(mask: CGEventFlags) {
        session.withLock {
            $0.id &+= 1
            $0.mask = mask
            $0.active = true
            $0.fired = false
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [self] in readFlags() }
        timer.resume()
        watchdog = timer
        readFlags()
    }

    /// Ends the session: no `onRelease` after this, even one that was already on its way.
    @MainActor
    func end() {
        session.withLock {
            guard $0.active else { return }
            $0.active = false
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: Any thread

    private func readFlags() {
        flagsChanged(CGEventSource.flagsState(.combinedSessionState))
    }

    /// The first detector to see the release wins; the other one is dropped.
    fileprivate func flagsChanged(_ flags: CGEventFlags) {
        let released = session.withLock { session -> UInt64? in
            guard session.active, !session.fired, flags.isDisjoint(with: session.mask) else { return nil }
            session.fired = true
            return session.id
        }
        guard let released else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.deliver(session: released) }
        }
    }

    /// The system switched the tap off (a timeout, or user input). During a session it goes back on,
    /// and the state is read again: the release may have been missed.
    fileprivate func tapWasDisabled() {
        // Enabled under the lock, so it cannot land after `end` disabled the tap.
        let active = session.withLock { session -> Bool in
            if session.active { CGEvent.tapEnable(tap: tap, enable: true) }
            return session.active
        }
        if active { readFlags() }
    }

    @MainActor
    private func deliver(session id: UInt64) {
        // `end`, or the `begin` of the next session, came first.
        guard session.withLock({ $0.active && $0.id == id }) else { return }
        onRelease()
    }
}

/// Runs on the tap thread: one mask compare, then a hop to main.
private let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
        let watcher = Unmanaged<ModifierWatcher>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .flagsChanged {
            watcher.flagsChanged(event.flags)
        } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // No event comes with these two: it is only passed back.
            watcher.tapWasDisabled()
        }
    }
    return Unmanaged.passUnretained(event)
}
