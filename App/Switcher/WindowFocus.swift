import AppKit

/// Brings one window forward, by the public route: Accessibility makes it the main window of its app and
/// raises it, then the app is activated. Nothing here runs on the caller's thread: an app that does not
/// answer costs the focus queue 0.25 s per call, never the main thread.
enum WindowFocus {
    private static let queue = DispatchQueue(label: "com.math2it.cmdtab.focus", qos: .userInitiated)
    private static let timeout: Float = 0.25

    /// Returns at once. The `focus` interval runs from this request to the last focus call's return.
    static func focus(windowID: CGWindowID, pid: pid_t) {
        let interval = Perf.begin("focus")
        queue.async {
            raise(windowID: windowID, pid: pid)
            // Also when the window was not raised (no answer, no Accessibility): its app still comes forward.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
            Perf.end(interval)
        }
    }

    /// On the focus queue: the elements are created and used here only.
    private static func raise(windowID: CGWindowID, pid: pid_t) {
        dispatchPrecondition(condition: .onQueue(queue))
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            // The timeout of the app element does not carry over to its window elements.
            AXUIElementSetMessagingTimeout(window, timeout)
            var id = CGWindowID(0)
            guard _AXUIElementGetWindow(window, &id) == .success, id == windowID else { continue }
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }
}
