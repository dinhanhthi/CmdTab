import AppKit

/// The switcher's content: one layer-backed view that draws the window tiles as sublayers and moves one
/// highlight behind the selected tile. Created once with the panel and kept: the tile layers come from a
/// grow-only pool, and a show only sets `contents`, `string`, `frame` and `isHidden` with layer actions disabled.
/// Window titles are untrusted text: shown as plain strings, never parsed or logged.
final class SwitcherView: NSView {
    struct Tile {
        let id: CGWindowID
        let title: String
        let icon: CGImage?
        let thumbnail: CGImage?
    }

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    // Layout, in points.
    private nonisolated static let padding: CGFloat = 16
    private nonisolated static let gap: CGFloat = 12
    /// The title row under the thumbnail box.
    private nonisolated static let titleHeight: CGFloat = 18
    /// The part of the screen's visible size the panel may take.
    private nonisolated static let screenShare: CGFloat = 0.9
    private static let titleSpacing: CGFloat = 3
    private static let fontSize: CGFloat = 11
    private static let cornerRadius: CGFloat = 8
    private static let highlightInset: CGFloat = 6
    /// The side of the app icon that stands in for a missing thumbnail.
    private static let placeholderSide: CGFloat = 64

    /// The layers of one pooled tile; `thumbnail`, `icon` and `title` sit in `container`, in its coordinates.
    private struct TileLayers {
        let container = CALayer()
        let thumbnail = CALayer()
        let icon = CALayer()
        let title = CATextLayer()
    }

    private var pool: [TileLayers] = []
    private let highlight = CALayer()
    /// The tiles on show and their frames, same order.
    private var tiles: [Tile] = []
    private var frames: [CGRect] = []
    private var thumbnailBox: CGSize = .zero
    private var iconSide: CGFloat = 0
    /// The contents scale of every pooled layer.
    private var scale: CGFloat = 0
    /// The tile under the pointer at the last `mouseMoved`.
    private var hovered: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        highlight.isHidden = true
        highlight.cornerRadius = Self.cornerRadius + Self.highlightInset
        highlight.cornerCurve = .continuous
        highlight.borderWidth = 3
        layer?.addSublayer(highlight)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) {
        fatalError("SwitcherView is not loaded from a nib")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // AppKit makes the view's appearance current here, so the system colours resolve for light or dark mode.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The accent colour, filled and outlined, so the selection reads at a glance over any wallpaper.
        let accent = NSColor.controlAccentColor
        highlight.backgroundColor = accent.withAlphaComponent(0.3).cgColor
        highlight.borderColor = accent.cgColor
        let text = NSColor.labelColor.cgColor
        for layers in pool { layers.title.foregroundColor = text }
        CATransaction.commit()
    }

    // MARK: Layout

    /// The panel size and the tile frames for `count` tiles: centred rows, a new row when the next tile would
    /// pass 90 % of `available` (the screen's visible size) in width, no row past 90 % of its height, so
    /// `frames.count` can be smaller than `count` (the first tiles are kept). Frames are in the view's flipped
    /// space and `panelSize` includes the padding. Pure arithmetic.
    nonisolated static func layout(count: Int, thumbnail: CGSize, icon: CGFloat, available: CGSize)
        -> (panelSize: CGSize, frames: [CGRect])
    {
        // `icon` does not change the size: the corner icon hangs at most 12 pt over the box, within gap and padding.
        arrange(
            count: count, tile: tileSize(thumbnail),
            limit: CGSize(width: available.width * screenShare, height: available.height * screenShare))
    }

    private nonisolated static func tileSize(_ thumbnail: CGSize) -> CGSize {
        CGSize(width: thumbnail.width, height: thumbnail.height + titleHeight)
    }

    /// As many tiles per row and rows as fit `limit` (at least one of each). Given a `panelSize` it returns,
    /// it gives back the same frames, which is how `show` lays out without the screen size.
    private nonisolated static func arrange(count: Int, tile: CGSize, limit: CGSize)
        -> (panelSize: CGSize, frames: [CGRect])
    {
        guard count > 0, tile.width > 0, tile.height > 0 else { return (.zero, []) }
        // The small epsilon keeps an exact fit from flooring one below through float error.
        let perRow = max(1, Int(((limit.width - 2 * padding + gap) / (tile.width + gap) + 0.001).rounded(.down)))
        let maxRows = max(1, Int(((limit.height - 2 * padding + gap) / (tile.height + gap) + 0.001).rounded(.down)))
        let kept = min(count, perRow * maxRows)
        let columns = min(kept, perRow)
        let rows = (kept + perRow - 1) / perRow
        let contentWidth = CGFloat(columns) * tile.width + CGFloat(columns - 1) * gap
        let panelSize = CGSize(
            width: contentWidth + 2 * padding,
            height: CGFloat(rows) * tile.height + CGFloat(rows - 1) * gap + 2 * padding)

        var frames: [CGRect] = []
        frames.reserveCapacity(kept)
        for index in 0..<kept {
            let row = index / perRow
            let inRow = min(perRow, kept - row * perRow)
            let rowWidth = CGFloat(inRow) * tile.width + CGFloat(inRow - 1) * gap
            let x = padding + ((contentWidth - rowWidth) / 2).rounded() + CGFloat(index % perRow) * (tile.width + gap)
            let y = padding + CGFloat(row) * (tile.height + gap)
            frames.append(CGRect(x: x, y: y, width: tile.width, height: tile.height))
        }
        return (panelSize, frames)
    }

    // MARK: Showing

    /// Shows `tiles` (front to back) with `selected` highlighted. `thumbnail` is the box of `ThumbnailSize`,
    /// `icon` the side of `AppIconSize`. Call it after `SwitcherPanel.place`: the tiles are laid out in the
    /// panel's size and drawn at its screen's scale.
    func show(tiles: [Tile], selected: Int, thumbnail: CGSize, icon: CGFloat) {
        frames = Self.arrange(count: tiles.count, tile: Self.tileSize(thumbnail), limit: window?.frame.size ?? bounds.size)
            .frames
        self.tiles = Array(tiles.prefix(frames.count))
        thumbnailBox = thumbnail
        iconSide = icon
        hovered = nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if backingScale != scale {
            scale = backingScale
            for layers in pool { setScale(of: layers) }
        }
        if pool.count < self.tiles.count { grow(to: self.tiles.count) }
        for (index, layers) in pool.enumerated() {
            guard index < self.tiles.count else {
                layers.container.isHidden = true
                continue
            }
            layers.container.frame = frames[index]
            fill(layers, with: self.tiles[index])
            layers.container.isHidden = false
        }
        highlight.isHidden = true
        select(selected)
        CATransaction.commit()
    }

    /// Moves the highlight to tile `index`; an index outside the tiles on show is ignored.
    func select(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = frames[index].insetBy(dx: -Self.highlightInset, dy: -Self.highlightInset)
        highlight.isHidden = false
        CATransaction.commit()
    }

    /// Puts `image` in the tile of window `id`; an id not on show is ignored.
    func setThumbnail(_ image: CGImage, for id: CGWindowID) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = tiles[index]
        tiles[index] = Tile(id: tile.id, title: tile.title, icon: tile.icon, thumbnail: image)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill(pool[index], with: tiles[index])
        CATransaction.commit()
    }

    /// Adds pooled tiles up to `count`. Their look is set once here; their colours come from `updateLayer`.
    private func grow(to count: Int) {
        while pool.count < count {
            let layers = TileLayers()
            layers.thumbnail.contentsGravity = .resizeAspect
            layers.thumbnail.cornerRadius = Self.cornerRadius
            layers.thumbnail.cornerCurve = .continuous
            layers.thumbnail.masksToBounds = true
            layers.icon.contentsGravity = .resizeAspect
            layers.title.font = NSFont.systemFont(ofSize: Self.fontSize)
            layers.title.fontSize = Self.fontSize
            layers.title.alignmentMode = .center
            layers.title.truncationMode = .end
            layers.title.isWrapped = false
            layers.container.addSublayer(layers.thumbnail)
            layers.container.addSublayer(layers.icon)
            layers.container.addSublayer(layers.title)
            setScale(of: layers)
            layer?.addSublayer(layers.container)
            pool.append(layers)
        }
        needsDisplay = true
    }

    private func setScale(of layers: TileLayers) {
        layers.thumbnail.contentsScale = scale
        layers.icon.contentsScale = scale
        layers.title.contentsScale = scale
    }

    /// Sets one tile's images, title and the frames inside it. Call it with layer actions disabled.
    private func fill(_ layers: TileLayers, with tile: Tile) {
        let box = CGRect(origin: .zero, size: thumbnailBox)
        if let thumbnail = tile.thumbnail {
            layers.thumbnail.frame = box
            layers.thumbnail.contents = thumbnail
            layers.icon.contents = tile.icon
            layers.icon.isHidden = tile.icon == nil
        } else {
            // No thumbnail: the app icon, centred at 64 pt, stands in for it, and the corner icon goes.
            let side = min(Self.placeholderSide, box.width, box.height)
            layers.thumbnail.frame = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
            layers.thumbnail.contents = tile.icon
            layers.icon.isHidden = true
        }
        // Bottom-right, three quarters on the box and a quarter over its right and bottom edges.
        let overhang = iconSide / 4
        layers.icon.frame = CGRect(
            x: box.maxX - iconSide + overhang, y: box.maxY - iconSide + overhang, width: iconSide, height: iconSide)
        layers.title.frame = CGRect(
            x: 0, y: box.maxY + Self.titleSpacing, width: box.width, height: Self.titleHeight - Self.titleSpacing)
        if layers.title.string as? String != tile.title { layers.title.string = tile.title }
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        let index = tileIndex(at: event)
        guard index != hovered else { return }
        hovered = index
        if let index { onHover?(index) }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = tileIndex(at: event) { onClick?(index) }
    }

    private func tileIndex(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return frames.firstIndex { $0.contains(point) }
    }
}
