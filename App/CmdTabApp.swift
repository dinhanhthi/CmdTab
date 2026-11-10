// The app entry: an AppKit delegate that will own the switcher and the app's shared state.
import AppKit

/// AppKit entry point: no SwiftUI `App`, so nothing but AppKit is loaded at launch.
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

/// Lives for the app lifetime. No window: the app stays in the background (LSUIElement).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Throwaway platform spike: `CmdTab --spike <mode> --out <file>`.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--spike") {
            SpikeRunner.run(arguments: arguments)
        }
        #endif
    }
}
