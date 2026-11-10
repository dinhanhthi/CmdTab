import Testing

// SwitcherSession.swift is compiled into this hostless bundle, so its types are used directly.

/// A session whose panel is showing: 3 windows, the selection on `startIndex`.
private func visibleSession(startIndex: Int) -> SwitcherSession {
    var session = SwitcherSession()
    _ = session.begin(count: 3, startIndex: startIndex, reverse: false, modifierDown: true)
    _ = session.handle(.holdElapsed)
    return session
}

@Suite struct SwitcherSessionTests {
    @Test func stepsWrapAroundInBothDirections() {
        var forward = visibleSession(startIndex: 2)
        let pastTheEnd = forward.handle(.step(1))
        #expect(pastTheEnd == [.select(0)])

        var backward = visibleSession(startIndex: 0)
        let beforeTheStart = backward.handle(.step(-1))
        #expect(beforeTheStart == [.select(2)])
    }

    @Test func aReleaseBeforeTheHoldCommitsWithoutShowingThePanel() {
        var session = SwitcherSession()
        let begun = session.begin(count: 3, startIndex: 1, reverse: false, modifierDown: true)
        #expect(begun == [])
        #expect(session.phase == .pending)

        let released = session.handle(.modifierReleased)
        #expect(released == [.commit(1)])
        #expect(session.phase == .idle)

        // The controller's timer may still fire after the commit: it must not show the panel.
        let lateHold = session.handle(.holdElapsed)
        #expect(lateHold == [])
        #expect(session.phase == .idle)
    }

    @Test func aModifierAlreadyUpAtPressCommitsAtOnce() {
        var session = SwitcherSession()
        let begun = session.begin(count: 3, startIndex: 1, reverse: false, modifierDown: false)
        #expect(begun == [.commit(1)])
        #expect(session.phase == .idle)

        // Opened with Shift held: the first selection is the last window.
        let reversed = session.begin(count: 3, startIndex: 1, reverse: true, modifierDown: false)
        #expect(reversed == [.commit(2)])
        #expect(session.phase == .idle)
    }

    @Test func aHoldShowsThePanelThenAReleaseCommitsTheMovedSelection() {
        var session = SwitcherSession()
        _ = session.begin(count: 3, startIndex: 1, reverse: false, modifierDown: true)
        // A Tab pressed before the panel shows still moves the selection.
        _ = session.handle(.step(1))

        let shown = session.handle(.holdElapsed)
        #expect(shown == [.showPanel(selected: 2)])
        #expect(session.phase == .visible)

        let stepped = session.handle(.step(1))
        #expect(stepped == [.select(0)])

        let released = session.handle(.modifierReleased)
        #expect(released == [.commit(0)])
        #expect(session.phase == .idle)
    }

    @Test func escapeCancelsWithoutACommit() {
        var session = visibleSession(startIndex: 1)
        let cancelled = session.handle(.cancel)
        #expect(cancelled == [.cancel])
        #expect(session.phase == .idle)

        // The modifier comes up after Escape: nothing is left to commit.
        let released = session.handle(.modifierReleased)
        #expect(released == [])
    }

    @Test func anEmptyListStartsNoSession() {
        var session = SwitcherSession()
        // Modifier up and Shift held: the two paths that would commit or compute an index.
        let begun = session.begin(count: 0, startIndex: 0, reverse: true, modifierDown: false)
        #expect(begun == [])
        #expect(session.phase == .idle)
    }
}
