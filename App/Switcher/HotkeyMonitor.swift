import AppKit
import Carbon.HIToolbox
import os
import Synchronization

private let log = Logger(subsystem: "com.math2it.cmdtab", category: "Input")

/// "CmdT": marks the Carbon hotkeys of this app.
private let hotKeySignature: OSType = 0x436D_6454

/// The switcher's keys as Carbon hotkeys: modifier+Tab and modifier+Shift+Tab while armed,
/// modifier+Left / Right / Escape and their modifier+Shift variants only during a session.
/// Carbon reports one press and one release per hold, so a held key repeats from a timer
/// that exists only between the two.
@MainActor
final class HotkeyMonitor {
    enum Key {
        case trigger, reverse, left, right, escape
    }

    /// The key of each Carbon hotkey id: 1 and 2 while armed, 3 to 8 during a session. Carbon matches modifiers
    /// exactly and Shift can still be down from modifier+Shift+Tab, so each session key also has a modifier+Shift
    /// variant (its id + 3) that reports the same `Key`.
    private static func key(id: UInt32) -> Key? {
        switch id {
        case 1: .trigger
        case 2: .reverse
        case 3, 6: .left
        case 4, 7: .right
        case 5, 8: .escape
        default: nil
        }
    }

    /// The session hotkeys: Carbon id, key code, with Shift.
    private static let sessionKeys: [(id: UInt32, keyCode: Int, shift: Bool)] = [
        (5, kVK_Escape, false), (8, kVK_Escape, true),
        (3, kVK_LeftArrow, false), (6, kVK_LeftArrow, true),
        (4, kVK_RightArrow, false), (7, kVK_RightArrow, true),
    ]

    /// Called for every press, and for every repeat of a held key.
    var onPress: ((Key) -> Void)?

    /// The monitor the Carbon handler reports to: the one armed last.
    fileprivate static weak var armed: HotkeyMonitor?
    private static var handlerInstalled = false

    private var modifier: HotkeyModifier?  // nil = not armed
    private var refs: [UInt32: EventHotKeyRef] = [:]  // by Carbon id
    private var heldKey: Key?
    private var repeatTimer: DispatchSourceTimer?

    /// Takes modifier+Tab and modifier+Shift+Tab. False, with nothing registered, when either is refused.
    /// The Dock loses its switcher only when both are registered and the modifier is Command.
    func arm(modifier: HotkeyModifier) -> Bool {
        if self.modifier != modifier {
            disarm()
            let flags = modifier.carbonFlags
            guard Self.installHandler(),
                  register(id: 1, keyCode: kVK_Tab, flags: flags),
                  register(id: 2, keyCode: kVK_Tab, flags: flags | UInt32(shiftKey)) else {
                disarm()
                return false
            }
            self.modifier = modifier
            Self.armed = self
        }
        SymbolicHotkeys.setDockSwitcher(enabled: modifier != .command)
        return true
    }

    /// Gives every key back, and Cmd+Tab back to the Dock.
    func disarm() {
        stopRepeat()
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        modifier = nil
        SymbolicHotkeys.setDockSwitcher(enabled: true)
    }

    /// The keys that exist only while a session runs.
    func setSessionKeys(_ on: Bool) {
        guard let modifier else { return }
        guard on else {
            stopRepeat()
            for entry in Self.sessionKeys {
                if let ref = refs.removeValue(forKey: entry.id) { UnregisterEventHotKey(ref) }
            }
            return
        }
        let flags = modifier.carbonFlags
        for entry in Self.sessionKeys {
            // Control+Left and Control+Right (with or without Shift) belong to Mission Control.
            if modifier == .control, entry.keyCode != kVK_Escape { continue }
            _ = register(id: entry.id, keyCode: entry.keyCode, flags: entry.shift ? flags | UInt32(shiftKey) : flags)
        }
    }

    // MARK: Carbon

    private static func installHandler() -> Bool {
        guard !handlerInstalled else { return true }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetEventDispatcherTarget(), hotKeyHandler, types.count, &types, nil, nil)
        if status != noErr { log.error("Carbon hotkey handler not installed: \(status)") }
        handlerInstalled = status == noErr
        return handlerInstalled
    }

    private func register(id: UInt32, keyCode: Int, flags: UInt32) -> Bool {
        guard refs[id] == nil else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), flags, EventHotKeyID(signature: hotKeySignature, id: id), GetEventDispatcherTarget(), 0,
            &ref)
        guard status == noErr, let ref else {
            log.error("hotkey \(id) not registered: \(status)")
            return false
        }
        refs[id] = ref
        return true
    }

    fileprivate func hotKey(id: UInt32, pressed: Bool) {
        // An event that was already queued when its key was unregistered is dropped.
        guard refs[id] != nil, let key = Self.key(id: id) else { return }
        if pressed {
            // The timer starts before `onPress`: a press that ends the session cancels it.
            stopRepeat()
            if key != .escape { startRepeat(key) }
            onPress?(key)
        } else if key == heldKey {
            stopRepeat()
        }
    }

    // MARK: Key repeat

    private func startRepeat(_ key: Key) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // The floor keeps a zero interval from spinning the main thread.
        timer.schedule(
            deadline: .now() + NSEvent.keyRepeatDelay, repeating: max(NSEvent.keyRepeatInterval, 0.01))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.repeatPress(key) }
        }
        timer.resume()
        heldKey = key
        repeatTimer = timer
    }

    private func repeatPress(_ key: Key) {
        // Carbon may not report the release of a key whose modifier went up first.
        guard let modifier, CGEventSource.flagsState(.combinedSessionState).contains(modifier.cgFlag) else {
            return stopRepeat()
        }
        onPress?(key)
    }

    private func stopRepeat() {
        repeatTimer?.cancel()
        repeatTimer = nil
        heldKey = nil
    }
}

/// Runs on the main thread, from the Carbon event dispatcher.
private let hotKeyHandler: EventHandlerUPP = { _, event, _ in
    var hotKey = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    guard status == noErr, hotKey.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let id = hotKey.id
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    MainActor.assumeIsolated { HotkeyMonitor.armed?.hotKey(id: id, pressed: pressed) }
    return noErr
}

/// The Dock's own switcher: symbolic hotkeys 1 (Cmd+Tab) and 2 (Cmd+Shift+Tab) in the WindowServer.
/// The setting outlives the process that changed it, so every exit this process can see restores it,
/// and every launch re-asserts it. It stays off, until the next launch, after SIGKILL, a stack overflow
/// (the crash handler has no stack left to run on) and the signals not handled here (for example SIGPIPE,
/// SIGUSR1, SIGUSR2).
enum SymbolicHotkeys {
    /// True while CmdTab has the Dock's switcher off. Read from signal handlers.
    private static let disabled = Atomic<Bool>(false)
    @MainActor private static var signalSources: [DispatchSourceSignal] = []

    static func setDockSwitcher(enabled: Bool) {
        // Set before the switcher goes off and cleared after it is back: a crash in between still restores it.
        if !enabled { disabled.store(true, ordering: .sequentiallyConsistent) }
        let first = CGSSetSymbolicHotKeyEnabled(1, enabled)
        let second = CGSSetSymbolicHotKeyEnabled(2, enabled)
        if enabled { disabled.store(false, ordering: .sequentiallyConsistent) }
        if first != .success || second != .success {
            log.error("Dock switcher enabled=\(enabled) failed: \(first.rawValue) \(second.rawValue)")
        }
    }

    /// Call once at launch, before anything arms.
    @MainActor
    static func installRestoreHandlers() {
        // A run that was killed left the switcher off. This also creates `disabled` before any handler can read it.
        setDockSwitcher(enabled: true)

        for number in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            // The default action would kill the process before the source fires.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                setDockSwitcher(enabled: true)
                signal(number, SIG_DFL)
                raise(number)
            }
            source.resume()
            signalSources.append(source)
        }

        // SA_RESETHAND: the handler runs once. SIGILL and SIGTRAP are exempt from it, so the handler
        // also resets the action itself.
        var action = sigaction(
            __sigaction_u: __sigaction_u(__sa_handler: crashHandler), sa_mask: 0, sa_flags: SA_RESETHAND)
        for number in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGSYS] { sigaction(number, &action, nil) }

        // The runtime aborts after this handler returns; the switcher is back by then.
        NSSetUncaughtExceptionHandler { _ in SymbolicHotkeys.restoreIfDisabled() }
    }

    /// Best effort: a WindowServer call is not async-signal-safe (it can block if the signal interrupted
    /// another one). So only the bare calls: no allocation, no lock, no logging.
    /// The signal then gets its default action back and is raised again: it kills the process,
    /// so the crash report is still written.
    private static let crashHandler: @convention(c) (Int32) -> Void = { number in
        SymbolicHotkeys.restoreIfDisabled()
        signal(number, SIG_DFL)
        raise(number)
    }

    private static func restoreIfDisabled() {
        guard disabled.exchange(false, ordering: .sequentiallyConsistent) else { return }
        _ = CGSSetSymbolicHotKeyEnabled(1, true)
        _ = CGSSetSymbolicHotKeyEnabled(2, true)
    }
}
