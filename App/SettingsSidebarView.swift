// The Settings page, sidebar layout: the sections in a raised card, the selected one's cards on the right over the
// window's glass; each change is saved at once.
import AppKit
import ServiceManagement
import SwiftUI

/// The Settings page `MainView` shows; the tab layout defines the same name.
typealias SettingsRoot = SettingsSidebarView

/// A sidebar section. Adding one: a case, its row in `label`, its page in `SettingsSidebarView.content`.
enum SettingsSection: CaseIterable, Identifiable {
    case general, appearance, permissions, about

    var id: Self { self }

    var label: (title: String, icon: String) {
        switch self {
        case .general: ("General", "gearshape")
        case .appearance: ("Appearance", "paintbrush")
        case .permissions: ("Permissions", "hand.raised")
        case .about: ("About", "info.circle")
        }
    }
}

struct SettingsSidebarView: View {
    /// Not observable: `canCheckForUpdates` is set once at launch, before the window exists.
    let updater: Updater
    @Environment(Navigation.self) private var navigation
    @Environment(AccessibilityPermission.self) private var accessibility
    @Environment(ScreenRecordingPermission.self) private var screenRecording
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.defaultMode
    @AppStorage(Preferences.hotkeyModifierKey) private var hotkeyModifier: HotkeyModifier = .command
    @AppStorage(Preferences.screenScopeKey) private var screenScope: ScreenScope = .mouseScreen
    @AppStorage(Preferences.iconVisibilityKey) private var iconVisibility: IconVisibility = .menuBar
    @AppStorage(Preferences.thumbnailSizeKey) private var thumbnailSize: ThumbnailSize = .medium
    @AppStorage(Preferences.appIconSizeKey) private var appIconSize: AppIconSize = .medium
    @AppStorage(Preferences.hideAnimationKey) private var hideAnimation: HideAnimation = HideAnimation.none
    @AppStorage(Preferences.shrinkToFitKey) private var shrinkToFit = true
    @AppStorage(Preferences.showMinimizedKey) private var showMinimized = false
    @AppStorage(Preferences.showHiddenAppsKey) private var showHiddenApps = false
    /// Sections opened so far: kept alive like TabView's tabs, so a section keeps its state (and its scroll) when
    /// the user comes back to it.
    @State private var opened: Set<SettingsSection> = []
    @FocusState private var sidebarFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            ZStack {
                ForEach(SettingsSection.allCases.filter(opened.contains)) { page in
                    let selected = page == navigation.section
                    pageView(page)
                        .labeledContentStyle(.settingsRow)
                        .opacity(selected ? 1 : 0)
                        // The leaving section fades out faster, so the two never show through each other.
                        .animation(switchAnimation(selected: selected), value: selected)
                        .allowsHitTesting(selected)
                        .disabled(!selected)
                        .accessibilityHidden(!selected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { sidebarFocused = true }
        .onChange(of: navigation.section, initial: true) { _, new in opened.insert(new) }
        .onChange(of: appearance) { _, mode in mode.apply() }
    }

    /// Capsule rows with a gap between them in a raised card, not a `List(.sidebar)`: its selection fills the whole
    /// row, so the rows touch. Up/Down move the selection while the card has the focus.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: SidebarItemStyle.spacing) {
            ForEach(SettingsSection.allCases) { row in
                // Only sets the section: the page reads its state from the models, so the switch is instant.
                Button {
                    navigation.section = row
                    sidebarFocused = true
                } label: {
                    Label(row.label.title, systemImage: row.label.icon)
                }
                .buttonStyle(SidebarItemStyle(selected: row == navigation.section))
                .accessibilityAddTraits(row == navigation.section ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(SettingsMetrics.sidebarRowsPadding)
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($sidebarFocused)
        .onMoveCommand(perform: moveSelection)
        // A raised card like the toolbar's capsules, instead of a divider beside the sections.
        .modifier(GlassCard(cornerRadius: SettingsMetrics.sidebarRadius, raised: true))
        // At the top of the safe area: about 8 pt under the toolbar's capsules. The page starts at the same top edge.
        .padding([.leading, .bottom], SettingsMetrics.sidebarInset)
    }

    /// Up/Down in the sidebar: the previous or next section, stopping at the ends.
    private func moveSelection(_ direction: MoveCommandDirection) {
        let all = SettingsSection.allCases
        guard let index = all.firstIndex(of: navigation.section) else { return }
        switch direction {
        case .up where index > all.startIndex: navigation.section = all[index - 1]
        case .down where index < all.count - 1: navigation.section = all[index + 1]
        default: break
        }
    }

    /// A fade between sections; an instant switch under Reduce Motion.
    private func switchAnimation(selected: Bool) -> Animation? {
        if reduceMotion { return nil }
        return selected ? Motion.standard : Motion.exit
    }

    /// A section's page. No top padding: its first element is top-aligned with the sidebar card. About is one card
    /// that fills the column, its bottom aligned with the sidebar card's too; the others scroll.
    @ViewBuilder
    private func pageView(_ page: SettingsSection) -> some View {
        if page == .about {
            content(page)
                .padding(.leading, SettingsMetrics.sidebarInset)
                .padding(.trailing, SettingsMetrics.pagePadding)
                .padding(.bottom, SettingsMetrics.sidebarInset)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    content(page)
                }
                // 12 pt from the sidebar card's trailing edge.
                .padding(.leading, SettingsMetrics.sidebarInset)
                .padding([.trailing, .bottom], SettingsMetrics.pagePadding)
            }
        }
    }

    @ViewBuilder
    private func content(_ section: SettingsSection) -> some View {
        switch section {
        case .general:
            SettingsGroup("General") {
                LabeledContent {
                    tabs($hotkeyModifier, \.title)
                } label: {
                    Text("Hotkey")
                    hint("Hold the modifier, press Tab to move, release to switch. Shift goes back.")
                }
                SettingsDivider()
                LabeledContent("Show windows from") { tabs($screenScope, \.title) }
                SettingsDivider()
                LabeledContent("Show minimized windows") {
                    Toggle("Show minimized windows", isOn: $showMinimized)
                        .toggleStyle(CompactSwitch())
                        .labelsHidden()
                }
                SettingsDivider()
                LabeledContent {
                    Toggle("Show windows of hidden apps", isOn: $showHiddenApps)
                        .toggleStyle(CompactSwitch())
                        .labelsHidden()
                } label: {
                    Text("Show windows of hidden apps")
                    hint("Listed after the other windows, with a badge.")
                }
                SettingsDivider()
                LabeledContent {
                    tabs($iconVisibility, \.title)
                } label: {
                    Text("Show CmdTab in")
                    hint("When hidden, open CmdTab again to show Settings.")
                }
                SettingsDivider()
                LaunchAtLoginRow()
            }
        case .appearance:
            SettingsGroup("Appearance") {
                LabeledContent("Theme") {
                    CapsuleTabs(selection: $appearance, tabs: AppearanceMode.allCases,
                                title: { Text($0.title) }, compact: true)
                        .fixedSize()
                }
                SettingsDivider()
                LabeledContent("Thumbnail size") { tabs($thumbnailSize, \.title) }
                SettingsDivider()
                LabeledContent("App icon size") { tabs($appIconSize, \.title) }
                SettingsDivider()
                LabeledContent {
                    Toggle("Shrink to fit", isOn: $shrinkToFit)
                        .toggleStyle(CompactSwitch())
                        .labelsHidden()
                } label: {
                    Text("Shrink to fit")
                    hint("When not all windows fit, previews get smaller, down to "
                        + "\(Int(SwitcherView.minimumThumbnail.width)) × "
                        + "\(Int(SwitcherView.minimumThumbnail.height)) pt. "
                        + "Windows that still do not fit are not shown.")
                }
                SettingsDivider()
                LabeledContent("Hide animation") { tabs($hideAnimation, \.title) }
            }
        case .permissions:
            SettingsGroup("Permissions") {
                permissionRow(title: "Accessibility", hint: "Required.", granted: accessibility.isTrusted,
                              request: accessibility.request)
                SettingsDivider()
                permissionRow(title: "Screen Recording",
                              hint: "For window previews and titles. Without it CmdTab shows app icons and names. "
                                  + "Applies after CmdTab restarts.",
                              granted: screenRecording.isGranted, request: screenRecording.request)
            }
        case .about:
            // One full-height card, its content at the top under a larger top padding.
            VStack(spacing: 10) {
                Image(nsImage: NSImage(named: "logo") ?? NSImage())
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text(AppInfo.name).font(.title2.weight(.semibold))
                Text("Version \(AppInfo.version)")
                    .foregroundStyle(.secondary)
                Text("Anh-Thi DINH")
                Link("github.com/dinhanhthi/CmdTab",
                     destination: URL(string: "https://github.com/dinhanhthi/CmdTab")!)
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(!updater.canCheckForUpdates)
            }
            .padding(.top, 40)
            .padding(.horizontal, SettingsMetrics.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
        }
    }

    /// A compact `CapsuleTabs` over every case of a setting, each titled with the case's `title`.
    private func tabs<Value: CaseIterable & Hashable>(_ selection: Binding<Value>, _ title: KeyPath<Value, String>)
        -> some View
    {
        CapsuleTabs(selection: selection, tabs: Array(Value.allCases), title: { Text($0[keyPath: title]) },
                    compact: true)
            .fixedSize()
    }

    /// A permission: its title and hint, then Granted or a button that asks for it.
    private func permissionRow(title: String, hint: String, granted: Bool, request: @escaping () -> Void)
        -> some View
    {
        LabeledContent {
            if granted {
                Text("Granted")
                    .foregroundStyle(.secondary)
            } else {
                Button("Grant…", action: request)
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        } label: {
            Text(title)
            self.hint(hint)
        }
    }

    /// The hint under a row's title.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.settingsCaption)
            .foregroundStyle(.secondary)
    }
}

/// Start at login through `SMAppService.mainApp`, with a `CompactSwitch` (which draws no label of its own). The
/// switch follows the login item's real status, which can also change in System Settings > General > Login Items. The
/// status is read on appear and when the app becomes active, never in `body`.
private struct LaunchAtLoginRow: View {
    @State private var status = SMAppService.Status.notRegistered
    @State private var note: String?

    var body: some View {
        LabeledContent {
            Toggle("Start at login", isOn: isOn)
                .toggleStyle(CompactSwitch())
                .labelsHidden()
        } label: {
            Text("Start at login")
            if let hint = note ?? approvalHint {
                Text(hint)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: sync)
        // The section stays alive once opened: catch a change made in System Settings when the app comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in sync() }
    }

    private var isOn: Binding<Bool> {
        Binding(get: { status == .enabled || status == .requiresApproval }, set: { set($0) })
    }

    private var approvalHint: String? {
        status == .requiresApproval ? "Approve CmdTab in System Settings > General > Login Items." : nil
    }

    private func set(_ enabled: Bool) {
        note = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            note = error.localizedDescription
        }
        sync()
    }

    private func sync() {
        status = SMAppService.mainApp.status
    }
}

/// The app's name and version from the bundle (About section and the window's toolbar).
enum AppInfo {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "CmdTab"
    }

    /// "0.1.0".
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// "0.1.0 (1)".
    static var version: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(shortVersion) (\($0))" } ?? shortVersion
    }
}
