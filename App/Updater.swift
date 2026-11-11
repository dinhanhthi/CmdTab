import AppKit
import os
import Sparkle

/// Sparkle updater, started only when `SUPublicEDKey` is a base64 Ed25519 public key (32 bytes); an empty or
/// malformed key would show Sparkle's misconfiguration alert. Until then "Check for Updates…" stays disabled.
/// While the menu bar item shows, a scheduled check that finds an update shows no Sparkle alert (gentle reminders):
/// it sets `availableUpdateVersion` for the item's badge, and "Check for Updates…" brings the update in focus.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private(set) var canCheckForUpdates = false

    /// Version of the update a scheduled check found, until its update session ends.
    private(set) var availableUpdateVersion: String?

    /// Called when `availableUpdateVersion` changes.
    var onAvailableUpdateChange: (() -> Void)?

    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                               userDriverDelegate: self)

    func start() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Data(base64Encoded: key)?.count == 32 else {
            Logger(subsystem: "com.math2it.cmdtab", category: "Updater")
                .notice("Updater off: SUPublicEDKey is not a base64 32-byte EdDSA public key")
            return
        }
        controller.startUpdater()
        canCheckForUpdates = true
    }

    /// Sparkle's check, with its window in front: CmdTab is an LSUIElement app.
    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate (called on the main thread)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle's own alert shows when no menu bar item listens (Dock or Hidden icon): the badge would have nowhere
    /// to go.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated { onAvailableUpdateChange == nil }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            availableUpdateVersion = version
            onAvailableUpdateChange?()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            guard availableUpdateVersion != nil else { return }
            availableUpdateVersion = nil
            onAvailableUpdateChange?()
        }
    }
}
