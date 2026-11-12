import AppKit

/// Brings one window forward. `NSRunningApplication.activate()` is not enough: macOS ignores an activation asked
/// by an app that is not active (CmdTab never is, unless its Settings window is in front), so the target app
/// stayed behind or only its window was raised. The WindowServer is asked instead (SkyLight, as yabai does): the
/// app comes forward with that window, the window is made key, then Accessibility raises it above the app's other
/// windows. When asked to restore, a hidden app is unhidden and a minimized window restored first. Nothing here
/// runs on the caller's thread: an app that does not answer costs the focus queue 0.25 s per Accessibility call,
/// never the main thread.
enum WindowFocus {
    private static let queue = DispatchQueue(label: "com.math2it.cmdtab.focus", qos: .userInitiated)
    private static let timeout: Float = 0.25
    /// `kCPSUserGenerated`: the switch is the user's own, as a click on the window would be.
    private static let userGenerated: UInt32 = 0x200

    /// Returns at once. With `restore` (a minimized window or one of a hidden app), the focus queue first unhides
    /// the app when it is hidden and restores the window when it is minimized. The `focus` interval runs from this
    /// request to the last focus call's return.
    static func focus(windowID: CGWindowID, pid: pid_t, restore: Bool = false) {
        let interval = Perf.begin("focus")
        // CmdTab's own window (Settings): AppKit would answer the Accessibility calls on the focus queue and order
        // the window off the main thread, which macOS stops the app for. AppKit on the main thread instead.
        if pid == getpid() {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.windowNumber == Int(windowID) }?.makeKeyAndOrderFront(nil)
                }
                Perf.end(interval)
            }
            return
        }
        queue.async {
            // A window to restore is looked up first: it leaves the Dock before it comes forward. Otherwise the
            // lookup comes after, so a window it cannot find still comes forward at once.
            let restored = restore ? restoredWindow(windowID: windowID, pid: pid) : nil
            if !bringForward(windowID: windowID, pid: pid) {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
            if let window = restore ? restored : axWindow(windowID: windowID, pid: pid) { raise(window) }
            Perf.end(interval)
        }
    }

    /// The app of `pid` becomes the front process with `windowID` as its key window. False when the process or
    /// the WindowServer refused.
    private static func bringForward(windowID: CGWindowID, pid: pid_t) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        var psn = ProcessSerialNumber()
        guard CmdTabGetProcessForPID(pid, &psn) == noErr,
              _SLPSSetFrontProcessWithOptions(&psn, windowID, userGenerated) == .success else { return false }
        makeKey(windowID: windowID, psn: &psn)
        return true
    }

    /// Two synthesized event records that make `windowID` the key window of its process. The layout (0xf8 bytes:
    /// the length at 0x04, the kind 1 then 2 at 0x08, 0xff over 0x20..<0x30, 0x10 at 0x3a, the window id at
    /// 0x3c) is read from yabai (MIT, github.com/koekeishiya/yabai, `window_manager_make_key_window`).
    private static func makeKey(windowID: CGWindowID, psn: inout ProcessSerialNumber) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        bytes.replaceSubrange(0x20..<0x30, with: repeatElement(0xff, count: 0x10))
        for kind: UInt8 in [0x01, 0x02] {
            bytes[0x08] = kind
            _ = SLPSPostEventRecordTo(&psn, &bytes)
        }
    }

    /// The Accessibility element of `windowID`, nil when the app does not list it. On the focus queue: the
    /// elements are created and used there only.
    private static func axWindow(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        dispatchPrecondition(condition: .onQueue(queue))
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            // The timeout of the app element does not carry over to its window elements.
            AXUIElementSetMessagingTimeout(window, timeout)
            var id = CGWindowID(0)
            if _AXUIElementGetWindow(window, &id) == .success, id == windowID { return window }
        }
        return nil
    }

    /// Unhides the app of `pid` when it is hidden, then returns the element of `windowID`, restored from the Dock
    /// when it was minimized. Nil when the app does not list the window.
    private static func restoredWindow(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        dispatchPrecondition(condition: .onQueue(queue))
        if let app = NSRunningApplication(processIdentifier: pid), app.isHidden { app.unhide() }
        guard let window = axWindow(windowID: windowID, pid: pid) else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
           (value as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        return window
    }

    /// Makes `window` the main window of its app and raises it above the app's other windows.
    private static func raise(_ window: AXUIElement) {
        dispatchPrecondition(condition: .onQueue(queue))
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}
