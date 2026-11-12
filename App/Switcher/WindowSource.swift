import AppKit

/// Reads what a switching session starts from: the windows (on-screen only, or also off-screen), the regular
/// and hidden apps, the displays and the mouse. It runs on the main thread at hotkey time, so it makes only these
/// WindowServer and workspace reads: no Accessibility call, and no filtering (that is `WindowFilter`).
enum WindowSource {
    /// `all` is front to back; with `includeOffScreen` it also holds the off-screen windows (minimized, of hidden
    /// apps, on other Spaces), each with `isOnScreen` false. `hiddenPIDs` are the regular apps that are hidden.
    /// `displays` and `mouse` share the windows' global top-left space. `mouseDisplay` is the display under the
    /// mouse: the first one when the mouse is on none, as in `WindowFilter.list`.
    @MainActor
    static func snapshot(includeOffScreen: Bool = false) -> (
        all: [WindowSnapshot], regularPIDs: Set<pid_t>, hiddenPIDs: Set<pid_t>, frontmostPID: pid_t?,
        displays: [CGRect], mouse: CGPoint, mouseDisplay: CGDirectDisplayID
    ) {
        let workspace = NSWorkspace.shared
        let regularApps = workspace.runningApplications.filter { $0.activationPolicy == .regular }
        let regularPIDs = Set(regularApps.map(\.processIdentifier))
        let hiddenPIDs = Set(regularApps.filter(\.isHidden).map(\.processIdentifier))

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        if CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount) != .success {
            displayCount = 0
        }
        displayIDs.removeLast(displayIDs.count - Int(displayCount))
        let displays = displayIDs.map { CGDisplayBounds($0) }

        let mouse = CGEvent(source: nil)?.location ?? .zero
        let mouseDisplay =
            displayIDs.isEmpty ? CGMainDisplayID() : displayIDs[displays.firstIndex { $0.contains(mouse) } ?? 0]

        return (
            windows(includeOffScreen: includeOffScreen), regularPIDs, hiddenPIDs,
            workspace.frontmostApplication?.processIdentifier, displays, mouse, mouseDisplay
        )
    }

    /// Every on-screen window, front to back, and with `includeOffScreen` the off-screen ones too. An entry without
    /// one of the keys the filter needs is skipped.
    private static func windows(includeOffScreen: Bool) -> [WindowSnapshot] {
        let options: CGWindowListOption =
            includeOffScreen ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let rect = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rect) else { return nil }
            // The title is absent without the Screen Recording permission, and empty for an untitled window.
            let title = info[kCGWindowName as String] as? String
            return WindowSnapshot(
                id: id, pid: pid, ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: title?.isEmpty == false ? title : nil, bounds: bounds, layer: layer, alpha: alpha,
                isOnScreen: !includeOffScreen || info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }
}
