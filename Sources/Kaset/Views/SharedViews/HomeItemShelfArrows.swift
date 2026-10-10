import AppKit

// MARK: - HomeItemShelfContainerView

/// Hosts the shelf's scroll view and its two paging arrows.
///
/// The arrows are native glass (`NSGlassEffectView`) rather than SwiftUI
/// `.glassEffect()`: SwiftUI re-resolves every glass element's context on each
/// frame it moves, and with an arrow on every visible shelf that was most of the
/// remaining cost of scrolling the page. Core Animation composites the native
/// glass without main-thread work. Arrows sit on physical sides; the shelf maps
/// them to leading/trailing for paging and right-to-left layouts.
@MainActor
final class HomeItemShelfContainerView: NSView {
    enum Side {
        case left
        case right
    }

    static let arrowSize: CGFloat = 38

    /// Called with the physical side of the arrow that was pressed.
    var pageHandler: ((Side) -> Void)?

    private weak var scrollView: NSScrollView?
    private var contentInset: CGFloat = 0
    private let leftArrow = HomeItemShelfArrowView(side: .left)
    private let rightArrow = HomeItemShelfArrowView(side: .right)
    private var isHovering = false

    override var isFlipped: Bool {
        true
    }

    func install(scrollView: NSScrollView, contentInset: CGFloat) {
        self.scrollView = scrollView
        self.contentInset = contentInset
        self.addSubview(scrollView)
        for arrow in [self.leftArrow, self.rightArrow] {
            arrow.pressHandler = { [weak self] side in self?.pageHandler?(side) }
            arrow.focusHandler = { [weak self] in self?.updateProminence() }
            self.addSubview(arrow)
        }
    }

    /// Shelf label used in the arrows' accessibility labels, and whether to use
    /// the macOS 15 material instead of glass.
    func configure(shelfLabel: String, usesLegacyMaterial: Bool) {
        for arrow in [self.leftArrow, self.rightArrow] {
            arrow.configure(shelfLabel: shelfLabel, usesLegacyMaterial: usesLegacyMaterial)
        }
    }

    /// Shows or hides each arrow; `animated` fades and scales them like the
    /// SwiftUI transition they replace.
    func setArrows(left: Bool, right: Bool, animated: Bool) {
        self.leftArrow.setVisible(left, animated: animated)
        self.rightArrow.setVisible(right, animated: animated)
    }

    /// Physical arrow, for tests.
    func arrow(_ side: Side) -> HomeItemShelfArrowView {
        side == .left ? self.leftArrow : self.rightArrow
    }

    func isShowingArrow(_ side: Side) -> Bool {
        switch side {
        case .left: self.leftArrow.isVisible
        case .right: self.rightArrow.isVisible
        }
    }

    /// Pointer over the shelf raises both arrows to full prominence.
    func setHovering(_ hovering: Bool) {
        guard hovering != self.isHovering else { return }
        self.isHovering = hovering
        self.updateProminence()
    }

    /// Hovering the shelf or focusing either arrow raises both, like the
    /// SwiftUI controls.
    private func updateProminence() {
        let prominent = self.isHovering || self.leftArrow.isFocused || self.rightArrow.isFocused
        self.leftArrow.setShelfProminent(prominent)
        self.rightArrow.setShelfProminent(prominent)
    }

    /// A trackpad swipe that starts on an arrow still scrolls the shelf (or,
    /// for vertical gestures, the page via the document view's routing).
    override func scrollWheel(with event: NSEvent) {
        if let documentView = self.scrollView?.documentView {
            documentView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func layout() {
        super.layout()
        self.scrollView?.frame = self.bounds
        let size = Self.arrowSize
        let y = (self.bounds.height - size) / 2
        // Sit at the resting inset (not the column edge) so the arrows clear the
        // floating-sidebar band, mirroring the SwiftUI controls.
        self.leftArrow.frame = NSRect(x: self.contentInset + 4, y: y, width: size, height: size)
        self.rightArrow.frame = NSRect(x: self.bounds.width - self.contentInset - 4 - size, y: y, width: size, height: size)
    }
}

// MARK: - HomeItemShelfArrowView

/// One paging arrow: a glass circle with a chevron. Handles its own clicks,
/// Return/Space under Full Keyboard Access, focus ring and accessibility, so
/// the glass and chevron subviews stay passive.
@MainActor
final class HomeItemShelfArrowView: NSView {
    var pressHandler: ((HomeItemShelfContainerView.Side) -> Void)?
    /// Called when this arrow gains or loses keyboard focus.
    var focusHandler: (() -> Void)?
    private(set) var isVisible = false
    private(set) var isFocused = false

    private let side: HomeItemShelfContainerView.Side
    private let chevron = NSImageView()
    private var background: NSView?
    private var usesLegacyMaterial: Bool?
    private var isShelfProminent = false
    private var isPressed = false

    init(side: HomeItemShelfContainerView.Side) {
        self.side = side
        super.init(frame: .zero)
        self.wantsLayer = true
        self.isHidden = true
        self.alphaValue = 0
        self.focusRingType = .exterior
        self.layer?.shadowColor = NSColor.black.cgColor
        self.applyProminence()

        let symbol = side == .left ? "chevron.left" : "chevron.right"
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        self.chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        self.chevron.contentTintColor = .labelColor
        self.chevron.imageScaling = .scaleNone

        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.button)
        self.setAccessibilityHelp(String(localized: "Scrolls this shelf by one page"))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func configure(shelfLabel: String, usesLegacyMaterial: Bool) {
        self.setAccessibilityLabel(self.side == .left
            ? String(localized: "Scroll \(shelfLabel) left")
            : String(localized: "Scroll \(shelfLabel) right"))
        guard usesLegacyMaterial != self.usesLegacyMaterial else { return }
        self.usesLegacyMaterial = usesLegacyMaterial
        self.background?.removeFromSuperview()
        let radius = HomeItemShelfContainerView.arrowSize / 2
        let background: NSView
        if !usesLegacyMaterial, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = self.chevron
            background = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .withinWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = radius
            material.layer?.masksToBounds = true
            material.addSubview(self.chevron)
            background = material
        }
        background.frame = self.bounds
        background.autoresizingMask = [.width, .height]
        self.chevron.frame = background.bounds
        self.chevron.autoresizingMask = [.width, .height]
        self.addSubview(background)
        self.background = background
    }

    // MARK: Visibility and prominence

    func setVisible(_ visible: Bool, animated: Bool) {
        guard visible != self.isVisible else { return }
        self.isVisible = visible
        if visible {
            self.isHidden = false
        }
        let alpha = self.targetAlpha
        guard animated else {
            self.applyProminence()
            self.alphaValue = alpha
            self.setScale(1)
            self.isHidden = !visible
            return
        }
        if visible {
            self.setScale(0.9)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = alpha
            self.applyProminence()
            self.setScale(visible ? self.restingScale : 0.9)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                // Hidden arrows leave hit testing and the key view loop.
                self.isHidden = true
            }
        }
    }

    func setShelfProminent(_ prominent: Bool) {
        guard prominent != self.isShelfProminent else { return }
        self.isShelfProminent = prominent
        self.animateProminence()
    }

    private var hasProminence: Bool {
        self.isShelfProminent || self.isFocused
    }

    private var targetAlpha: CGFloat {
        guard self.isVisible else { return 0 }
        return self.hasProminence ? 1 : 0.72
    }

    private var restingScale: CGFloat {
        self.isFocused ? 1.04 : 1
    }

    private func animateProminence() {
        guard self.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = self.targetAlpha
            self.applyProminence()
            self.setScale(self.restingScale)
        }
    }

    /// Shadow under the glass, matching the SwiftUI arrow's resting and
    /// prominent shadows.
    private func applyProminence() {
        guard let layer else { return }
        let prominent = self.hasProminence
        layer.shadowOpacity = prominent ? 0.18 : 0.10
        layer.shadowRadius = prominent ? 10 : 8
        // Layer y points up in this unflipped view, so a downward shadow is negative.
        layer.shadowOffset = CGSize(width: 0, height: prominent ? -4 : -3)
    }

    /// Scales around the center; AppKit pins view layers' anchor at the origin.
    private func setScale(_ scale: CGFloat) {
        let center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
        self.layer?.transform = transform
    }

    override func layout() {
        super.layout()
        let radius = self.bounds.width / 2
        self.layer?.shadowPath = CGPath(ellipseIn: self.bounds, transform: nil)
        self.layer?.cornerRadius = radius
        self.setScale(self.isVisible ? self.restingScale : 0.9)
    }

    // MARK: Input

    /// The glass and chevron are decoration; the arrow itself takes every event.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates. Only the circle is the
        // button, so a click in the frame's corners reaches the card beneath.
        guard !self.isHidden, NSBezierPath(ovalIn: self.frame).contains(point) else { return nil }
        return self
    }

    override func mouseDown(with _: NSEvent) {
        self.isPressed = true
        self.background?.alphaValue = 0.75
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
        self.background?.alphaValue = inside ? 0.75 : 1
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            self.isPressed = false
            self.background?.alphaValue = 1
        }
        guard self.isPressed, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return }
        self.press()
    }

    private func press() {
        self.pressHandler?(self.side)
    }

    override func accessibilityPerformPress() -> Bool {
        self.press()
        return true
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool {
        NSApp.isFullKeyboardAccessEnabled && self.isVisible
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        self.isFocused = true
        self.animateProminence()
        self.focusHandler?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        self.isFocused = false
        self.animateProminence()
        self.focusHandler?()
        return true
    }

    override var focusRingMaskBounds: NSRect {
        self.bounds
    }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: self.bounds).fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard self.window?.firstResponder === self, event.keyCode == 49,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
        else { return super.performKeyEquivalent(with: event) }
        // Focused controls handle Space before the app's Play/Pause shortcut.
        self.press()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49: // Return, Enter, Space
            self.press()
        default:
            super.keyDown(with: event)
        }
    }
}
