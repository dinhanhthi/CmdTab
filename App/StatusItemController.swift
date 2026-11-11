import AppKit

/// CmdTab's menu bar item: the app's logo (dimmed while the switcher is off) and a menu (Enable CmdTab, Settings…,
/// About CmdTab, Check for Updates…, Quit CmdTab). Created when the status item should show; `remove()` takes it out
/// of the menu bar.
@MainActor
final class StatusItemController: NSObject, NSMenuItemValidation {
    private let updater: Updater
    private let showSettings: () -> Void
    private let showAbout: () -> Void
    private let statusItem: NSStatusItem

    init(updater: Updater, showSettings: @escaping () -> Void, showAbout: @escaping () -> Void) {
        self.updater = updater
        self.showSettings = showSettings
        self.showAbout = showAbout
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        // A copy: resizing the named image would resize it in About too.
        let image = NSImage(named: "logo")?.copy() as? NSImage
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = "CmdTab"
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !Preferences.isEnabled
        let menu = NSMenu()
        menu.addItem(item("Enable CmdTab", #selector(toggleEnabled)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("About CmdTab", #selector(openAbout)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Quit CmdTab", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    /// Takes the item out of the menu bar; the controller is done after this.
    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Runs each time the menu opens. "Enable CmdTab" shows a check while on; "Check for Updates…" is disabled while
    /// the updater is off.
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
