import CoreGraphics
import Testing

// WindowFilter.swift is compiled into this hostless bundle, so its types are used directly.

private let regular: Set<pid_t> = [10, 20]

// Two displays side by side, in the global top-left space.
private let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]

private func window(
    _ id: CGWindowID, pid: pid_t = 10, bounds: CGRect = CGRect(x: 100, y: 100, width: 400, height: 300),
    layer: Int = 0, alpha: Double = 1
) -> WindowSnapshot {
    WindowSnapshot(id: id, pid: pid, ownerName: "App", title: nil, bounds: bounds, layer: layer, alpha: alpha)
}

@Suite struct WindowFilterTests {
    @Test func listKeepsTheMouseDisplaysWindowsFrontToBack() {
        // Front to back, the two displays interleaved. Windows 9 and 2 both start on display 0 and straddle the edge;
        // only the larger part decides.
        let all = [
            window(7, bounds: CGRect(x: 1200, y: 100, width: 400, height: 300)), // display 1
            window(3, bounds: CGRect(x: 100, y: 100, width: 400, height: 300)), // display 0
            window(9, bounds: CGRect(x: 800, y: 100, width: 600, height: 300)), // 200 on display 0, 400 on display 1
            window(2, bounds: CGRect(x: 700, y: 100, width: 400, height: 300)), // 300 on display 0, 100 on display 1
            window(5, pid: 20, bounds: CGRect(x: 1500, y: 400, width: 300, height: 300)), // display 1
        ]
        func ids(mouse: CGPoint, scope: ScreenScope) -> [CGWindowID] {
            WindowFilter.list(all: all, regularPIDs: regular, displays: displays, mouse: mouse, scope: scope).map(\.id)
        }

        #expect(ids(mouse: CGPoint(x: 1500, y: 400), scope: .mouseScreen) == [7, 9, 5])
        #expect(ids(mouse: CGPoint(x: 10, y: 10), scope: .mouseScreen) == [3, 2])
        // A pointer on no display counts for display 0.
        #expect(ids(mouse: CGPoint(x: -50, y: -50), scope: .mouseScreen) == [3, 2])
        #expect(ids(mouse: CGPoint(x: 10, y: 10), scope: .allScreens) == [7, 3, 9, 2, 5])
    }

    @Test(arguments: [
        ("wrong layer", window(2, layer: 25)),
        ("zero alpha", window(2, alpha: 0)),
        ("too small", window(2, bounds: CGRect(x: 100, y: 100, width: 400, height: 99))),
        ("non-regular owner", window(2, pid: 99)),
        ("not switchable", window(4)),
    ])
    func admittedDropsAWindowThatBreaksOneRule(_ name: String, _ rejected: WindowSnapshot) {
        // The kept window sits exactly on the 100 x 100 floor. Only window 4 (a sheet, say) is not switchable.
        let kept = window(1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(
            WindowFilter.admitted([rejected, kept], regularPIDs: regular, isSwitchable: { $0 != 4 }) == [kept], "\(name)")
    }

    @Test func startIndexSkipsTheFocusedWindowOnlyWhenItIsListedFirst() {
        let focused = window(1, pid: 10)
        let sameApp = window(2, pid: 10)
        let other = window(3, pid: 20)
        let admittedAll = [focused, sameApp, other]

        #expect(WindowFilter.startIndex(list: [focused, sameApp, other], admittedAll: admittedAll, frontmostPID: 10) == 1)
        // The focused window is on another display: the list starts with another window of the frontmost app.
        #expect(WindowFilter.startIndex(list: [sameApp, other], admittedAll: admittedAll, frontmostPID: 10) == 0)
        #expect(WindowFilter.startIndex(list: [focused], admittedAll: [focused], frontmostPID: 10) == 0)
        // A sheet of the frontmost app, listed first, is not switchable: the selection starts after the focused
        // window, not on it.
        let all = [window(4, pid: 10), focused, sameApp, other]
        let switchable: (CGWindowID) -> Bool = { $0 != 4 }
        let list = WindowFilter.list(
            all: all, regularPIDs: regular, displays: displays, mouse: .zero, scope: .allScreens,
            isSwitchable: switchable)
        let admitted = WindowFilter.admitted(all, regularPIDs: regular, isSwitchable: switchable)
        #expect(list[WindowFilter.startIndex(list: list, admittedAll: admitted, frontmostPID: 10)] == sameApp)
    }
}
