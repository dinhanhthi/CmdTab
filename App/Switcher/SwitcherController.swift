import AppKit

/// Runs the switcher: a hotkey press reads the windows and starts a `SwitcherSession`, the release of
/// the modifier commits it, and a commit focuses the chosen window. Between sessions nothing runs here:
/// no timer, no polling; the only thing left is the Carbon hotkeys.
@MainActor
final class SwitcherController {
    private let monitor = HotkeyMonitor()
    /// Created once, when Accessibility is granted, and kept for the life of the process.
    private var watcher: ModifierWatcher?
    private var session = SwitcherSession()
    /// The windows of the current session, front to back. The session's indexes point into it.
    private var list: [WindowSnapshot] = []
    /// Fires 100 ms after the press, when the modifier is still held. It exists only while a session is pending.
    private var holdTimer: DispatchWorkItem?
    private var armedModifier: HotkeyModifier?  // nil = the hotkeys are not taken
    /// Exists only while the hotkeys could not be taken.
    private var activeObserver: NSObjectProtocol?

    func start() {
        monitor.onPress = { [weak self] key in self?.pressed(key) }
        arm()
    }

    func stop() {
        apply(session.handle(.cancel))
        monitor.disarm()
        armedModifier = nil
        stopObserving()
    }

    /// Call after the hotkey modifier setting changed.
    func applyPreferences() {
        guard let armedModifier, armedModifier != Preferences.hotkeyModifier else { return }
        apply(session.handle(.cancel))
        arm()
    }

    // MARK: Arming

    /// Takes the hotkeys when Accessibility is granted and the release detector exists.
    /// Otherwise it tries again the next time the app becomes active.
    private func arm() {
        let modifier = Preferences.hotkeyModifier
        if AXIsProcessTrusted() {
            // Only once trusted: the tap cannot be created before.
            if watcher == nil {
                watcher = ModifierWatcher { [weak self] in self?.modifierReleased() }
            }
            if watcher != nil, monitor.arm(modifier: modifier) {
                armedModifier = modifier
                stopObserving()
                return
            }
        }
        disarmAndWait()
    }

    /// Gives the keys (and the Dock its switcher) back until the app becomes active again.
    private func disarmAndWait() {
        monitor.disarm()
        armedModifier = nil
        guard activeObserver == nil else { return }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.arm() }
        }
    }

    private func stopObserving() {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    // MARK: Keys

    private func pressed(_ key: HotkeyMonitor.Key) {
        switch key {
        case .trigger, .reverse:
            let reverse = key == .reverse
            if session.phase == .idle {
                beginSession(reverse: reverse)
            } else {
                apply(session.handle(.step(reverse ? -1 : 1)))
            }
        case .left: apply(session.handle(.step(-1)))
        case .right: apply(session.handle(.step(1)))
        case .escape: apply(session.handle(.cancel))
        }
    }

    private func modifierReleased() {
        apply(session.handle(.modifierReleased))
    }

    private func holdElapsed() {
        holdTimer = nil
        apply(session.handle(.holdElapsed))
    }

    // MARK: Session

    /// The hotkey was pressed while idle. Main thread: only the window list, the pure filter and the session.
    private func beginSession(reverse: Bool) {
        let press = Perf.begin("press")
        defer { Perf.end(press) }
        // Trust can be taken away while the app runs: without it the Dock gets its switcher back.
        guard AXIsProcessTrusted(), let watcher else { return disarmAndWait() }

        let snapshot = WindowSource.snapshot()
        list = WindowFilter.list(
            all: snapshot.all, regularPIDs: snapshot.regularPIDs, displays: snapshot.displays, mouse: snapshot.mouse,
            scope: Preferences.screenScope)
        guard !list.isEmpty else {
            // Nothing to switch to, so no session. This registers no key: it only stops the repeat of the
            // held Tab, which would run this path again and again.
            monitor.setSessionKeys(false)
            return
        }
        let admittedAll = WindowFilter.admitted(snapshot.all, regularPIDs: snapshot.regularPIDs)
        let startIndex = WindowFilter.startIndex(
            list: list, admittedAll: admittedAll, frontmostPID: snapshot.frontmostPID)

        let modifier = Preferences.hotkeyModifier.cgFlag
        // A quick tap may be over already: the session then commits at once.
        let modifierDown = CGEventSource.flagsState(.combinedSessionState).contains(modifier)
        apply(session.begin(count: list.count, startIndex: startIndex, reverse: reverse, modifierDown: modifierDown))
        guard session.phase == .pending else { return }

        watcher.begin(mask: modifier)
        monitor.setSessionKeys(true)
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.holdElapsed() }
        }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: timer)
    }

    /// Everything that exists only during a session goes: the hold timer, the release detector, the session keys.
    private func endSession() {
        holdTimer?.cancel()
        holdTimer = nil
        watcher?.end()
        monitor.setSessionKeys(false)
    }

    private func apply(_ effects: [SwitcherSession.Effect]) {
        for effect in effects {
            switch effect {
            case .commit(let index):
                endSession()
                // An index outside the list is dropped.
                guard list.indices.contains(index) else { continue }
                WindowFocus.focus(windowID: list[index].id, pid: list[index].pid)
            case .cancel:
                endSession()
            case .showPanel, .select:
                // Phase 3: the panel is shown and its selection moved here.
                break
            }
        }
    }
}
