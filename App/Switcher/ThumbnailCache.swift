import CoreGraphics

/// The last window thumbnails, by window id: at most 30, the least recently used goes first.
/// The images are stored at the pixel size they were captured at (thumbnail box x backing scale).
@MainActor
final class ThumbnailCache {
    private static let capacity = 30

    private var images: [CGWindowID: CGImage] = [:]
    /// The ids in `images`, least recently used first.
    private var recency: [CGWindowID] = []

    /// The thumbnail of `id`, if cached; a hit makes it the most recent entry.
    subscript(id: CGWindowID) -> CGImage? {
        guard let image = images[id] else { return nil }
        touch(id)
        return image
    }

    /// Stores or replaces the thumbnail of `id` as the most recent entry, evicting the least recent past 30.
    func set(_ image: CGImage, for id: CGWindowID) {
        images[id] = image
        touch(id)
        while recency.count > Self.capacity {
            images[recency.removeFirst()] = nil
        }
    }

    func removeAll() {
        images.removeAll()
        recency.removeAll()
    }

    private func touch(_ id: CGWindowID) {
        if let index = recency.firstIndex(of: id) { recency.remove(at: index) }
        recency.append(id)
    }
}
