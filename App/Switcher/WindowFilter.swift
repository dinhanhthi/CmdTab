import CoreGraphics

/// One window, as read from the CG window list. Bounds are in the global top-left space.
struct WindowSnapshot: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String?
    let bounds: CGRect
    let layer: Int
    let alpha: Double
    /// False for a window that is not on screen now: minimized, of a hidden app, or on another Space.
    var isOnScreen = true
}

enum ScreenScope: String, CaseIterable, Sendable {
    case mouseScreen, allScreens
}

/// Why a listed window is (or is not) off screen: `normal` on screen, `hidden` off screen with its app hidden (a
/// minimized window of a hidden app counts as hidden), else `minimized`. The switcher draws a badge for the last two.
enum WindowState: Sendable {
    case normal, minimized, hidden
}

/// Decides which windows the switcher lists. Pure: window bounds, display bounds and the mouse location
/// share one global top-left space, so nothing is flipped here.
enum WindowFilter {
    /// On screen, layer 0, alpha > 0, at least 100 x 100 points, owned by a regular app, and switchable (not a
    /// sheet, as far as `isSwitchable` knows). The order is kept.
    static func admitted(
        _ all: [WindowSnapshot], regularPIDs: Set<pid_t>, isSwitchable: (CGWindowID) -> Bool = { _ in true }
    ) -> [WindowSnapshot] {
        all.filter {
            $0.isOnScreen && $0.layer == 0 && $0.alpha > 0 && $0.bounds.width >= 100 && $0.bounds.height >= 100
                && regularPIDs.contains($0.pid) && isSwitchable($0.id)
        }
    }

    /// The off-screen windows to list: layer 0, at least 100 x 100 points, owned by a regular app, and either a
    /// known window of a hidden app (`showHidden`) or a minimized window (`showMinimized`); a minimized window of a
    /// hidden app is listed when either toggle allows it. AX only lists the current Space's windows, so an off-screen
    /// window the classifier does not know (on another Space, or a helper window) is never listed. The order is kept.
    static func offScreen(
        _ all: [WindowSnapshot], regularPIDs: Set<pid_t>, hiddenPIDs: Set<pid_t>, showMinimized: Bool,
        showHidden: Bool, isMinimized: (CGWindowID) -> Bool, isKnownWindow: (CGWindowID) -> Bool
    ) -> [WindowSnapshot] {
        all.filter {
            !$0.isOnScreen && $0.layer == 0 && $0.bounds.width >= 100 && $0.bounds.height >= 100
                && regularPIDs.contains($0.pid)
                && ((showHidden && hiddenPIDs.contains($0.pid) && isKnownWindow($0.id))
                    || (showMinimized && isMinimized($0.id)))
        }
    }

    /// The display holding most of `bounds`; a tie goes to the lower index. `nil` when it is on no display.
    static func displayIndex(of bounds: CGRect, displays: [CGRect]) -> Int? {
        var best: Int?
        var bestArea: CGFloat = 0
        for (index, display) in displays.enumerated() {
            let overlap = bounds.intersection(display)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                best = index
                bestArea = area
            }
        }
        return best
    }

    /// The admitted windows, front to back, then the `offScreen` ones. `mouseScreen` keeps those of the display
    /// containing the mouse (display 0 when the mouse is on none).
    static func list(
        all: [WindowSnapshot], regularPIDs: Set<pid_t>, displays: [CGRect], mouse: CGPoint, scope: ScreenScope,
        isSwitchable: (CGWindowID) -> Bool = { _ in true }, hiddenPIDs: Set<pid_t> = [], showMinimized: Bool = false,
        showHidden: Bool = false, isMinimized: (CGWindowID) -> Bool = { _ in false },
        isKnownWindow: (CGWindowID) -> Bool = { _ in false }
    ) -> [WindowSnapshot] {
        let windows =
            admitted(all, regularPIDs: regularPIDs, isSwitchable: isSwitchable)
            + offScreen(
                all, regularPIDs: regularPIDs, hiddenPIDs: hiddenPIDs, showMinimized: showMinimized,
                showHidden: showHidden, isMinimized: isMinimized, isKnownWindow: isKnownWindow)
        guard scope == .mouseScreen else { return windows }
        let mouseDisplay = displays.firstIndex { $0.contains(mouse) } ?? 0
        return windows.filter { displayIndex(of: $0.bounds, displays: displays) == mouseDisplay }
    }

    /// The state of a listed `window`: on screen is `normal`; off screen, `hidden` when its pid is in `hiddenPIDs`,
    /// else `minimized` (`list` lists no other off-screen window).
    static func state(of window: WindowSnapshot, hiddenPIDs: Set<pid_t>) -> WindowState {
        if window.isOnScreen { return .normal }
        return hiddenPIDs.contains(window.pid) ? .hidden : .minimized
    }

    /// 1 when the first listed window is the focused window (the first admitted window, in global z-order,
    /// owned by the frontmost pid) and the list has more than one entry; otherwise 0.
    static func startIndex(list: [WindowSnapshot], admittedAll: [WindowSnapshot], frontmostPID: pid_t?) -> Int {
        guard list.count > 1, let frontmostPID,
              let focused = admittedAll.first(where: { $0.pid == frontmostPID }),
              list[0].id == focused.id
        else { return 0 }
        return 1
    }
}
