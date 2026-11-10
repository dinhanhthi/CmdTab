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

    static var hotkeyModifier: HotkeyModifier { value(hotkeyModifierKey, default: .command) }
    static var screenScope: ScreenScope { value(screenScopeKey, default: .mouseScreen) }
    static var thumbnailSize: ThumbnailSize { value(thumbnailSizeKey, default: .medium) }
    static var appIconSize: AppIconSize { value(appIconSizeKey, default: .medium) }
    static var hideAnimation: HideAnimation { value(hideAnimationKey, default: .none) }
    static var iconVisibility: IconVisibility { value(iconVisibilityKey, default: .menuBar) }

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
