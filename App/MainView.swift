// The Settings window: the logo in the toolbar, the Settings sections under it, over the window glass.
import AppKit
import SwiftUI

/// The selected Settings section, owned by the AppDelegate so its menus can open a section before the window exists.
@Observable
@MainActor
final class Navigation {
    var section: SettingsSection = .general
}

struct MainView: View {
    /// Not observable: passed down to the About section.
    let updater: Updater

    var body: some View {
        // The scaffold keeps one settings layout; both define `SettingsRoot`.
        SettingsRoot(updater: updater)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(glass.ignoresSafeArea())
            // A band behind the transparent title bar, so scrolled content never shows through it; the same glass as
            // the window, so the title bar and the content still read as one.
            .overlay {
                GeometryReader { proxy in
                    glass
                        .frame(height: proxy.safeAreaInsets.top)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(.container, edges: .top)
                }
                .allowsHitTesting(false)
            }
            .modifier(HardTopScrollEdge())
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    // The logo, then the name and version.
                    HStack(spacing: 8) {
                        Image(nsImage: NSImage(named: "logo") ?? NSImage())
                            .resizable()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text(AppInfo.name).font(.headline)
                        Text(AppInfo.shortVersion)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                }
                .hiddenSharedBackground()
            }
    }

    /// The window's glass: the background and the title-bar band.
    private var glass: some View { WindowGlass() }
}
