import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The app's settings: UserDefaults keys and typed reads. Each value is stored as the enum's raw value
/// (= its case name); a missing or unknown value reads as the default. Settings binds `@AppStorage` to these keys.
enum Preferences {
    static let hotkeyModifierKey = "HotkeyModifier"
    static let screenScopeKey = "ScreenScope"
    static let thumbnailSizeKey = "ThumbnailSize"
    static let appIconSizeKey = "AppIconSize"
    static let hideAnimationKey = "HideAnimation"
    static let iconVisibilityKey = "IconVisibility"
    static let enabledKey = "Enabled"
    static let shrinkToFitKey = "ShrinkToFit"
    static let showMinimizedKey = "ShowMinimized"
    static let showHiddenAppsKey = "ShowHiddenApps"

    static var hotkeyModifier: HotkeyModifier { value(hotkeyModifierKey, default: .command) }
    static var screenScope: ScreenScope { value(screenScopeKey, default: .mouseScreen) }
    static var thumbnailSize: ThumbnailSize { value(thumbnailSizeKey, default: .medium) }
    static var appIconSize: AppIconSize { value(appIconSizeKey, default: .medium) }
    static var hideAnimation: HideAnimation { value(hideAnimationKey, default: .none) }
    static var iconVisibility: IconVisibility { value(iconVisibilityKey, default: .menuBar) }
    /// Off: the switcher is disarmed and the system Cmd+Tab works. On by default.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    /// On: the previews shrink when not all windows fit. On by default.
    static var shrinkToFit: Bool { UserDefaults.standard.object(forKey: shrinkToFitKey) as? Bool ?? true }
    /// On: the switcher also lists minimized windows. Off by default.
    static var showMinimized: Bool { UserDefaults.standard.object(forKey: showMinimizedKey) as? Bool ?? false }
    /// On: the switcher also lists the windows of hidden apps. Off by default.
    static var showHiddenApps: Bool { UserDefaults.standard.object(forKey: showHiddenAppsKey) as? Bool ?? false }

    private static func value<Value: RawRepresentable>(_ key: String, default: Value) -> Value
    where Value.RawValue == String {
        UserDefaults.standard.string(forKey: key).flatMap(Value.init(rawValue:)) ?? `default`
    }
}

/// The modifier held with Tab.
enum HotkeyModifier: String, CaseIterable, Identifiable {
    case command, option, control

    var id: Self { self }

    var title: String {
        switch self {
        case .command: "⌘ Tab"
        case .option: "⌥ Tab"
        case .control: "⌃ Tab"
        }
    }

    /// The Carbon modifier mask, as `RegisterEventHotKey` takes it.
    var carbonFlags: UInt32 {
        switch self {
        case .command: UInt32(cmdKey)
        case .option: UInt32(optionKey)
        case .control: UInt32(controlKey)
        }
    }

    var cgFlag: CGEventFlags {
        switch self {
        case .command: .maskCommand
        case .option: .maskAlternate
        case .control: .maskControl
        }
    }
}

enum ThumbnailSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: Self { self }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The box a thumbnail fits in, in points.
    var box: CGSize {
        switch self {
        case .small: CGSize(width: 160, height: 100)
        case .medium: CGSize(width: 240, height: 150)
        case .large: CGSize(width: 320, height: 200)
        }
    }
}

enum AppIconSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: Self { self }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The side of the app icon, in points.
    var side: CGFloat {
        switch self {
        case .small: 24
        case .medium: 32
        case .large: 48
        }
    }
}

enum HideAnimation: String, CaseIterable, Identifiable {
    case none, fade

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .fade: "Fade out"
        }
    }
}

enum IconVisibility: String, CaseIterable, Identifiable {
    case dock, menuBar, hidden

    var id: Self { self }

    var title: String {
        switch self {
        case .dock: "Dock"
        case .menuBar: "Menu bar"
        case .hidden: "Hidden"
        }
    }
}

extension ScreenScope: Identifiable {
    var id: Self { self }

    var title: String {
        switch self {
        case .mouseScreen: "Mouse screen"
        case .allScreens: "All screens"
        }
    }
}
