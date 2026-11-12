import AppKit
import Synchronization

/// Tells real windows from sheets and other layer-0 windows that cannot be switched to: the CG list shows a
/// sheet as a window of its own, in front of its document window, while Accessibility lists it as no window.
/// Only what is shown to be a non-window is hidden: an on-screen id that Accessibility does not list, or a listed
/// window whose subrole is on a short deny list (floating panels). Any other listed window stays switchable.
/// It also knows which listed windows are minimized. Reads are cache reads, safe on the main thread. The
/// Accessibility work runs only when the controller asks for a refresh, or when the watched frontmost app creates a
/// window or a sheet or minimizes or restores a window (observed per window: the app element posts no minimize), on
/// its own queue: an app that does not answer costs that queue 0.25 s per call, never the main thread. Unchecked
/// Sendable: the cache is behind its mutex, and `watched` and `runLoop` are touched only on the queue (the observer
/// thread hands `runLoop` over once, before the queue reads it).
final class AXWindowClassifier: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.math2it.cmdtab.classifier", qos: .utility)
    private static let timeout: Float = 0.25
    private static let deniedSubroles: Set<String> = [kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole]
    /// Observed on the watched app's element.
    private static let notifications = [kAXWindowCreatedNotification, kAXSheetCreatedNotification]
    /// Observed on each window element of the watched app (registered by `update`): the app element does not post
    /// them.
    private static let windowNotifications = [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
    /// `windows`: switchable or not and minimized or not, by window id, with the owner's pid for `forget` and the
    /// replace of `update`. `pids`: every pid that Accessibility answered once, even with no window, until `forget`.
    private let cache = Mutex<(
        windows: [CGWindowID: (pid: pid_t, switchable: Bool, minimized: Bool)], pids: Set<pid_t>
    )>(([:], []))
    /// The one app whose window and sheet creations, and its windows' minimizes and restores, are observed: the
    /// frontmost regular app. Queue only.
    private var watched: (pid: pid_t, app: AXUIElement, observer: AXObserver)?
    /// The run loop of the observer thread, made on the first `watch` and kept for the process. Queue only.
    private var runLoop: CFRunLoop?

    /// An unknown window is switchable. Known limit: a sheet of the frontmost app is classified ~50 ms after it
    /// appears, so a press inside that gap still lists it; so does a sheet of an app that posts no Accessibility
    /// creation notification, until the next trigger (the session that lists it refreshes that pid at its end).
    func isSwitchable(_ id: CGWindowID) -> Bool {
        cache.withLock { $0.windows[id]?.switchable ?? true }
    }

    /// True when a refresh has classified `id`.
    func knows(_ id: CGWindowID) -> Bool {
        cache.withLock { $0.windows[id] != nil }
    }

    /// True when a refresh found `id` minimized. An unknown window is not.
    func isMinimized(_ id: CGWindowID) -> Bool {
        cache.withLock { $0.windows[id]?.minimized ?? false }
    }

    /// True when a refresh classified `id` as a switchable window: an unknown window is not (unlike `isSwitchable`).
    func isKnownWindow(_ id: CGWindowID) -> Bool {
        cache.withLock { $0.windows[id]?.switchable ?? false }
    }

    /// The pids that Accessibility answered since they were last forgotten, with or without windows.
    func knownPIDs() -> Set<pid_t> {
        cache.withLock { $0.pids }
    }

    /// Returns at once. The pid's windows that Accessibility lists become switchable unless their subrole is on the
    /// deny list, and minimized when they say so; its `onScreenIDs` that Accessibility does not list (sheets) do
    /// not. They replace all of the pid's entries, so windows that closed or are on another Space go; an app that
    /// lists no window and has no `onScreenIDs` loses them all but stays known. When the app or one of its windows
    /// does not answer, or the app lists no window while `onScreenIDs` is not empty, nothing changes: a slow or
    /// confused app must not lose its real windows.
    /// CmdTab's own windows are never classified (they stay switchable): AppKit would answer the Accessibility calls
    /// on this queue, off the main thread.
    func refresh(pid: pid_t, onScreenIDs: [CGWindowID]) {
        guard pid != getpid() else { return }
        queue.async { [self] in update(pid: pid, onScreenIDs: onScreenIDs) }
    }

    /// The app also stops being watched.
    func forget(pid: pid_t) {
        cache.withLock { cache in
            cache.windows = cache.windows.filter { $0.value.pid != pid }
            cache.pids.remove(pid)
        }
        queue.async { [self] in
            if watched?.pid == pid { unwatch() }
        }
    }

    /// Returns at once. Observes the window and sheet creations of `pid` (the frontmost regular app) instead of the
    /// app watched so far, and the minimizes and restores of each of its windows (registered by the refresh that
    /// follows, then by each refresh of `pid`: a new window's creation brings one); each one refreshes `pid` 50 ms
    /// later. Nothing runs between two notifications. CmdTab itself is never watched (see `refresh`).
    func watch(pid: pid_t) {
        guard pid != getpid() else { return }
        queue.async { [self] in
            guard watched?.pid != pid else { return }
            unwatch()
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.timeout)
            var created: AXObserver?
            guard AXObserverCreate(pid, observerCallback, &created) == .success, let observer = created else { return }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let added = Self.notifications.filter {
                AXObserverAddNotification(observer, app, $0 as CFString, refcon) == .success
            }
            // Not registered (no answer, no Accessibility): the next activation of the app tries again.
            guard !added.isEmpty else { return }
            CFRunLoopAddSource(observerRunLoop(), AXObserverGetRunLoopSource(observer), .defaultMode)
            watched = (pid, app, observer)
            // Registers the minimizes and restores of the windows that exist now.
            if let ids = Self.onScreenIDs(pid: pid) { update(pid: pid, onScreenIDs: ids) }
        }
    }

    /// Returns at once. No app is watched any more.
    func stopWatching() {
        queue.async { [self] in unwatch() }
    }

    /// From the observer thread: a window or a sheet of `pid` was created, or one of its windows (each observed on
    /// its own element) was minimized or restored.
    /// The CG list may not show it yet, so the refresh waits 50 ms; a notification of an app that is no longer
    /// watched is dropped then.
    fileprivate func changed(pid: pid_t) {
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
            guard watched?.pid == pid, let ids = Self.onScreenIDs(pid: pid) else { return }
            update(pid: pid, onScreenIDs: ids)
        }
    }

    /// The on-screen layer-0 window ids of `pid`, from one WindowServer read. nil when the read fails.
    static func onScreenIDs(pid: pid_t) -> [CGWindowID]? {
        onScreenIDsByPID().map { $0[pid] ?? [] }
    }

    /// The on-screen layer-0 window ids of every pid, front to back, from one WindowServer read. A pid with none is
    /// missing. nil when the read fails.
    static func onScreenIDsByPID() -> [pid_t: [CGWindowID]]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        var ids: [pid_t: [CGWindowID]] = [:]
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            ids[pid, default: []].append(id)
        }
        return ids
    }

    // MARK: Queue

    private func update(pid: pid_t, onScreenIDs: [CGWindowID]) {
        guard let (found, elements) = Self.classify(pid: pid) else { return }
        // The watched app's windows: the observer holds these registrations until `unwatch` drops it.
        if let watched, watched.pid == pid {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for element in elements {
                for name in Self.windowNotifications {
                    _ = AXObserverAddNotification(watched.observer, element, name as CFString, refcon)
                }
            }
        }
        // One lock: a read never sees the pid half replaced.
        cache.withLock { cache in
            cache.pids.insert(pid)
            // An empty answer with on-screen windows counts as no answer (a confused app); with none, the app has no
            // window on this Space.
            guard !found.isEmpty || onScreenIDs.isEmpty else { return }
            cache.windows = cache.windows.filter { $0.value.pid != pid }
            for id in onScreenIDs { cache.windows[id] = (pid, false, false) }
            for (id, window) in found { cache.windows[id] = (pid, window.switchable, window.minimized) }
        }
    }

    /// The source goes first: no callback of this observer after that. The per-window registrations end with the
    /// observer.
    private func unwatch() {
        guard let watched else { return }
        if let runLoop {
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(watched.observer), .defaultMode)
        }
        for name in Self.notifications {
            AXObserverRemoveNotification(watched.observer, watched.app, name as CFString)
        }
        self.watched = nil
    }

    /// Starts the observer thread on first use. Its run loop only delivers the observer's callbacks; a source
    /// that is never signalled keeps it running while no app is watched. The thread keeps the classifier alive.
    private func observerRunLoop() -> CFRunLoop {
        if let runLoop { return runLoop }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            var context = CFRunLoopSourceContext()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFRunLoopSourceCreate(nil, 0, &context), .defaultMode)
            runLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.math2it.cmdtab.classifier-observer"
        thread.qualityOfService = .utility
        thread.start()
        ready.wait()
        return runLoop!
    }

    /// On the classifier queue: whether each window Accessibility lists for `pid` is switchable, by window id: true
    /// unless its subrole is on the deny list (a missing or unsupported subrole is true), and whether it is minimized
    /// (any failed read is false), with the window elements. nil when the app or one of its windows did not answer
    /// its id or subrole.
    private static func classify(
        pid: pid_t
    ) -> (windows: [CGWindowID: (switchable: Bool, minimized: Bool)], elements: [AXUIElement])? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var found: [CGWindowID: (switchable: Bool, minimized: Bool)] = [:]
        for window in windows {
            // The timeout of the app element does not carry over to its window elements.
            AXUIElementSetMessagingTimeout(window, timeout)
            var id = CGWindowID(0)
            guard _AXUIElementGetWindow(window, &id) == .success else { return nil }
            var subrole: CFTypeRef?
            let switchable: Bool
            switch AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) {
            case .success: switchable = !deniedSubroles.contains(subrole as? String ?? "")
            case .noValue, .attributeUnsupported: switchable = true
            default: return nil
            }
            var minimized: CFTypeRef?
            let isMinimized =
                AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success
                && minimized as? Bool ?? false
            found[id] = (switchable, isMinimized)
        }
        return (found, windows)
    }
}

/// Runs on the observer thread: reads the pid of the new window or sheet, or of the minimized or restored window, and
/// hands it to the classifier's queue.
private let observerCallback: AXObserverCallback = { _, element, _, refcon in
    var pid: pid_t = 0
    guard let refcon, AXUIElementGetPid(element, &pid) == .success else { return }
    Unmanaged<AXWindowClassifier>.fromOpaque(refcon).takeUnretainedValue().changed(pid: pid)
}
