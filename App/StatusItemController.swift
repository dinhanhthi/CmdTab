import AppKit

/// CmdTab's menu bar item: the app's logo (dimmed while the switcher is off) and a menu (Enable CmdTab, Settings…,
/// About CmdTab, Check for Updates…, Quit CmdTab). While Sparkle holds an update found by a scheduled check, the logo
/// has a download badge and "Check for Updates…" reads "Update to CmdTab <version>…". Created when the status item
/// should show; `remove()` takes it out of the menu bar.
@MainActor
final class StatusItemController: NSObject, NSMenuItemValidation {
    private let updater: Updater
    private let showSettings: () -> Void
    private let showAbout: () -> Void
    private let statusItem: NSStatusItem
    private let logo: NSImage?
    private lazy var updatesItem = item("Check for Updates…", #selector(checkForUpdates))

    init(updater: Updater, showSettings: @escaping () -> Void, showAbout: @escaping () -> Void) {
        self.updater = updater
        self.showSettings = showSettings
        self.showAbout = showAbout
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // A copy: resizing the named image would resize it in About too.
        let image = NSImage(named: "logo")?.copy() as? NSImage
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = "CmdTab"
        logo = image
        super.init()
        statusItem.button?.appearsDisabled = !Preferences.isEnabled
        let menu = NSMenu()
        menu.addItem(item("Enable CmdTab", #selector(toggleEnabled)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("About CmdTab", #selector(openAbout)))
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit CmdTab", #selector(quit), key: "q"))
        statusItem.menu = menu
        updater.onAvailableUpdateChange = { [weak self] in self?.refreshUpdateState() }
        // An update may already be known: the item is recreated when its visibility setting changes.
        refreshUpdateState()
    }

    /// Takes the item out of the menu bar; the controller is done after this.
    func remove() {
        updater.onAvailableUpdateChange = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// The plain logo and "Check for Updates…", or, while an update waits, the logo with a download badge at its
    /// bottom-right corner and "Update to CmdTab <version>…".
    private func refreshUpdateState() {
        guard let version = updater.availableUpdateVersion else {
            statusItem.button?.image = logo
            updatesItem.title = "Check for Updates…"
            return
        }
        let logo = logo
        let badged = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            logo?.draw(in: rect)
            let badge = NSRect(x: rect.maxX - 11, y: rect.minY, width: 11, height: 11)
            // A white disc, then a bold arrow in a deep green (the system green, 45 % of the way to black).
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let green = NSColor.systemGreen.blended(withFraction: 0.45, of: .black) ?? .systemGreen
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .black)
                .applying(NSImage.SymbolConfiguration(paletteColors: [green]))
            if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                // Aspect-fit in the disc's inner square, centred.
                let inner = badge.insetBy(dx: 1, dy: 1)
                let size = arrow.size
                let scale = min(inner.width / size.width, inner.height / size.height)
                let fitted = NSSize(width: size.width * scale, height: size.height * scale)
                arrow.draw(in: NSRect(x: badge.midX - fitted.width / 2, y: badge.midY - fitted.height / 2,
                                      width: fitted.width, height: fitted.height))
            }
            return true
        }
        badged.accessibilityDescription = "CmdTab, update available"
        statusItem.button?.image = badged
        updatesItem.title = "Update to CmdTab \(version)…"
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Runs each time the menu opens. "Enable CmdTab" shows a check while on; the updates item is disabled while the
    /// updater is off.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleEnabled) { menuItem.state = Preferences.isEnabled ? .on : .off }
        return menuItem.action == #selector(checkForUpdates) ? updater.canCheckForUpdates : true
    }

    /// The delegate's defaults observer starts or stops the switcher.
    @objc private func toggleEnabled() {
        Preferences.isEnabled.toggle()
        statusItem.button?.appearsDisabled = !Preferences.isEnabled
    }

    @objc private func openSettings() { showSettings() }
    @objc private func openAbout() { showAbout() }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}
