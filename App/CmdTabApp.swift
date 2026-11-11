// The app entry: an AppKit delegate that owns the switcher, the Settings window, its menu and the shared state.
import AppKit
import SwiftUI

/// AppKit entry point: no SwiftUI `App`, so SwiftUI is only loaded inside the Settings window.
@main
@MainActor
enum CmdTabApp {
    // NSApplication.delegate is weak; keep the delegate alive for the app lifetime.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

/// Lives for the app lifetime. No window at launch: the app stays in the background (LSUIElement), with a menu bar
/// item, a Dock icon or neither (`IconVisibility`), and a Dock icon while Settings is open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let switcher = SwitcherController()
    /// The selected section; kept across window closes, so a menu can open a section before the window exists.
    private let navigation = Navigation()
    /// Sparkle; stays off until `SUPublicEDKey` is set.
    private var updater: Updater?
    /// Created at launch; reading them never prompts.
    private var accessibility: AccessibilityPermission?
    private var screenRecording: ScreenRecordingPermission?

    /// Created on the first `showSettings` and kept: closing only orders it out.
    private var window: NSWindow?
    /// Exists only while the menu bar item shows.
    private var statusItem: StatusItemController?

    /// The settings applied last, so the defaults observer acts only on a real change.
    private var appliedIconVisibility = Preferences.iconVisibility
    private var appliedHotkeyModifier = Preferences.hotkeyModifier
    private var appliedThumbnailSize = Preferences.thumbnailSize
    private var appliedEnabled = Preferences.isEnabled
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First: a run that was killed left the Dock's switcher off.
        SymbolicHotkeys.installRestoreHandlers()
        // Before any window.
        AppearanceMode.current.apply()
        NSApp.mainMenu = makeMainMenu()
        let updater = Updater()
        self.updater = updater
        updater.start()
        let accessibility = AccessibilityPermission()
        self.accessibility = accessibility
        screenRecording = ScreenRecordingPermission()
        observeDefaults()
        applyIconVisibility()
        if Preferences.isEnabled { switcher.start() }
        // Without Accessibility the switcher cannot run: show why and how to grant it.
        if !accessibility.isTrusted { showSettings(section: .permissions) }
        // `start` does nothing more when the switcher is already armed.
        accessibility.onTrusted = { [weak self] in
            if Preferences.isEnabled { self?.switcher.start() }
        }
    }

    /// Disarms the switcher, which gives Cmd+Tab back to the Dock.
    func applicationWillTerminate(_ notification: Notification) {
        switcher.stop()
    }

    /// Opening the app again (Finder, `open`, Spotlight) opens Settings: the only way in when the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: Settings window

    /// Opens Settings on `section`.
    func showSettings(section: SettingsSection) {
        // First, so the window shows the section from its first frame.
        navigation.section = section
        showSettings()
    }

    /// Opens Settings on the last section shown.
    @objc func showSettings() {
        if window == nil, let updater, let accessibility, let screenRecording {
            let hosting = NSHostingController(rootView: MainView(updater: updater).environment(navigation)
                .environment(accessibility).environment(screenRecording))
            // The window owns its size, not the SwiftUI content.
            hosting.sizingOptions = []
            // The SwiftUI toolbar (the logo) becomes the window's toolbar, in the traffic-light row.
            hosting.sceneBridgingOptions = [.toolbars]
            let window = NSWindow(contentViewController: hosting)
            window.title = "CmdTab"
            window.titleVisibility = .hidden
            // Compact: a shorter traffic-light row, so the Settings body starts close under it.
            window.toolbarStyle = .unifiedCompact
            // One background for the toolbar and the content, without a line between them.
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            // Full size content: the background runs under the toolbar too.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 420)
            window.setContentSize(NSSize(width: 860, height: 560))
            if !window.setFrameUsingName("MainWindow") { window.center() }
            window.setFrameAutosaveName("MainWindow")
            window.delegate = self
            self.window = window
        }
        bringToFront(window)
    }

    /// Opens Settings on the About section.
    @objc func showAbout() {
        showSettings(section: .about)
    }

    /// Shows the Dock icon and activates the app on the next turn (the `.regular` switch from LSUIElement is
    /// not effective before), then fronts `window`. On macOS 14+ a plain `activate()` is denied on a fresh launch
    /// from LSUIElement; the `ignoringOtherApps:` form is still honored.
    private func bringToFront(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }

    /// Drops the Dock icon once Settings is closed, unless the icon belongs in the Dock or another titled window
    /// (Sparkle's) is still open.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // On the next turn, once the window is off screen.
        Task { @MainActor in
            let otherWindowOpen = NSApp.windows.contains {
                $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled)
            }
            if !otherWindowOpen, Preferences.iconVisibility != .dock { NSApp.setActivationPolicy(.accessory) }
        }
    }

    // MARK: Icon and live preferences

    /// Dock: a Dock icon, no menu bar item. Menu bar: a menu bar item, no Dock icon. Hidden: neither. While Settings
    /// shows, the Dock icon stays (`windowWillClose` drops it): only the menu bar item changes then.
    private func applyIconVisibility() {
        let mode = Preferences.iconVisibility
        if mode == .menuBar {
            if statusItem == nil, let updater {
                statusItem = StatusItemController(updater: updater, showSettings: { [weak self] in self?.showSettings() },
                                                  showAbout: { [weak self] in self?.showAbout() })
            }
        } else {
            statusItem?.remove()
            statusItem = nil
        }
        if mode == .dock {
            NSApp.setActivationPolicy(.regular)
        } else if window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// One observer for every defaults write (`@AppStorage`, the window frame, Sparkle's keys): it acts only when a
    /// setting the delegate or the switcher applies really changed.
    private func observeDefaults() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
    }

    private func defaultsChanged() {
        let iconVisibility = Preferences.iconVisibility
        let hotkeyModifier = Preferences.hotkeyModifier
        let thumbnailSize = Preferences.thumbnailSize
        let enabled = Preferences.isEnabled
        let iconChanged = iconVisibility != appliedIconVisibility
        let switcherChanged = hotkeyModifier != appliedHotkeyModifier || thumbnailSize != appliedThumbnailSize
        let enabledChanged = enabled != appliedEnabled
        // Stored first: applying can write defaults (the status item's position), which posts again at once.
        appliedIconVisibility = iconVisibility
        appliedHotkeyModifier = hotkeyModifier
        appliedThumbnailSize = thumbnailSize
        appliedEnabled = enabled
        if iconChanged { applyIconVisibility() }
        // Off: `stop` disarms, which gives Cmd+Tab back to the Dock.
        if enabledChanged { enabled ? switcher.start() : switcher.stop() }
        if switcherChanged { switcher.applyPreferences() }
    }

    // MARK: Main menu

    @objc private func checkForUpdates() { updater?.checkForUpdates() }

    /// Disabled while the updater is off (no `SUPublicEDKey` yet).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkForUpdates) ? updater?.canCheckForUpdates == true : true
    }

    /// App menu (About, Check for Updates, Settings, Hide, Quit), Edit and Window menus: without them Settings loses
    /// ⌘W, ⌘, and copy and paste.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About CmdTab", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings as () -> Void),
                        keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide CmdTab", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit CmdTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = NSMenu(title: "Edit")
        // No typed selectors for these: the responder chain (text views, the window's undo manager) answers them.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}
