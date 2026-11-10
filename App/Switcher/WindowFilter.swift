import CoreGraphics

/// One on-screen window, as read from the CG window list. Bounds are in the global top-left space.
struct WindowSnapshot: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String?
    let bounds: CGRect
    let layer: Int
    let alpha: Double
}

enum ScreenScope: String, CaseIterable, Sendable {
    case mouseScreen, allScreens
}

/// Decides which windows the switcher lists. Pure: window bounds, display bounds and the mouse location
/// share one global top-left space, so nothing is flipped here.
enum WindowFilter {
    /// Layer 0, alpha > 0, at least 100 x 100 points, owned by a regular app. The order is kept.
    static func admitted(_ all: [WindowSnapshot], regularPIDs: Set<pid_t>) -> [WindowSnapshot] {
        all.filter {
            $0.layer == 0 && $0.alpha > 0 && $0.bounds.width >= 100 && $0.bounds.height >= 100
                && regularPIDs.contains($0.pid)
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

    /// The admitted windows, front to back. `mouseScreen` keeps those of the display containing the mouse
    /// (display 0 when the mouse is on none).
    static func list(
        all: [WindowSnapshot], regularPIDs: Set<pid_t>, displays: [CGRect], mouse: CGPoint, scope: ScreenScope
    ) -> [WindowSnapshot] {
        let windows = admitted(all, regularPIDs: regularPIDs)
        guard scope == .mouseScreen else { return windows }
        let mouseDisplay = displays.firstIndex { $0.contains(mouse) } ?? 0
        return windows.filter { displayIndex(of: $0.bounds, displays: displays) == mouseDisplay }
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
