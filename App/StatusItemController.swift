import AppKit

/// CmdTab's menu bar item: the template SF Symbol `macwindow.on.rectangle` and a menu (Settings…, Check for
/// Updates…, Quit CmdTab). Created when the status item should show; `remove()` takes it out of the menu bar.
@MainActor
final class StatusItemController: NSObject, NSMenuItemValidation {
    private let updater: Updater
    private let showSettings: () -> Void
    private let statusItem: NSStatusItem

    init(updater: Updater, showSettings: @escaping () -> Void) {
        self.updater = updater
        self.showSettings = showSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "CmdTab")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
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

    /// Runs each time the menu opens. "Check for Updates…" is disabled while the updater is off.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates) ? updater.canCheckForUpdates : true
    }

    @objc private func openSettings() { showSettings() }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}
