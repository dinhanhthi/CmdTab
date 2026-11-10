import AppKit
import Carbon.HIToolbox
import os
import Synchronization

private let log = Logger(subsystem: "com.math2it.cmdtab", category: "Input")

/// "CmdT": marks the Carbon hotkeys of this app.
private let hotKeySignature: OSType = 0x436D_6454

/// The switcher's keys as Carbon hotkeys: modifier+Tab and modifier+Shift+Tab while armed,
/// modifier+Left / Right / Escape only during a session.
/// Carbon reports one press and one release per hold, so a held key repeats from a timer
/// that exists only between the two.
@MainActor
final class HotkeyMonitor {
    /// The raw value is the Carbon hotkey id.
    enum Key: UInt32 {
        case trigger = 1, reverse, left, right, escape
    }

    /// Called for every press, and for every repeat of a held key.
    var onPress: ((Key) -> Void)?

    /// The monitor the Carbon handler reports to: the one armed last.
    fileprivate static weak var armed: HotkeyMonitor?
    private static var handlerInstalled = false

    private var modifier: HotkeyModifier?  // nil = not armed
    private var refs: [Key: EventHotKeyRef] = [:]
    private var heldKey: Key?
    private var repeatTimer: DispatchSourceTimer?

    /// Takes modifier+Tab and modifier+Shift+Tab. False, with nothing registered, when either is refused.
    /// The Dock loses its switcher only when both are registered and the modifier is Command.
    func arm(modifier: HotkeyModifier) -> Bool {
        if self.modifier != modifier {
            disarm()
            let flags = modifier.carbonFlags
            guard Self.installHandler(),
                  register(.trigger, keyCode: kVK_Tab, flags: flags),
                  register(.reverse, keyCode: kVK_Tab, flags: flags | UInt32(shiftKey)) else {
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
            for key in [Key.left, .right, .escape] {
                if let ref = refs.removeValue(forKey: key) { UnregisterEventHotKey(ref) }
            }
            return
        }
        let flags = modifier.carbonFlags
        _ = register(.escape, keyCode: kVK_Escape, flags: flags)
        // Control+Left and Control+Right belong to Mission Control.
        guard modifier != .control else { return }
        _ = register(.left, keyCode: kVK_LeftArrow, flags: flags)
        _ = register(.right, keyCode: kVK_RightArrow, flags: flags)
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

    private func register(_ key: Key, keyCode: Int, flags: UInt32) -> Bool {
        guard refs[key] == nil else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), flags, EventHotKeyID(signature: hotKeySignature, id: key.rawValue),
            GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("hotkey \(key.rawValue) not registered: \(status)")
            return false
        }
        refs[key] = ref
        return true
    }

    fileprivate func hotKey(id: UInt32, pressed: Bool) {
        // An event that was already queued when its key was unregistered is dropped.
        guard let key = Key(rawValue: id), refs[key] != nil else { return }
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
/// and every launch re-asserts it. Only SIGKILL leaves it off, until the next launch.
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

        for number in [SIGTERM, SIGINT, SIGHUP] {
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
        for number in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP] { sigaction(number, &action, nil) }

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
