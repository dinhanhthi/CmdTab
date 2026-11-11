import CoreGraphics
import ScreenCaptureKit

/// Window thumbnails through ScreenCaptureKit (spike rule (b)): one shareable-content lookup, then one
/// screenshot per window. Runs off the main actor; only `deliver` hops to it. Needs Screen Recording.
enum WindowCapture {
    /// Captures `ids` in the given order, each aspect-fit in `box` (points) at `scale`, and hands every image to
    /// `deliver`. A window that is not on screen or fails is skipped silently. Cancelling the task stops it:
    /// nothing is delivered after the cancel is seen.
    @concurrent
    static func capture(
        _ ids: [CGWindowID], box: CGSize, scale: CGFloat,
        deliver: @escaping @MainActor (CGWindowID, CGImage) -> Void
    ) async {
        guard !Task.isCancelled,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return }
        let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids {
            guard !Task.isCancelled else { return }
            guard let window = windows[id], let size = pixelSize(of: window.frame.size, in: box, scale: scale) else {
                continue
            }
            let token = Perf.begin("capture")
            let configuration = SCStreamConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.scalesToFit = true
            let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
            Perf.end(token)
            // A cancel during the screenshot drops its image.
            guard !Task.isCancelled else { return }
            if let image { await deliver(id, image) }
        }
    }

    /// The whole-pixel size of `frame` aspect-fit in `box` at `scale`, at least 1 x 1; nil for an empty frame.
    private static func pixelSize(of frame: CGSize, in box: CGSize, scale: CGFloat) -> (width: Int, height: Int)? {
        guard frame.width > 0, frame.height > 0, box.width > 0, box.height > 0, scale > 0 else { return nil }
        let fit = min(box.width / frame.width, box.height / frame.height) * scale
        return (max(1, Int((frame.width * fit).rounded())), max(1, Int((frame.height * fit).rounded())))
    }
}
