import AppKit
import SwiftUI

// MARK: - HomeItemCell

/// Native card as a single layer-backed view. Everything static — title,
/// subtitle, explicit badge, chart rank, like button — is drawn into the
/// view's own backing bitmap once per configure; the artwork and its hover
/// lift are sublayers; the glass play overlay is the one piece of SwiftUI,
/// hosted only while the card is hovered.
///
/// One `NSView` per card is the point: SwiftUI detaches and re-attaches each
/// shelf's platform view as it crosses the viewport, and AppKit's cost for
/// that (and for every scroll frame while attached) scales with the number of
/// views in the subtree. Measured with a multi-view card it was ~7 dropped
/// frames per scroll pass; with a 3-view card, under 1.
@MainActor
final class HomeItemCell: NSView {
    static let artworkHeight: CGFloat = 160
    static let squareWidth: CGFloat = 160
    static let videoWidth: CGFloat = 284
    /// Artwork + 8pt gap + two title lines + subtitle.
    static let height: CGFloat = 220
    static let cornerRadius: CGFloat = 8
    static let likeButtonSize: CGFloat = 22
    static let likeButtonInset: CGFloat = 6
    static let playButtonSize: CGFloat = 48

    static func width(for item: HomeSectionItem) -> CGFloat {
        item.isVideoSong ? self.videoWidth : self.squareWidth
    }

    var menuProvider: (() -> NSMenu?)?
    /// Called when the like control (drawn at the artwork's top-trailing corner) is clicked.
    var likeAction: (() -> Void)?

    private let artwork = HomeItemArtworkLayers()
    /// Like control and chart rank sit above the artwork, so they are layers
    /// (the view's own bitmap is beneath the artwork sublayers).
    private let likeLayer = CALayer()
    private let rankLayer = CALayer()
    private var playOverlay: NSHostingView<AnyView>?

    private(set) var item: HomeSectionItem?
    private var rank: Int?
    private var quickPlayAction: (() -> Void)?
    private var environment = EnvironmentValues()
    private var allowsLikeActions = false
    private var isLiked = false
    private var isLikeFocused = false
    private var overlayScale: CGFloat = 0
    private(set) var isHovered = false
    private var imageLoadTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.layer?.addSublayer(self.artwork.liftLayer)
        self.likeLayer.contentsGravity = .center
        self.likeLayer.isHidden = true
        // The view is flipped, so "top" gravity lands at the visual bottom.
        self.rankLayer.contentsGravity = .topLeft
        self.rankLayer.isHidden = true
        self.layer?.addSublayer(self.rankLayer)
        self.layer?.addSublayer(self.likeLayer)
        self.focusRingType = .exterior
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    /// Frame of the like control in the view's coordinates, or nil when it is not shown.
    var likeButtonFrame: NSRect? {
        guard self.showsLikeButton, let item else { return nil }
        return self.likeControlFrame(width: Self.width(for: item))
    }

    private var isRightToLeft: Bool {
        self.environment.layoutDirection == .rightToLeft
    }

    private func likeControlFrame(width: CGFloat) -> NSRect {
        NSRect(
            x: self.isRightToLeft ? Self.likeButtonInset : width - Self.likeButtonInset - Self.likeButtonSize,
            y: Self.likeButtonInset,
            width: Self.likeButtonSize,
            height: Self.likeButtonSize
        )
    }

    /// Frame of the hovered play button, or nil when the card has none. Songs
    /// show a decorative icon instead, since clicking anywhere on them plays.
    var playButtonFrame: NSRect? {
        guard self.isHovered, self.quickPlayAction != nil, let item else { return nil }
        switch item {
        case .playlist, .album: return self.playOverlayFrame(width: Self.width(for: item))
        case .song, .artist: return nil
        }
    }

    private func playOverlayFrame(width: CGFloat) -> NSRect {
        NSRect(
            x: (width - Self.playButtonSize) / 2,
            y: (Self.artworkHeight - Self.playButtonSize) / 2,
            width: Self.playButtonSize,
            height: Self.playButtonSize
        )
    }

    private var showsPlayOverlay: Bool {
        guard let item, self.isHovered else { return false }
        if case .song = item {
            return true
        }
        return self.playButtonFrame != nil
    }

    func performPlayAction() {
        self.quickPlayAction?()
    }

    private var supportsLikeAction: Bool {
        guard let item, case .song = item else { return false }
        return self.allowsLikeActions
    }

    private var showsLikeButton: Bool {
        self.supportsLikeAction && (self.isLiked || self.isHovered || self.isLikeFocused)
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        let scale = self.window?.backingScaleFactor ?? 2
        let width = Self.width(for: item)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.artwork.layout(in: NSRect(x: 0, y: 0, width: width, height: Self.artworkHeight), scale: scale)
        // Flipped view: layer frames are in the view's (top-left origin) space.
        self.likeLayer.frame = self.likeControlFrame(width: width)
        // Mirrors the SwiftUI card: leading 8, 60pt above the card's bottom.
        self.rankLayer.frame = NSRect(x: self.isRightToLeft ? 0 : 8, y: 0, width: width - 8, height: Self.height - 60)
        self.rankLayer.contentsGravity = self.isRightToLeft ? .topRight : .topLeft
        if self.overlayScale != scale {
            self.updateOverlayLayers()
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.needsLayout = true
        self.needsDisplay = true
    }

    private func updateOverlayLayers() {
        let scale = self.window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            if self.showsLikeButton {
                self.likeLayer.contents = self.likeImage(liked: self.isLiked, scale: scale)
                self.likeLayer.isHidden = false
            } else {
                self.likeLayer.isHidden = true
            }
            if let rank {
                self.rankLayer.contents = Self.rankImage(rank, scale: scale, isRightToLeft: self.isRightToLeft)
                self.rankLayer.isHidden = false
            } else {
                self.rankLayer.isHidden = true
            }
        }
        self.likeLayer.contentsScale = scale
        self.rankLayer.contentsScale = scale
        self.overlayScale = scale
        CATransaction.commit()
    }

    /// The unliked glyph resolves a dynamic color; bitmap resolution must also
    /// match the destination layer's backing scale.
    private static var likeImages: [String: CGImage] = [:]

    private func likeImage(liked: Bool, scale: CGFloat) -> CGImage? {
        let key = "\(liked)-\(self.effectiveAppearance.name.rawValue)-\(scale)"
        if let cached = Self.likeImages[key] {
            return cached
        }
        let symbol = liked ? "hand.thumbsup.fill" : "hand.thumbsup"
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [liked ? .systemRed : .secondaryLabelColor]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        let rendered = HomeItemLayerImage.render(size: NSSize(width: Self.likeButtonSize, height: Self.likeButtonSize), scale: scale) { rect in
            let size = image.size
            image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
        Self.likeImages[key] = rendered
        return rendered
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Text colors are dynamic but drawn into our own bitmap; the layer
        // images resolve system colors when rendered.
        self.needsDisplay = true
        if let item {
            self.artwork.refreshAppearance(for: item)
        }
        self.updateOverlayLayers()
    }

    private static func rankImage(_ rank: Int, scale: CGFloat, isRightToLeft: Bool) -> CGImage? {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let string = NSAttributedString(string: "\(rank)", attributes: [
            .font: Self.rankFont,
            .foregroundColor: NSColor.labelColor,
            .shadow: shadow,
        ])
        let size = string.size()
        let padded = NSSize(width: ceil(size.width) + 8, height: ceil(size.height) + 8)
        return HomeItemLayerImage.render(size: padded, scale: scale) { _ in
            string.draw(at: NSPoint(x: isRightToLeft ? 8 : 0, y: 4))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        self.menuProvider?() ?? super.menu(for: event)
    }

    // MARK: Configuration

    func configure(
        item: HomeSectionItem,
        rank: Int?,
        allowsLikeActions: Bool,
        quickPlayAction: (() -> Void)?,
        environment: EnvironmentValues
    ) {
        let hasSamePlayAction = (self.quickPlayAction == nil) == (quickPlayAction == nil)
        let directionChanged = self.environment.layoutDirection != environment.layoutDirection
        self.environment = environment
        self.quickPlayAction = quickPlayAction
        if directionChanged {
            self.needsLayout = true
            self.needsDisplay = true
            self.updateOverlayLayers()
            self.noteFocusRingMaskChanged()
        }
        if self.item?.hasSameCardContent(as: item) == true,
           self.rank == rank,
           self.allowsLikeActions == allowsLikeActions,
           hasSamePlayAction
        {
            // The hosted overlay carries the forwarded environment; keep it
            // current if it is showing.
            if self.isHovered {
                self.updatePlayOverlay()
            }
            return
        }
        let sameSong = self.item?.id == item.id
        self.item = item
        self.rank = rank
        self.allowsLikeActions = allowsLikeActions
        self.setLikeFocused(self.isLikeFocused)
        self.imageLoadTask?.cancel()
        self.imageLoadTask = nil

        self.artwork.configure(item: item)
        // Like state is pushed by the shelf; keep it across a metadata-only
        // refresh of the same song so the card doesn't flash to "unliked".
        if !sameSong {
            self.isLiked = false
            // A card that changes song drops its hover; a metadata refresh of
            // the same song keeps it (the shelf still tracks it as hovered).
            self.setHovered(false, animated: false)
        } else if self.isHovered {
            // Width or environment may have changed: re-place the overlay.
            self.updatePlayOverlay()
        }
        self.loadArtwork(for: item)
        self.updateOverlayLayers()
        self.needsLayout = true
        self.needsDisplay = true

        let subtitle = item.homeCardSubtitle ?? ""
        var accessibilityLabel = rank.map { String(localized: "Number \($0), \(item.title)") } ?? item.title
        if !subtitle.isEmpty {
            accessibilityLabel += ", \(subtitle)"
        }
        if self.isExplicit {
            accessibilityLabel += ", \(String(localized: "Explicit"))"
        }
        self.setAccessibilityLabel(accessibilityLabel)
        self.updateAccessibilityActions()
    }

    /// Called on click, Return/Space, or an accessibility press.
    var activateAction: (() -> Void)?

    private func updateAccessibilityActions() {
        var actions: [NSAccessibilityCustomAction] = []
        if let item, self.quickPlayAction != nil {
            actions.append(NSAccessibilityCustomAction(name: String(localized: "Play \(item.title)")) { [weak self] in
                self?.quickPlayAction?()
                return true
            })
        }
        if let item, case .song = item, self.allowsLikeActions {
            let name = self.isLiked ? String(localized: "Unlike") : String(localized: "Like")
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                self?.toggleLike()
                return true
            })
        }
        self.setAccessibilityCustomActions(actions)
    }

    override func accessibilityPerformPress() -> Bool {
        guard self.activateAction != nil else { return false }
        self.activateAction?()
        return true
    }

    // MARK: Keyboard

    /// Like AppKit's own buttons, cards join the key view loop only under Full
    /// Keyboard Access: with hundreds of cards alive, unconditional first-responder
    /// status made every shelf re-attach rebuild the window's key loop.
    override var acceptsFirstResponder: Bool {
        NSApp.isFullKeyboardAccessEnabled
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        self.setLikeFocused(self.window?.keyViewSelectionDirection == .selectingPrevious)
        self.scrollToVisible(self.bounds)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        self.setLikeFocused(false)
        return true
    }

    override var focusRingMaskBounds: NSRect {
        if self.isLikeFocused, let likeButtonFrame {
            return likeButtonFrame
        }
        guard let item else { return .zero }
        return NSRect(x: 0, y: 0, width: Self.width(for: item), height: Self.artworkHeight)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: self.focusRingMaskBounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard self.window?.firstResponder === self, event.keyCode == 49,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
        else { return super.performKeyEquivalent(with: event) }
        // Focused controls handle Space before the app's Play/Pause shortcut.
        self.keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            self.moveKeyboardFocus(backwards: event.modifierFlags.contains(.shift))
            return
        }
        switch event.keyCode {
        case 36, 76, 49: // Return, Enter, Space
            if self.isLikeFocused {
                self.likeAction?()
            } else {
                self.activateAction?()
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// Two keyboard targets share the card's single view. Tab visits the like
    /// control before moving to the next card; Shift-Tab reverses that order.
    private func moveKeyboardFocus(backwards: Bool) {
        if backwards {
            if self.isLikeFocused {
                self.setLikeFocused(false)
            } else {
                self.window?.selectPreviousKeyView(self)
                if self.window?.firstResponder === self {
                    self.setLikeFocused(true)
                }
            }
        } else if self.supportsLikeAction, !self.isLikeFocused {
            self.setLikeFocused(true)
        } else {
            self.setLikeFocused(false)
            self.window?.selectNextKeyView(self)
        }
    }

    private func setLikeFocused(_ focused: Bool) {
        let focused = focused && self.supportsLikeAction
        guard focused != self.isLikeFocused else { return }
        self.isLikeFocused = focused
        self.updateOverlayLayers()
        self.noteFocusRingMaskChanged()
    }

    private var isExplicit: Bool {
        if case let .song(song) = self.item {
            return song.isExplicit == true
        }
        return false
    }

    private func loadArtwork(for item: HomeSectionItem) {
        let urls = Self.thumbnailURLs(for: item)
        guard !urls.isEmpty else { return }
        let targetSize = CGSize(width: Self.width(for: item), height: Self.artworkHeight)
        // A memory-cache hit is applied synchronously with no fade, so a
        // rebuilt shelf shows its artwork in the same frame it appears.
        if let url = urls.first, let cached = ImageCache.shared.cachedImage(for: url, targetSize: targetSize) {
            self.artwork.setImage(cached, animated: false)
            return
        }
        let itemID = item.id
        self.imageLoadTask = Task { [weak self] in
            for url in urls {
                if let image = await ImageCache.shared.image(for: url, targetSize: targetSize) {
                    guard !Task.isCancelled, let self, self.item?.id == itemID else { return }
                    self.artwork.setImage(image, animated: !self.environment.accessibilityReduceMotion)
                    return
                }
                if Task.isCancelled {
                    return
                }
            }
        }
    }

    /// Same candidate order as `HomeSectionItemCard`: wide video thumbnail first
    /// for video songs, then the standard artwork, then the fallback.
    static func thumbnailURLs(for item: HomeSectionItem) -> [URL] {
        var candidates: [URL?] = []
        if item.isVideoSong, case let .song(song) = item {
            candidates = [song.wideHighQualityThumbnailURL, item.thumbnailURL?.highQualityThumbnailURL, song.fallbackThumbnailURL]
        } else {
            candidates = [item.thumbnailURL?.highQualityThumbnailURL]
        }
        var seen = Set<URL>()
        return candidates.compactMap(\.self).filter { seen.insert($0).inserted }
    }

    // MARK: Like status

    /// Like status is observed once per shelf (see `HomeItemShelfView`) and
    /// pushed here, rather than registering an observation per card.
    func setLiked(_ liked: Bool) {
        guard liked != self.isLiked else { return }
        self.isLiked = liked
        self.updateOverlayLayers()
        self.updateAccessibilityActions()
    }

    func toggleLike() {
        guard let item, case let .song(song) = item, self.allowsLikeActions else { return }
        HapticService.success()
        let manager = SongLikeStatusManager.shared
        if self.isLiked {
            SongActionsHelper.unlikeSong(song, likeStatusManager: manager)
        } else {
            SongActionsHelper.likeSong(song, likeStatusManager: manager)
        }
    }

    // MARK: Hover

    func setHovered(_ hovered: Bool, animated: Bool) {
        guard hovered != self.isHovered || !animated else { return }
        self.isHovered = hovered
        self.artwork.setLifted(hovered, animated: animated)
        self.updatePlayOverlay()
        self.updateOverlayLayers()
    }

    /// The glass play icon is the one piece of SwiftUI on the card, hosted only
    /// while this card is hovered, so at most one such view exists per shelf.
    /// It never takes clicks: the shelf routes presses on `playButtonFrame`.
    private func updatePlayOverlay() {
        guard let item, self.showsPlayOverlay else {
            self.playOverlay?.removeFromSuperview()
            self.playOverlay = nil
            return
        }
        let root = AnyView(
            SongCoverPlayOverlay(size: CGSize(width: Self.playButtonSize, height: Self.playButtonSize))
                .environment(\.self, self.environment)
        )
        let frame = self.playOverlayFrame(width: Self.width(for: item))
        if let playOverlay {
            playOverlay.rootView = root
            playOverlay.frame = frame
        } else {
            let overlay = NSHostingView(rootView: root)
            overlay.sizingOptions = []
            overlay.frame = frame
            self.addSubview(overlay)
            self.playOverlay = overlay
        }
    }

    // MARK: Drawing

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let subtitleFont = NSFont.systemFont(ofSize: 11)
    private static let badgeFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let rankFont: NSFont = {
        let descriptor = NSFont.systemFont(ofSize: 32, weight: .bold).fontDescriptor.withDesign(.rounded)
        return descriptor.flatMap { NSFont(descriptor: $0, size: 32) } ?? .systemFont(ofSize: 32, weight: .bold)
    }()

    override func draw(_: NSRect) {
        guard let item else { return }
        let width = Self.width(for: item)
        let textTop = Self.artworkHeight + 8
        let isExplicit = self.isExplicit
        let badgeSize: CGFloat = 12
        let titleMaxWidth = width - (isExplicit ? badgeSize + 6 : 0)

        // Title: up to two lines, last line truncated, like the SwiftUI card.
        // Word-wrapping paragraph + `truncatesLastVisibleLine` gives the
        // ellipsis on line two; a tail-truncating paragraph would force one line.
        let wrapping = NSMutableParagraphStyle()
        wrapping.lineBreakMode = .byWordWrapping
        wrapping.alignment = self.isRightToLeft ? .right : .left
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = wrapping.alignment
        let title = NSAttributedString(string: item.title, attributes: [
            .font: Self.titleFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: wrapping,
        ])
        let titleLineHeight = ceil(Self.titleFont.ascender - Self.titleFont.descender + Self.titleFont.leading)
        let titleBounds = title.boundingRect(
            with: NSSize(width: titleMaxWidth, height: titleLineHeight * 2),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
        let titleRect = NSRect(
            x: self.isRightToLeft ? width - titleMaxWidth : 0,
            y: textTop, width: titleMaxWidth, height: min(ceil(titleBounds.height), titleLineHeight * 2)
        )
        title.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if isExplicit {
            let titleWidth = min(ceil(titleBounds.width), titleMaxWidth)
            let badgeX = self.isRightToLeft ? width - titleWidth - 6 - badgeSize : titleWidth + 6
            let badgeRect = NSRect(x: badgeX, y: textTop + (titleLineHeight - badgeSize) / 2, width: badgeSize, height: badgeSize)
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 2.5, yRadius: 2.5).fill()
            let badgeText = NSAttributedString(string: String(localized: "E"), attributes: [
                .font: Self.badgeFont,
                .foregroundColor: NSColor.windowBackgroundColor,
            ])
            let badgeTextSize = badgeText.size()
            badgeText.draw(at: NSPoint(
                x: badgeRect.midX - badgeTextSize.width / 2,
                y: badgeRect.midY - badgeTextSize.height / 2
            ))
        }

        if let subtitle = item.homeCardSubtitle, !subtitle.isEmpty {
            let subtitleString = NSAttributedString(string: subtitle, attributes: [
                .font: Self.subtitleFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
            let subtitleRect = NSRect(x: 0, y: titleRect.maxY + 4, width: width, height: ceil(Self.subtitleFont.ascender - Self.subtitleFont.descender) + 2)
            subtitleString.draw(with: subtitleRect, options: [.usesLineFragmentOrigin])
        }
    }
}

// MARK: - HomeItemArtworkLayers

/// Artwork layer stack: a lift layer (scale + shadow on hover) containing a
/// rounded, clipping content layer with the placeholder gradient, the
/// placeholder icon, and the decoded bitmap (aspect fill for square artwork,
/// aspect fit over a tinted backdrop for video).
@MainActor
private final class HomeItemArtworkLayers {
    /// Carries the hover lift. Its own layer because it needs a centered
    /// anchor point, which AppKit view layers don't have.
    let liftLayer = CALayer()
    private let contentLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let iconLayer = CALayer()
    private let imageLayer = CALayer()
    private var placeholderSymbolName: String?

    init() {
        self.liftLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        self.liftLayer.shadowColor = NSColor.black.cgColor
        self.liftLayer.shadowRadius = 12
        self.liftLayer.shadowOffset = CGSize(width: 0, height: 4)
        self.liftLayer.shadowOpacity = 0

        self.contentLayer.cornerRadius = HomeItemCell.cornerRadius
        self.contentLayer.masksToBounds = true
        self.gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        self.gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        self.iconLayer.contentsGravity = .center
        self.iconLayer.contentsScale = 2
        self.imageLayer.contentsGravity = .resizeAspectFill
        self.contentLayer.addSublayer(self.gradientLayer)
        self.contentLayer.addSublayer(self.iconLayer)
        self.contentLayer.addSublayer(self.imageLayer)
        self.liftLayer.addSublayer(self.contentLayer)
    }

    func layout(in frame: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: frame.size)
        self.liftLayer.bounds = bounds
        self.liftLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        self.contentLayer.frame = bounds
        self.gradientLayer.frame = bounds
        self.imageLayer.frame = bounds
        self.iconLayer.frame = bounds
        self.imageLayer.contentsScale = scale
        if self.iconLayer.contentsScale != scale {
            self.iconLayer.contentsScale = scale
            if let placeholderSymbolName {
                self.iconLayer.contents = Self.placeholderIcon(named: placeholderSymbolName, scale: scale)
            }
        }
        self.liftLayer.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: HomeItemCell.cornerRadius,
            cornerHeight: HomeItemCell.cornerRadius,
            transform: nil
        )
        CATransaction.commit()
    }

    func configure(item: HomeSectionItem) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.imageLayer.contents = nil
        self.imageLayer.isHidden = true
        self.gradientLayer.isHidden = false
        if item.isVideoSong {
            self.imageLayer.contentsGravity = .resizeAspect
            let backdrop = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
            self.gradientLayer.colors = [backdrop, backdrop]
        } else {
            self.imageLayer.contentsGravity = .resizeAspectFill
            self.gradientLayer.colors = Self.placeholderColors(for: item).map(\.cgColor)
        }
        let symbol = Self.placeholderSymbol(for: item)
        self.placeholderSymbolName = symbol
        self.iconLayer.contents = Self.placeholderIcon(named: symbol, scale: self.iconLayer.contentsScale)
        self.iconLayer.isHidden = false
        CATransaction.commit()
    }

    /// Re-resolves the appearance-dependent layer colors (video backdrop).
    func refreshAppearance(for item: HomeSectionItem) {
        guard item.isVideoSong else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let backdrop = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        self.gradientLayer.colors = [backdrop, backdrop]
        CATransaction.commit()
    }

    func setImage(_ image: NSImage, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.imageLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        self.imageLayer.isHidden = false
        self.iconLayer.isHidden = true
        // Aspect-fitted video artwork still needs its backdrop in the margins.
        self.gradientLayer.isHidden = self.imageLayer.contentsGravity != .resizeAspect
        CATransaction.commit()
        guard animated else { return }
        // Match the SwiftUI card's crossfade on a fresh load.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.25
        self.imageLayer.add(fade, forKey: "fadeIn")
    }

    /// Hover lift: scale the artwork and add a shadow, matching the SwiftUI
    /// card's `ThumbnailHoverLift`.
    func setLifted(_ lifted: Bool, animated: Bool) {
        let apply = {
            self.liftLayer.transform = lifted ? CATransform3DMakeScale(1.02, 1.02, 1) : CATransform3DIdentity
            self.liftLayer.shadowOpacity = lifted ? 0.15 : 0
        }
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        apply()
        CATransaction.commit()
    }

    // MARK: Placeholder

    private static func placeholderSymbol(for item: HomeSectionItem) -> String {
        switch item {
        case .song: item.isVideoSong ? "play.rectangle" : "music.note"
        case .album: "square.stack"
        case .playlist: "music.note.list"
        case .artist: "person.fill"
        }
    }

    /// Same scheme as `HomeSectionItemCard`: mood cards use the API color,
    /// everything else a title-derived hue pair.
    private static func placeholderColors(for item: HomeSectionItem) -> [NSColor] {
        if case let .playlist(playlist) = item,
           let colorHex = playlist.description,
           colorHex.hasPrefix("#"),
           let color = Color(hex: colorHex)
        {
            let base = NSColor(color)
            return [base, base.withAlphaComponent(0.7)]
        }
        let hash = abs(item.title.hashValue)
        let hue1 = CGFloat(hash % 360) / 360
        let hue2 = (hue1 + 0.1).truncatingRemainder(dividingBy: 1)
        return [
            NSColor(hue: hue1, saturation: 0.6, brightness: 0.5, alpha: 1),
            NSColor(hue: hue2, saturation: 0.7, brightness: 0.35, alpha: 1),
        ]
    }

    /// Tinted symbol bitmaps, rendered once per symbol and backing scale.
    private static var placeholderIcons: [String: CGImage] = [:]

    private static func placeholderIcon(named symbol: String, scale: CGFloat) -> CGImage? {
        let key = "\(symbol)-\(scale)"
        if let cached = self.placeholderIcons[key] {
            return cached
        }
        let config = NSImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        guard let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        let tinted = HomeItemLayerImage.render(size: icon.size, scale: scale) { rect in
            icon.draw(in: rect)
            NSColor.white.withAlphaComponent(0.8).set()
            rect.fill(using: .sourceAtop)
        }
        self.placeholderIcons[key] = tinted
        return tinted
    }
}

// MARK: - HomeItemLayerImage

@MainActor
private enum HomeItemLayerImage {
    /// Produces a bitmap with an explicit pixels-per-point ratio for CALayer.
    static func render(size: NSSize, scale: CGFloat, draw: (NSRect) -> Void) -> CGImage? {
        let bounds = NSRect(x: 0, y: 0, width: ceil(size.width), height: ceil(size.height))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        draw(bounds)
        return context.makeImage()
    }
}
