import AppKit

/// Runs the switcher: a hotkey press reads the windows and starts a `SwitcherSession`, a hold shows the
/// panel, the release of the modifier commits it, and a commit focuses the chosen window. Between sessions the
/// only work is event-driven: a one-off classifier refresh of every app and background thumbnail capture when the
/// switcher starts, and nothing periodic (no timer, no polling, no animation); what is left is the Carbon hotkeys,
/// four workspace observers (an app activation refreshes the window classifier and has it watch that app, an app
/// that hides is refreshed, a Space switch refreshes every app the classifier knows, an app that quits is
/// forgotten) and the classifier's Accessibility observer of the frontmost app.
@MainActor
final class SwitcherController {
    private let monitor = HotkeyMonitor()
    /// Created once, when Accessibility is granted, and kept for the life of the process.
    private var watcher: ModifierWatcher?
    private var session = SwitcherSession()
    /// The windows of the current session: the on-screen ones front to back, then the listed off-screen ones. The
    /// session's indexes point into it.
    private var list: [WindowSnapshot] = []
    /// The hidden regular apps at the session's press: with `list`, they give each tile its `WindowState`.
    private var hiddenPIDs: Set<pid_t> = []
    /// Fires 100 ms after the press, when the modifier is still held. It exists only while a session is pending.
    private var holdTimer: DispatchWorkItem?
    private var armedModifier: HotkeyModifier?  // nil = the hotkeys are not taken
    /// Exists only while the hotkeys could not be taken.
    private var activeObserver: NSObjectProtocol?
    /// Tells sheets from real windows and knows minimized ones. Refreshed for every regular app at `start`, then on
    /// an app activation, an app hide, a Space switch, when the frontmost app creates a window or a sheet or minimizes
    /// or restores a window, and at the end of a session that listed unknown windows; an app that quits is forgotten.
    /// The workspace observers and the frontmost app's watch live from `start` to `stop`.
    private let classifier = AXWindowClassifier()
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Built by `warmPanel` while the first held session waits for its hold timer (or by the first show), then kept.
    private var panel: SwitcherPanel?
    /// Where and how big the current session's panel is, fixed at the press. nil before the first session.
    private var layout: (screen: NSScreen, panelSize: CGSize, thumbnail: CGSize, icon: CGFloat)?
    /// True from `showPanel` to the hide: a quick tap never touches the panel.
    private var panelShown = false
    /// Counts the shows, so a fade that ends after a new show leaves the panel alone.
    private var showGeneration = 0
    /// App icons by pid, rendered once at max(icon side, 64) points x `iconScale`. Emptied when it reaches
    /// 64 entries or the screen scale changes.
    private var icons: [pid_t: CGImage] = [:]
    private var iconScale: CGFloat = 0
    /// Window thumbnails, made at `thumbnailBox` (the preferred box, even when a session's box shrinks) x the panel
    /// screen's scale in a session, or the window's display scale when prefetched; emptied when the box changes.
    private let thumbnails = ThumbnailCache()
    private var thumbnailBox: CGSize = .zero
    /// The selected tile while the panel shows: the capture order starts there.
    private var selectedIndex = 0
    /// Fires 200 ms after `showPanel` and starts `captureTask`. Both exist only while the panel shows.
    private var captureTimer: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?
    /// A background capture between sessions: it only fills the cache. A session start cancels it.
    private var prefetchTask: Task<Void, Never>?

    func start() {
        monitor.onPress = { [weak self] key in self?.pressed(key) }
        arm()
        observeWorkspace()
        if let app = NSWorkspace.shared.frontmostApplication, app.activationPolicy == .regular {
            classifier.watch(pid: app.processIdentifier)
        }
        // Every app running before CmdTab started: without an activation or a hide, its hidden and minimized windows
        // would stay unknown.
        if let byPID = AXWindowClassifier.onScreenIDsByPID() {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                classifier.refresh(pid: app.processIdentifier, onScreenIDs: byPID[app.processIdentifier] ?? [])
            }
        }
        // The first press on any screen finds thumbnails: the frontmost windows of all screens, as many as fit.
        if CGPreflightScreenCaptureAccess() {
            let snapshot = WindowSource.snapshot()
            let admitted = WindowFilter.admitted(
                snapshot.all, regularPIDs: snapshot.regularPIDs, isSwitchable: classifier.isSwitchable)
            prefetch(admitted.prefix(ThumbnailCache.capacity).map(\.id))
        }
    }

    func stop() {
        apply(session.handle(.cancel))
        // While idle the cancel has no effects, so a prefetch would outlive the switcher.
        cancelCapture()
        monitor.disarm()
        armedModifier = nil
        stopObserving()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        classifier.stopWatching()
    }

    /// Call after a setting changed.
    func applyPreferences() {
        // The cached thumbnails were made for another box.
        if Preferences.thumbnailSize.box != thumbnailBox {
            thumbnails.removeAll()
            thumbnailBox = Preferences.thumbnailSize.box
        }
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

    // MARK: Classifier triggers

    private func observeWorkspace() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let key = NSWorkspace.applicationUserInfoKey
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
                [weak self] note in
                guard let app = note.userInfo?[key] as? NSRunningApplication, app.activationPolicy == .regular
                else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated {
                    self?.classify(pid: pid)
                    self?.classifier.watch(pid: pid)
                }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
                [weak self] note in
                guard let pid = (note.userInfo?[key] as? NSRunningApplication)?.processIdentifier else { return }
                MainActor.assumeIsolated { self?.classifier.forget(pid: pid) }
            },
            // A hidden app has no on-screen window; Accessibility still lists its windows.
            center.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) {
                [weak self] note in
                guard let app = note.userInfo?[key] as? NSRunningApplication, app.activationPolicy == .regular
                else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated { self?.classifier.refresh(pid: pid, onScreenIDs: []) }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.classifySpace() }
            },
        ]
    }

    /// The Space changed: one WindowServer read, then a refresh off-main of every app the classifier knows, so the
    /// windows of the Space left behind go. An app with no on-screen window here gets an empty `onScreenIDs`.
    private func classifySpace() {
        guard let byPID = AXWindowClassifier.onScreenIDsByPID() else { return }
        for pid in classifier.knownPIDs() {
            classifier.refresh(pid: pid, onScreenIDs: byPID[pid] ?? [])
        }
    }

    /// An app came forward: one WindowServer read for its on-screen layer-0 windows, then a refresh off-main.
    private func classify(pid: pid_t) {
        guard let ids = AXWindowClassifier.onScreenIDs(pid: pid) else { return }
        classifier.refresh(pid: pid, onScreenIDs: ids)
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

    /// The hotkey was pressed while idle. Main thread: only the window list, two settings, the screen, the pure filter
    /// and layout arithmetic, and the session.
    private func beginSession(reverse: Bool) {
        let press = Perf.begin("press")
        defer { Perf.end(press) }
        cancelCapture()
        // Trust can be taken away while the app runs: without it the Dock gets its switcher back.
        guard AXIsProcessTrusted(), let watcher, let armedModifier else { return disarmAndWait() }

        // Off-screen windows are read only when one of the two settings lists some.
        let showMinimized = Preferences.showMinimized, showHidden = Preferences.showHiddenApps
        let snapshot = WindowSource.snapshot(includeOffScreen: showMinimized || showHidden)
        hiddenPIDs = snapshot.hiddenPIDs
        list = WindowFilter.list(
            all: snapshot.all, regularPIDs: snapshot.regularPIDs, displays: snapshot.displays, mouse: snapshot.mouse,
            scope: Preferences.screenScope, isSwitchable: classifier.isSwitchable, hiddenPIDs: snapshot.hiddenPIDs,
            showMinimized: showMinimized, showHidden: showHidden, isMinimized: classifier.isMinimized,
            isKnownWindow: classifier.isKnownWindow)
        let screen =
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    == snapshot.mouseDisplay
            } ?? NSScreen.main
        guard !list.isEmpty, let screen else {
            // Nothing to switch to (or no screen), so no session. This registers no key: it only stops the repeat
            // of the held Tab, which would run this path again and again.
            monitor.setSessionKeys(false)
            return
        }
        // Only the windows the panel can draw: the session's indexes then always point at a drawn tile. With
        // "Shrink to fit" the box (and the icon with it) first shrinks so more of them fit.
        let preferred = Preferences.thumbnailSize.box
        let preferredIcon = Preferences.appIconSize.side
        var thumbnail = preferred
        var icon = preferredIcon
        if Preferences.shrinkToFit {
            thumbnail = SwitcherView.fittingThumbnail(
                count: list.count, preferred: preferred, available: screen.visibleFrame.size)
            icon = thumbnail == preferred
                ? preferredIcon : max(16, (preferredIcon * thumbnail.width / preferred.width).rounded())
        }
        let fit = SwitcherView.layout(
            count: list.count, thumbnail: thumbnail, icon: icon, available: screen.visibleFrame.size)
        if fit.frames.count < list.count { list.removeLast(list.count - fit.frames.count) }
        layout = (screen, fit.panelSize, thumbnail, icon)

        let admittedAll = WindowFilter.admitted(
            snapshot.all, regularPIDs: snapshot.regularPIDs, isSwitchable: classifier.isSwitchable)
        let startIndex = WindowFilter.startIndex(
            list: list, admittedAll: admittedAll, frontmostPID: snapshot.frontmostPID)

        let modifier = armedModifier.cgFlag
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
        // The first held session builds the panel on the next main-queue turn, inside the 100 ms hold window.
        if panel == nil {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.warmPanel() }
            }
        }
    }

    /// Everything that exists only during a session goes: the hold timer, the thumbnail capture, the release
    /// detector, the session keys. The apps whose listed windows the classifier did not know yet are refreshed, each
    /// with all of its on-screen windows (not only the listed ones: a refresh replaces the app's entries), from one
    /// WindowServer read made only when there is such an app.
    private func endSession() {
        holdTimer?.cancel()
        holdTimer = nil
        cancelCapture()
        watcher?.end()
        monitor.setSessionKeys(false)
        let unknown = Set(list.filter { !classifier.knows($0.id) }.map(\.pid))
        guard !unknown.isEmpty, let byPID = AXWindowClassifier.onScreenIDsByPID() else { return }
        for pid in unknown {
            classifier.refresh(pid: pid, onScreenIDs: byPID[pid] ?? [])
        }
    }

    private func apply(_ effects: [SwitcherSession.Effect]) {
        for effect in effects {
            switch effect {
            case .commit(let index):
                endSession()
                // Focus first, then the hide. An index outside the list is dropped.
                if list.indices.contains(index) {
                    let window = list[index]
                    WindowFocus.focus(
                        windowID: window.id, pid: window.pid,
                        restore: WindowFilter.state(of: window, hiddenPIDs: hiddenPIDs) != .normal)
                }
                hidePanel()
            case .cancel:
                endSession()
                hidePanel()
            case .showPanel(let selected):
                showPanel(selected: selected)
            case .select(let index):
                let step = Perf.begin("step")
                selectedIndex = index
                panel?.switcherView.select(index)
                Perf.end(step)
            }
        }
    }

    // MARK: Panel

    /// The hold timer fired with the modifier still down. Main thread: the icons, the layer updates and the flush.
    private func showPanel(selected: Int) {
        let token = Perf.begin("showPanel")
        defer { Perf.end(token) }
        guard let layout else { return }
        let panel = self.panel ?? makePanel()
        let scale = layout.screen.backingScaleFactor
        // Thumbnails are made at the preferred box, even when the session's box shrank. An image of another size
        // (shrunk box, prefetched, or from a session on another screen) shows aspect-fit in the box.
        let box = Preferences.thumbnailSize.box
        if box != thumbnailBox { thumbnails.removeAll() }
        thumbnailBox = box
        let tiles = list.map { window in
            SwitcherView.Tile(
                id: window.id, title: window.title ?? window.ownerName,
                icon: icon(for: window.pid, side: max(layout.icon, 64), scale: scale), thumbnail: thumbnails[window.id],
                state: WindowFilter.state(of: window, hiddenPIDs: hiddenPIDs))
        }
        selectedIndex = selected

        showGeneration += 1
        if panel.isVisible {
            // The fade of the last session is still running: a zero-length animation replaces it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
        panel.place(size: layout.panelSize, centredIn: layout.screen.visibleFrame)
        panel.switcherView.show(tiles: tiles, selected: selected, thumbnail: layout.thumbnail, icon: layout.icon)
        panel.orderFrontRegardless()
        // `updateLayer` sets the colours of new tile layers: it runs before the flush.
        panel.displayIfNeeded()
        CATransaction.flush()
        panelShown = true
        scheduleCapture()
    }

    /// Does the one-time work of the first show while the hold timer runs: the panel, its frame on the session's
    /// screen, its layout and layers, and the session's icons. The panel stays off screen.
    private func warmPanel() {
        // A session that already ended (or showed) leaves it to the next one, or to `showPanel`.
        guard panel == nil, session.phase == .pending, let layout else { return }
        let token = Perf.begin("warmPanel")
        defer { Perf.end(token) }
        let panel = makePanel()
        let scale = layout.screen.backingScaleFactor
        // The thumbnails (prefetched or not) and the selection are set by `showPanel`.
        let tiles = list.map { window in
            SwitcherView.Tile(
                id: window.id, title: window.title ?? window.ownerName,
                icon: icon(for: window.pid, side: max(layout.icon, 64), scale: scale), thumbnail: nil,
                state: WindowFilter.state(of: window, hiddenPIDs: hiddenPIDs))
        }
        panel.place(size: layout.panelSize, centredIn: layout.screen.visibleFrame)
        panel.switcherView.show(tiles: tiles, selected: 0, thumbnail: layout.thumbnail, icon: layout.icon)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel()
        panel.switcherView.onHover = { [weak self] index in
            guard let self else { return }
            apply(session.handle(.hover(index)))
        }
        panel.switcherView.onClick = { [weak self] index in
            guard let self else { return }
            apply(session.handle(.click(index)))
        }
        self.panel = panel
        return panel
    }

    /// Hides the panel of the session that just ended, if it showed one: a fade (`HideAnimation.fade` without
    /// Reduce Motion) or at once.
    private func hidePanel() {
        guard panelShown, let panel else { return }
        panelShown = false
        guard Preferences.hideAnimation == .fade, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return panel.orderOut(nil)
        }
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new session showed the panel meanwhile: it is its panel now.
                guard let self, generation == self.showGeneration else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    // MARK: Thumbnails

    /// Refreshes the thumbnails 200 ms after the show, off the main thread, from the selected tile outwards,
    /// and only with Screen Recording (never asked for here). Cached images already show meanwhile.
    private func scheduleCapture() {
        cancelCapture()
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.startCapture() }
        }
        captureTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: timer)
    }

    private func startCapture() {
        captureTimer = nil
        guard panelShown, CGPreflightScreenCaptureAccess() else { return }
        let generation = showGeneration
        // The panel's screen, fixed for the session: every tile is drawn at its scale.
        let scale = layout?.screen.backingScaleFactor
        captureTask = Task { [weak self, thumbnailBox, ids = captureOrder()] in
            await WindowCapture.capture(ids, box: thumbnailBox, scale: scale) { id, image in
                // A late image of a panel that hid, or of an earlier show, is dropped.
                guard let self, self.panelShown, generation == self.showGeneration else { return }
                self.thumbnails.set(image, for: id)
                self.panel?.switcherView.setThumbnail(image, for: id)
            }
        }
    }

    /// The listed window ids by distance from the selected tile: selected, +1, -1, +2, -2, ...
    private func captureOrder() -> [CGWindowID] {
        guard list.indices.contains(selectedIndex) else { return list.map(\.id) }
        var ids = [list[selectedIndex].id]
        for distance in 1..<list.count {
            if list.indices.contains(selectedIndex + distance) { ids.append(list[selectedIndex + distance].id) }
            if list.indices.contains(selectedIndex - distance) { ids.append(list[selectedIndex - distance].id) }
        }
        return ids
    }

    /// Fills the cache with `ids` off the main thread while no session runs, and only with Screen Recording (never
    /// asked for here). The panel is never touched.
    private func prefetch(_ ids: [CGWindowID]) {
        guard !ids.isEmpty, session.phase == .idle, CGPreflightScreenCaptureAccess() else { return }
        // No show has run yet.
        if thumbnailBox == .zero { thumbnailBox = Preferences.thumbnailSize.box }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self, box = thumbnailBox] in
            await WindowCapture.capture(ids, box: box, scale: nil) { id, image in
                // An image made for an earlier box is dropped.
                guard let self, self.thumbnailBox == box else { return }
                self.thumbnails.set(image, for: id)
            }
        }
    }

    /// Stops the session's capture and any prefetch: the session's own capture takes over.
    private func cancelCapture() {
        captureTimer?.cancel()
        captureTimer = nil
        captureTask?.cancel()
        captureTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    /// The app icon of `pid`, rendered once into a `side`-point square at `scale`. One image serves the corner
    /// icon and the no-thumbnail placeholder.
    private func icon(for pid: pid_t, side: CGFloat, scale: CGFloat) -> CGImage? {
        if scale != iconScale {
            icons.removeAll()
            iconScale = scale
        }
        if let icon = icons[pid] { return icon }
        guard let image = NSRunningApplication(processIdentifier: pid)?.icon,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let pixels = Int((side * scale).rounded())
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let icon = context.makeImage() else { return nil }
        if icons.count >= 64 { icons.removeAll() }
        icons[pid] = icon
        return icon
    }
}
