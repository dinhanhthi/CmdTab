/// One switching session, from the hotkey press to the commit or the cancel. Pure: no clock and no side
/// effects. The controller owns the 100 ms hold timer and performs the returned effects.
///
/// Whatever makes no sense in the current phase returns `[]` and changes nothing: any event while `idle`
/// (a late `holdElapsed` or release after the commit), `holdElapsed` while already `visible`, `hover` and
/// `click` while no panel is showing or with an index outside the list, and `begin` during a session.
/// A `step` while `pending` moves the selection but returns `[]`: nothing is on screen yet, and
/// `showPanel(selected:)` carries the index.
struct SwitcherSession {
    enum Phase {
        /// No session.
        case idle
        /// The modifier is down and the hold timer has not fired: no panel.
        case pending
        /// The panel is showing.
        case visible
    }

    enum Event {
        case step(Int)
        case holdElapsed
        case modifierReleased
        case cancel
        case hover(Int)
        case click(Int)
    }

    enum Effect: Equatable {
        case showPanel(selected: Int)
        case select(Int)
        case commit(Int)
        case cancel
    }

    private(set) var phase = Phase.idle
    private var count = 0
    private var selected = 0

    /// Starts a session over `count` windows. The first selection is `startIndex`, or the last window when
    /// `reverse`. A modifier that is already up commits at once (the quick tap); an empty list starts nothing.
    mutating func begin(count: Int, startIndex: Int, reverse: Bool, modifierDown: Bool) -> [Effect] {
        guard phase == .idle, count > 0 else { return [] }
        let first = reverse ? count - 1 : startIndex
        guard modifierDown else { return [.commit(first)] }
        self.count = count
        selected = first
        phase = .pending
        return []
    }

    mutating func handle(_ event: Event) -> [Effect] {
        guard phase != .idle else { return [] }
        switch event {
        case .step(let delta):
            // Swift's % keeps the sign of the left side, hence the second pass.
            selected = ((selected + delta) % count + count) % count
            return phase == .visible ? [.select(selected)] : []
        case .holdElapsed:
            guard phase == .pending else { return [] }
            phase = .visible
            return [.showPanel(selected: selected)]
        case .modifierReleased:
            phase = .idle
            return [.commit(selected)]
        case .cancel:
            phase = .idle
            return [.cancel]
        case .hover(let index):
            guard phase == .visible, (0..<count).contains(index) else { return [] }
            selected = index
            return [.select(index)]
        case .click(let index):
            guard phase == .visible, (0..<count).contains(index) else { return [] }
            phase = .idle
            return [.commit(index)]
        }
    }
}
