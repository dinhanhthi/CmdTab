// Accessibility and Screen Recording permission state, after SimpleMenu's AccessibilityPermission.
import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import os

private let logger = Logger(subsystem: "com.math2it.cmdtab", category: "Permissions")

/// Accessibility (AX) trust state. Reading it never prompts; only `request()` does, and that must only be called
/// from a user action. While untrusted, a 1 s poll picks up a grant made while the app runs (an accessory app rarely
/// becomes active); it stops as soon as trust is seen, so nothing runs while trusted.
@MainActor
@Observable
final class AccessibilityPermission {
    private(set) var isTrusted: Bool

    /// Called once each time the state flips from untrusted to trusted.
    @ObservationIgnored var onTrusted: (() -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    private static let settingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    init() {
        isTrusted = AXIsProcessTrusted()
        logger.notice("accessibility trusted=\(self.isTrusted, privacy: .public)")
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(AXIsProcessTrusted()) }
        }
        if !isTrusted { startPolling() }
    }

    /// Shows the system prompt and opens System Settings > Privacy & Security > Accessibility.
    func request() {
        // The value of `kAXTrustedCheckOptionPrompt`, a global var Swift 6 rejects as not concurrency-safe.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        update(AXIsProcessTrustedWithOptions(options))
        NSWorkspace.shared.open(Self.settingsURL)
        if !isTrusted { startPolling() }
    }

    private func update(_ trusted: Bool) {
        if trusted { stopPolling() }
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        logger.notice("accessibility trusted=\(trusted, privacy: .public)")
        if trusted { onTrusted?() }
    }

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(AXIsProcessTrusted()) }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

/// Screen Recording state. Reading it never prompts; only `request()` does. Refreshed when the app becomes active;
/// no poll.
@MainActor
@Observable
final class ScreenRecordingPermission {
    private(set) var isGranted: Bool

    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    private static let settingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    init() {
        isGranted = CGPreflightScreenCaptureAccess()
        logger.notice("screen recording granted=\(self.isGranted, privacy: .public)")
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(CGPreflightScreenCaptureAccess()) }
        }
    }

    /// Shows the system prompt and opens System Settings > Privacy & Security > Screen Recording.
    func request() {
        update(CGRequestScreenCaptureAccess())
        NSWorkspace.shared.open(Self.settingsURL)
    }

    private func update(_ granted: Bool) {
        guard granted != isGranted else { return }
        isGranted = granted
        logger.notice("screen recording granted=\(granted, privacy: .public)")
    }
}
