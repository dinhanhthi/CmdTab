// Throwaway platform spike (Phase 1 gate), DEBUG only and deleted in Phase 2.
// `CmdTab --spike <mode> --out <file>`: each mode writes one JSON file and one Perf log line.
// Run it only in a virtual machine: `hotkey`, `focus` and `restore` change the system-wide Cmd+Tab state,
// `permissions` and `capture` raise permission prompts. `windows` only reads.
#if DEBUG
import AppKit
import Carbon.HIToolbox
import os
import ScreenCaptureKit
import Synchronization

enum SpikeRunner {
    /// The Dock's Cmd+Tab and Cmd+Shift+Tab in the WindowServer's symbolic-hotkey table.
    static let dockHotKeys: [Int32] = [1, 2]

    @MainActor
    static func run(arguments: [String]) {
        guard let mode = value(after: "--spike", in: arguments),
              let path = value(after: "--out", in: arguments) else {
            fail("usage: CmdTab --spike <mode> --out <file>")
        }
        let out = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        switch mode {
        case "hotkey": HotkeySpike.start(out: out)
        case "restore": restore(out: out)
        case "permissions": permissions(out: out)
        case "windows": WindowsSpike.start(out: out)
        case "capture":
            guard let api = value(after: "--api", in: arguments), api == "sck" || api == "private" else {
                fail("usage: CmdTab --spike capture --api sck|private --out <file>")
            }
            CaptureSpike.start(api: api, out: out)
        case "focus":
            guard let wid = value(after: "--wid", in: arguments).flatMap({ CGWindowID($0) }),
                  let pid = value(after: "--pid", in: arguments).flatMap({ pid_t($0) }) else {
                fail("usage: CmdTab --spike focus --wid <window id> --pid <pid> --out <file>")
            }
            HotkeySpike.start(out: out, focus: FocusSpike.Target(wid: wid, pid: pid))
        default: fail("unknown spike mode: \(mode)")
        }
    }

    // MARK: Modes that exit at once

    private struct RestoreReport: Encodable {
        let mode = "restore"
        let enabledBefore: [Bool]
        let restoreErrors: [Int32]
        let enabledAfter: [Bool]
    }

    private static func restore(out: URL) -> Never {
        let before = dockHotKeysEnabled()
        let errors = restoreDockHotKeys()
        finish(RestoreReport(enabledBefore: before, restoreErrors: errors, enabledAfter: dockHotKeysEnabled()), out: out)
    }

    private struct PermissionsReport: Encodable {
        let mode = "permissions"
        let accessibility: Bool
        let screenRecording: Bool
    }

    /// Asks for both permissions so CmdTab is listed in both privacy panes, then reports the current states.
    private static func permissions(out: URL) -> Never {
        // The value of `kAXTrustedCheckOptionPrompt`, a global var Swift 6 rejects as not concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
        finish(
            PermissionsReport(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess()),
            out: out)
    }

    // MARK: Shared helpers

    /// Re-enables the Dock's two hotkeys. Returns the CGError of each call (0 = success).
    static func restoreDockHotKeys() -> [Int32] {
        dockHotKeys.map { CGSSetSymbolicHotKeyEnabled($0, true).rawValue }
    }

    static func dockHotKeysEnabled() -> [Bool] {
        dockHotKeys.map { CGSIsSymbolicHotKeyEnabled($0) }
    }

    /// Writes the mode's JSON, emits the Perf line and exits.
    static func finish<Report: Encodable>(_ report: Report, out: URL, exitCode: Int32 = 0) -> Never {
        var exitCode = exitCode
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: out, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("spike: cannot write \(out.path): \(error)\n".utf8))
            exitCode = 1
        }
        // The format `Perf` uses later, so gate (h) reads the real thing: a public name and a number.
        let name = "spike"
        let ms = 1.0
        Logger(subsystem: "com.math2it.cmdtab", category: "Perf")
            .notice("perf \(name, privacy: .public) \(ms, format: .fixed(precision: 2))")
        exit(exitCode)
    }

    /// `finish` for a mode that ends on a background thread: `exit` runs on the main thread.
    static func finishOnMain<Report: Encodable & Sendable>(_ report: Report, out: URL, exitCode: Int32 = 0) {
        DispatchQueue.main.async { finish(report, out: out, exitCode: exitCode) }
    }

    /// Milliseconds since `start` (uptime nanoseconds), at microsecond resolution.
    static func ms(since start: UInt64) -> Double {
        Double((DispatchTime.now().uptimeNanoseconds - start) / 1000) / 1000
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("spike: \(message)\n".utf8))
        exit(2)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

// MARK: - Mode `hotkey`

/// Takes Cmd+Tab from the Dock and records what arrives, until SIGTERM.
/// A session runs from the first Cmd+Tab press to the release of Command.
@MainActor
private enum HotkeySpike {
    enum Kind: String, Encodable {
        case hotkeyPressed, hotkeyReleased, tapRelease, pollRelease, tapDisabled
    }

    /// `id`: the Carbon hotkey id; for `tapDisabled` 1 = by timeout, 2 = by user input; otherwise 0.
    struct Event: Encodable {
        let t: Double  // ms since the spike started, monotonic
        let kind: Kind
        let id: UInt32
        let secureInput: Bool
    }

    struct Report: Encodable {
        var mode = "hotkey"
        var axTrusted: Bool
        var handlerStatus: Int32?
        var registerStatus: [String: Int32] = [:]  // Carbon hotkey id → OSStatus of its last registration
        var tapCreated = false
        var enabledBefore: [Bool]?
        var disableErrors: [Int32]?
        var enabledAfterDisable: [Bool]?
        var restoreErrors: [Int32]?
        var enabledAfterRestore: [Bool]?
        var events: [Event] = []
        var focus: FocusSpike.Report?  // mode `focus` only
    }

    /// What the tap thread shares with the main thread.
    struct Shared {
        var events: [Event] = []
        var sessionActive = false  // the tap is wanted
        var tapReleaseSeen = false  // one `tapRelease` per session
    }

    nonisolated static let shared = Mutex(Shared())
    nonisolated static let clockStart = DispatchTime.now().uptimeNanoseconds
    /// Written once on the main thread, before the tap thread starts; read-only afterwards.
    nonisolated(unsafe) static var tap: CFMachPort?

    static var report = Report(axTrusted: true)
    static var out: URL?
    /// Set in mode `focus`: same setup and exit paths, but a press raises this window instead of starting a session.
    static var focusTarget: FocusSpike.Target?
    static var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    static var signalSources: [DispatchSourceSignal] = []
    static var sampler: DispatchSourceTimer?
    static var pollArmed = false  // one `pollRelease` per session
    static var sessionEnd: DispatchWorkItem?

    static let sessionKeys: [(id: UInt32, key: Int)] = [(3, kVK_LeftArrow), (4, kVK_RightArrow), (5, kVK_Escape)]
    /// How long the slower release detector gets to report after the faster one.
    static let releaseGrace = DispatchTimeInterval.milliseconds(200)

    static func start(out: URL, focus target: FocusSpike.Target? = nil) {
        self.out = out
        focusTarget = target
        if target != nil { report.mode = "focus" }
        _ = clockStart
        guard AXIsProcessTrusted() else {
            report.axTrusted = false
            SpikeRunner.finish(report, out: out, exitCode: 1)
        }

        // Everything that can fail comes before the Dock's hotkeys are touched.
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handlerStatus = InstallEventHandler(GetEventDispatcherTarget(), hotKeyHandler, types.count, &types, nil, nil)
        report.handlerStatus = handlerStatus
        register(1, key: kVK_Tab, modifiers: cmdKey)
        // `focus` needs Cmd+Tab only: no Cmd+Shift+Tab, no release detection.
        if target == nil { register(2, key: kVK_Tab, modifiers: cmdKey | shiftKey) }
        guard handlerStatus == noErr, hotKeyRefs[1] != nil, target != nil || hotKeyRefs[2] != nil else {
            SpikeRunner.finish(report, out: out, exitCode: 1)
        }
        if target == nil { startTap() }
        installExitHandlers()

        report.enabledBefore = SpikeRunner.dockHotKeysEnabled()
        report.disableErrors = SpikeRunner.dockHotKeys.map { CGSSetSymbolicHotKeyEnabled($0, false).rawValue }
        report.enabledAfterDisable = SpikeRunner.dockHotKeysEnabled()
    }

    /// Every exit this process can see gives Cmd+Tab back to the Dock first.
    static func stop() -> Never {
        report.restoreErrors = SpikeRunner.restoreDockHotKeys()
        report.enabledAfterRestore = SpikeRunner.dockHotKeysEnabled()
        report.events = shared.withLock { $0.events }.sorted { $0.t < $1.t }
        if let focusTarget { report.focus = FocusSpike.report(for: focusTarget) }
        SpikeRunner.finish(report, out: out ?? URL(fileURLWithPath: "/dev/null"))
    }

    static func installExitHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            // The default action would kill the process before the source fires.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { stop() } }
            source.resume()
            signalSources.append(source)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { stop() }
        }
    }

    // MARK: Carbon hotkeys (main thread)

    static func register(_ id: UInt32, key: Int, modifiers: Int) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x436D_6454 /* CmdT */, id: id),
            GetEventDispatcherTarget(), 0, &ref)
        report.registerStatus[String(id)] = status
        if status == noErr { hotKeyRefs[id] = ref }
    }

    static func unregisterSessionKeys() {
        for (id, _) in sessionKeys {
            if let ref = hotKeyRefs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        }
    }

    static func hotKey(id: UInt32, pressed: Bool) {
        record(pressed ? .hotkeyPressed : .hotkeyReleased, id: id)
        guard pressed, id == 1 || id == 2 else { return }
        if let focusTarget { return FocusSpike.press(focusTarget) }
        // A press in the grace period after a release starts a new session.
        if sessionEnd != nil { endSession() }
        if !shared.withLock({ $0.sessionActive }) { beginSession() }
    }

    // MARK: Session (main thread)

    static func beginSession() {
        shared.withLock {
            $0.sessionActive = true
            $0.tapReleaseSeen = false
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        for (id, key) in sessionKeys { register(id, key: key, modifiers: cmdKey) }

        pollArmed = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16), leeway: .milliseconds(1))
        timer.setEventHandler { MainActor.assumeIsolated { poll() } }
        timer.resume()
        sampler = timer
        poll()  // Command may already be up at press time
    }

    static func poll() {
        guard pollArmed, !CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) else { return }
        pollArmed = false
        record(.pollRelease)
        releaseDetected()
    }

    /// The first detector to see the release drops the session keys at once;
    /// the session itself ends after the grace period, so the other detector can still report.
    static func releaseDetected() {
        let tapSawIt = shared.withLock { $0.sessionActive && $0.tapReleaseSeen }
        // A late hop from the tap thread may land in the next session, where nothing was released yet.
        guard sessionEnd == nil, tapSawIt || (sampler != nil && !pollArmed) else { return }
        unregisterSessionKeys()
        let end = DispatchWorkItem { MainActor.assumeIsolated { endSession() } }
        sessionEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseGrace, execute: end)
    }

    static func endSession() {
        sessionEnd?.cancel()
        sessionEnd = nil
        shared.withLock { $0.sessionActive = false }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        sampler?.cancel()
        sampler = nil
        pollArmed = false
        unregisterSessionKeys()
    }

    // MARK: Event tap (its own thread)

    /// Listen-only and disabled while no session runs, as the shipping tap will be.
    static func startTap() {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
            callback: tapCallback, userInfo: nil)
        else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        tap = port
        report.tapCreated = true
        let thread = Thread {
            guard let port = tap else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CFRunLoopRun()
        }
        thread.name = "com.math2it.cmdtab.spike.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    nonisolated static func tapSawRelease() {
        let event = makeEvent(.tapRelease, id: 0)
        let first = shared.withLock { state -> Bool in
            guard state.sessionActive, !state.tapReleaseSeen else { return false }
            state.tapReleaseSeen = true
            state.events.append(event)
            return true
        }
        if first {
            DispatchQueue.main.async { MainActor.assumeIsolated { releaseDetected() } }
        }
    }

    nonisolated static func tapWasDisabled(byTimeout: Bool) {
        record(.tapDisabled, id: byTimeout ? 1 : 2)
        // Outside a session the tap is meant to be off.
        if shared.withLock({ $0.sessionActive }), let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: Recording (any thread)

    nonisolated static func makeEvent(_ kind: Kind, id: UInt32) -> Event {
        let ns = DispatchTime.now().uptimeNanoseconds - clockStart
        return Event(t: Double(ns / 1000) / 1000, kind: kind, id: id, secureInput: IsSecureEventInputEnabled())
    }

    nonisolated static func record(_ kind: Kind, id: UInt32 = 0) {
        let event = makeEvent(kind, id: id)
        shared.withLock { $0.events.append(event) }
    }
}

// MARK: - Window list (modes `windows`, `capture`, `focus`)

/// One on-screen window that passes the admission rule, as the WindowServer lists it.
private struct SpikeWindow: Sendable {
    let id: CGWindowID
    let owner: String
    let pid: pid_t
    let title: String?  // absent without the Screen Recording permission
    let bounds: CGRect  // points, global, origin at the top left of the main display
}

@MainActor
private enum WindowList {
    /// Layer 0, alpha > 0, at least 100 x 100 points, owned by a regular app. Front to back.
    static func admitted() -> [SpikeWindow] {
        let regular = Set(
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let rect = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rect),
                  bounds.width >= 100, bounds.height >= 100,
                  regular.contains(pid) else { return nil }
            return SpikeWindow(
                id: id, owner: info[kCGWindowOwnerName as String] as? String ?? "", pid: pid,
                title: info[kCGWindowName as String] as? String, bounds: bounds)
        }
    }
}

/// Accessibility reads and actions. Every call runs on `queue`, never on the main thread.
private enum SpikeAX {
    static let queue = DispatchQueue(label: "com.math2it.cmdtab.spike.ax", qos: .userInitiated)
    static let timeout: Float = 0.25

    /// The app's window elements by CGWindowID, with the AXError of the query.
    static func windows(of pid: pid_t) -> (error: AXError, windows: [CGWindowID: AXUIElement]) {
        dispatchPrecondition(condition: .onQueue(queue))
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success, let elements = value as? [AXUIElement] else { return (error, [:]) }
        var windows: [CGWindowID: AXUIElement] = [:]
        for element in elements {
            // The timeout of the app element does not carry over to its window elements.
            AXUIElementSetMessagingTimeout(element, timeout)
            var id = CGWindowID(0)
            if _AXUIElementGetWindow(element, &id) == .success { windows[id] = element }
        }
        return (error, windows)
    }

    static func subrole(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

// MARK: - Mode `windows`

/// Dumps the admitted windows, front to back, as a JSON array.
private enum WindowsSpike {
    struct Bounds: Encodable, Sendable {
        let x, y, width, height: Double
    }

    struct Entry: Encodable, Sendable {
        let id: UInt32
        let owner: String
        let pid: Int32
        let title: String?
        let bounds: Bounds
        /// The AX subrole; `noAXWindow` when the app lists no element with this window id;
        /// `noSubrole` when the element exists and its subrole cannot be read.
        let subrole: String
        /// AXError of the owner's `kAXWindowsAttribute` query: 0 = success, -25211 = Accessibility not granted,
        /// -25204 = no answer within the timeout.
        let axError: Int32
    }

    @MainActor
    static func start(out: URL) {
        let windows = WindowList.admitted()
        SpikeAX.queue.async {
            var apps: [pid_t: (error: AXError, windows: [CGWindowID: AXUIElement])] = [:]
            let entries = windows.map { window in
                let app = apps[window.pid] ?? SpikeAX.windows(of: window.pid)
                apps[window.pid] = app
                let subrole = app.windows[window.id].map { SpikeAX.subrole(of: $0) ?? "noSubrole" } ?? "noAXWindow"
                let bounds = Bounds(
                    x: window.bounds.minX, y: window.bounds.minY, width: window.bounds.width,
                    height: window.bounds.height)
                return Entry(
                    id: window.id, owner: window.owner, pid: window.pid, title: window.title, bounds: bounds,
                    subrole: subrole, axError: app.error.rawValue)
            }
            SpikeRunner.finishOnMain(entries, out: out)
        }
    }
}

// MARK: - Mode `capture`

/// Times one capture API on every admitted window: `rounds` thumbnails each, inside a `box` of pixels.
private enum CaptureSpike {
    static let box = (width: 480, height: 300)
    static let rounds = 5
    /// The option bits yabai (MIT) passes to this call in `window_manager.c`.
    static let privateOptions: UInt32 = (1 << 11) | (1 << 8)

    struct WindowResult: Encodable, Sendable {
        let id: UInt32
        let owner: String
        let pid: Int32
        var width = 0  // pixels of the last thumbnail
        var height = 0
        var ms: [Double] = []  // one per round that returned an image
        var medianMs: Double?
        var maxMs: Double?
        var blankRounds = 0  // rounds whose thumbnail had one colour only
        var blank = true  // a round without an image, or a blank round
        var error: String?  // the last failure

        init(_ window: SpikeWindow) {
            id = window.id
            owner = window.owner
            pid = window.pid
        }

        /// `thumbnail` is the image of this round as a bitmap; every pixel is compared with the first one.
        mutating func add(ms: Double, thumbnail: CGContext, width: Int, height: Int) {
            self.ms.append(ms)
            self.width = width
            self.height = height
            if CaptureSpike.isBlank(thumbnail) { blankRounds += 1 }
        }

        mutating func close() {
            medianMs = CaptureSpike.median(ms)
            maxMs = ms.max()
            blank = ms.count < CaptureSpike.rounds || blankRounds > 0
        }
    }

    struct Report: Encodable, Sendable {
        let mode = "capture"
        let api: String
        let screenRecording: Bool  // CGPreflightScreenCaptureAccess() at start
        let boxWidth = CaptureSpike.box.width
        let boxHeight = CaptureSpike.box.height
        let rounds = CaptureSpike.rounds
        var privateOptions: UInt32?  // api `private` only
        var lookupMs = 0.0
        var lookupError: String?
        var medianMs: Double?  // over every round of every window
        var worstWindowMedianMs: Double?
        var blankWindows = 0
        var png: String?  // the first image, when one was written
        var windows: [WindowResult] = []
    }

    @MainActor
    static func start(api: String, out: URL) {
        let windows = WindowList.admitted()
        let report = Report(api: api, screenRecording: CGPreflightScreenCaptureAccess())
        Task.detached {
            if api == "sck" {
                await captureWithScreenCaptureKit(windows, report: report, out: out)
            } else {
                captureWithWindowServer(windows, report: report, out: out)
            }
        }
    }

    // MARK: ScreenCaptureKit

    /// A round = content filter + configuration + `captureImage`. The one lookup before is `lookupMs`.
    static func captureWithScreenCaptureKit(_ windows: [SpikeWindow], report: Report, out: URL) async {
        var report = report
        var first: CGImage?
        let lookupStart = DispatchTime.now().uptimeNanoseconds
        var shareable: [CGWindowID: SCWindow] = [:]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            for window in content.windows { shareable[window.windowID] = window }
        } catch {
            report.lookupError = describe(error)
        }
        report.lookupMs = SpikeRunner.ms(since: lookupStart)

        for window in windows {
            var result = WindowResult(window)
            let size = fit(window.bounds.size)
            if let shareableWindow = shareable[window.id] {
                for _ in 0..<rounds {
                    let start = DispatchTime.now().uptimeNanoseconds
                    do {
                        let configuration = SCStreamConfiguration()
                        configuration.width = size.width
                        configuration.height = size.height
                        configuration.showsCursor = false
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(desktopIndependentWindow: shareableWindow),
                            configuration: configuration)
                        let ms = SpikeRunner.ms(since: start)
                        // Outside the timed span: a bitmap of a known layout, only to compare the pixels.
                        guard let thumbnail = thumbnail(of: image, size: size) else {
                            result.error = "no bitmap"
                            continue
                        }
                        result.add(ms: ms, thumbnail: thumbnail, width: image.width, height: image.height)
                        if first == nil { first = image }
                    } catch {
                        result.error = describe(error)
                    }
                }
            } else {
                result.error = report.lookupError == nil ? "not in SCShareableContent" : "no lookup"
            }
            result.close()
            report.windows.append(result)
        }
        finish(report, first: first, out: out)
    }

    // MARK: CGSHWCaptureWindowList

    /// A round = the WindowServer capture + the downscale into the box. `lookupMs` is `CGSMainConnectionID`.
    static func captureWithWindowServer(_ windows: [SpikeWindow], report: Report, out: URL) {
        var report = report
        var first: CGImage?
        report.privateOptions = privateOptions
        let lookupStart = DispatchTime.now().uptimeNanoseconds
        let connection = CGSMainConnectionID()
        report.lookupMs = SpikeRunner.ms(since: lookupStart)

        for window in windows {
            var result = WindowResult(window)
            let size = fit(window.bounds.size)
            for _ in 0..<rounds {
                // A wrong ownership annotation on the private call would crash here, when the pool drains.
                autoreleasepool {
                    let start = DispatchTime.now().uptimeNanoseconds
                    var id = window.id
                    // Create rule (the header says CF_RETURNS_RETAINED): Swift owns the array and releases it
                    // at the end of this scope. Its images are only borrowed from it.
                    guard let images = CGSHWCaptureWindowList(connection, &id, 1, privateOptions),
                          CFArrayGetCount(images) > 0, let pointer = CFArrayGetValueAtIndex(images, 0) else {
                        result.error = "no image"
                        return
                    }
                    let image = Unmanaged<CGImage>.fromOpaque(pointer).takeUnretainedValue()
                    guard let thumbnail = thumbnail(of: image, size: size) else {
                        result.error = "no bitmap"
                        return
                    }
                    let ms = SpikeRunner.ms(since: start)
                    result.add(ms: ms, thumbnail: thumbnail, width: thumbnail.width, height: thumbnail.height)
                    if first == nil { first = thumbnail.makeImage() }
                }
            }
            result.close()
            report.windows.append(result)
        }
        finish(report, first: first, out: out)
    }

    // MARK: Shared

    static func finish(_ report: Report, first: CGImage?, out: URL) {
        var report = report
        report.medianMs = median(report.windows.flatMap(\.ms))
        report.worstWindowMedianMs = report.windows.compactMap(\.medianMs).max()
        report.blankWindows = report.windows.count { $0.blank }
        if let first {
            let url = URL(fileURLWithPath: out.path + ".png")
            let data = NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:])
            try? FileManager.default.createDirectory(
                at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data, (try? data.write(to: url, options: .atomic)) != nil { report.png = url.path }
        }
        // Not a measurement: nothing to capture, or a window that never gave an image.
        let failed = report.windows.isEmpty || report.windows.contains { $0.ms.isEmpty }
        SpikeRunner.finishOnMain(report, out: out, exitCode: failed ? 1 : 0)
    }

    /// The pixel size of a window of `size` points, scaled to fit the box with its aspect ratio kept.
    static func fit(_ size: CGSize) -> (width: Int, height: Int) {
        let scale = min(Double(box.width) / size.width, Double(box.height) / size.height)
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// `image` drawn into a BGRA bitmap of `size` pixels.
    static func thumbnail(of image: CGImage, size: (width: Int, height: Int)) -> CGContext? {
        let layout = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: layout)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context
    }

    /// True when every pixel of the bitmap equals the first one.
    static func isBlank(_ bitmap: CGContext) -> Bool {
        guard let data = bitmap.data else { return true }
        let first = data.load(as: UInt32.self)
        for y in 0..<bitmap.height {
            let row = data.advanced(by: y * bitmap.bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<bitmap.width where row[x] != first { return false }
        }
        return true
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }
}

// MARK: - Mode `focus`

/// Each Cmd+Tab press brings one window of another app forward by the public route:
/// AXMain + AXRaise off the main thread, then `activate()`. `HotkeySpike` owns the hotkey and the exit paths.
@MainActor
private enum FocusSpike {
    struct Target: Sendable {
        let wid: CGWindowID
        let pid: pid_t
    }

    /// What the Accessibility queue did. The errors are AXError values: 0 = success.
    struct Raise: Encodable, Sendable {
        let windowsError: Int32  // the `kAXWindowsAttribute` query
        var windowFound = false  // an element with the target's window id
        var setMainError: Int32?
        var raiseError: Int32?
    }

    struct Press: Encodable {
        let t: Double  // ms since the spike started, the clock of `events`
        let appActive: Bool  // NSApp.isActive, read in the Carbon handler
        let frontmostPidBefore: Int32?  // read in the Carbon handler
        let zOrderBefore: [UInt32]  // admitted window ids, front to back, read in the Carbon handler
        var raise: Raise?
        var activateCalled: Bool?  // false when the target's app was already frontmost
        var activateResult: Bool?
        var focusMs: Double?  // press → the focus calls returned
        var zOrderAfter: [UInt32]?  // 500 ms after the focus calls returned
        var frontmostPidAfter: Int32?
    }

    struct Report: Encodable {
        let wid: UInt32
        let pid: Int32
        let presses: [Press]
    }

    static var presses: [Press] = []

    static func report(for target: Target) -> Report {
        Report(wid: target.wid, pid: target.pid, presses: presses)
    }

    /// Called from the Carbon hotkey handler.
    static func press(_ target: Target) {
        let start = DispatchTime.now().uptimeNanoseconds
        let index = presses.count
        presses.append(Press(
            t: Double((start - HotkeySpike.clockStart) / 1000) / 1000, appActive: NSApp.isActive,
            frontmostPidBefore: frontmostPid(), zOrderBefore: zOrder()))
        SpikeAX.queue.async {
            let raise = raise(target)
            DispatchQueue.main.async { MainActor.assumeIsolated { raised(raise, target, index: index, start: start) } }
        }
    }

    /// On the Accessibility queue.
    nonisolated static func raise(_ target: Target) -> Raise {
        let app = SpikeAX.windows(of: target.pid)
        var raise = Raise(windowsError: app.error.rawValue)
        guard let window = app.windows[target.wid] else { return raise }
        raise.windowFound = true
        raise.setMainError = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue).rawValue
        raise.raiseError = AXUIElementPerformAction(window, kAXRaiseAction as CFString).rawValue
        return raise
    }

    /// Back on the main thread: the app is activated even when its window did not answer.
    static func raised(_ raise: Raise, _ target: Target, index: Int, start: UInt64) {
        presses[index].raise = raise
        let activate = frontmostPid() != target.pid
        presses[index].activateCalled = activate
        if activate {
            presses[index].activateResult = NSRunningApplication(processIdentifier: target.pid)?.activate()
        }
        presses[index].focusMs = SpikeRunner.ms(since: start)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
            MainActor.assumeIsolated {
                presses[index].zOrderAfter = zOrder()
                presses[index].frontmostPidAfter = frontmostPid()
            }
        }
    }

    static func frontmostPid() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func zOrder() -> [UInt32] {
        WindowList.admitted().map(\.id)
    }
}

/// Runs on the main thread, from the Carbon event dispatcher.
private let hotKeyHandler: EventHandlerUPP = { _, event, _ in
    var hotKey = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    guard status == noErr else { return status }
    let id = hotKey.id
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    MainActor.assumeIsolated { HotkeySpike.hotKey(id: id, pressed: pressed) }
    return noErr
}

/// Runs on the tap thread: one mask compare, then a hop to main.
private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        HotkeySpike.tapWasDisabled(byTimeout: type == .tapDisabledByTimeout)
    } else if !event.flags.contains(.maskCommand) {
        HotkeySpike.tapSawRelease()
    }
    return Unmanaged.passUnretained(event)
}
#endif
