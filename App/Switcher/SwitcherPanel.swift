import AppKit

/// The switcher overlay: one borderless, non-activating panel on a HUD material, holding one `SwitcherView`.
/// Created once and kept. It never becomes key: the session keys are Carbon hotkeys (spike rule (f)).
final class SwitcherPanel: NSPanel {
    let switcherView = SwitcherView(frame: .zero)

    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true

        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 16
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        switcherView.autoresizingMask = [.width, .height]
        material.addSubview(switcherView)
        contentView = material
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Sizes the panel to `size` (the `panelSize` of `SwitcherView.layout`) and centres it in `visibleFrame`.
    /// Call it before `SwitcherView.show`, which lays the tiles out in this size, at this screen's scale.
    func place(size: CGSize, centredIn visibleFrame: CGRect) {
        let origin = CGPoint(
            x: (visibleFrame.midX - size.width / 2).rounded(), y: (visibleFrame.midY - size.height / 2).rounded())
        let target = CGRect(origin: origin, size: size)
        guard target != frame else { return }
        let resized = target.size != frame.size
        setFrame(target, display: false)
        // The shadow follows the rounded material, so it is redrawn only when the size changed.
        if resized { invalidateShadow() }
    }
}
