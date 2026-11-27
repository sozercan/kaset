import AppKit

@MainActor
final class HomeItemShelfContainerView: NSView {
    enum Side {
        case left
        case right
    }

    static let arrowSize: CGFloat = 38

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

    func configure(shelfLabel: String, usesLegacyMaterial: Bool) {
        for arrow in [self.leftArrow, self.rightArrow] {
            arrow.configure(shelfLabel: shelfLabel, usesLegacyMaterial: usesLegacyMaterial)
        }
    }

    func setArrows(left: Bool, right: Bool, animated: Bool) {
        self.leftArrow.setVisible(left, animated: animated)
        self.rightArrow.setVisible(right, animated: animated)
        if self.leftArrow.isFocused, !left, right {
            self.window?.makeFirstResponder(self.rightArrow)
        } else if self.rightArrow.isFocused, !right, left {
            self.window?.makeFirstResponder(self.leftArrow)
        }
    }

    func arrow(_ side: Side) -> HomeItemShelfArrowView {
        side == .left ? self.leftArrow : self.rightArrow
    }

    func isShowingArrow(_ side: Side) -> Bool {
        switch side {
        case .left: self.leftArrow.isVisible
        case .right: self.rightArrow.isVisible
        }
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != self.isHovering else { return }
        self.isHovering = hovering
        self.updateProminence()
    }

    private func updateProminence() {
        let prominent = self.isHovering || self.leftArrow.isFocused || self.rightArrow.isFocused
        self.leftArrow.setShelfProminent(prominent)
        self.rightArrow.setShelfProminent(prominent)
    }

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
        self.leftArrow.frame = NSRect(x: self.contentInset + 4, y: y, width: size, height: size)
        self.rightArrow.frame = NSRect(x: self.bounds.width - self.contentInset - 4 - size, y: y, width: size, height: size)
    }
}

@MainActor
final class HomeItemShelfArrowView: NSView {
    var pressHandler: ((HomeItemShelfContainerView.Side) -> Void)?
    var focusHandler: (() -> Void)?
    private(set) var isVisible = false
    private(set) var isFocused = false

    private let side: HomeItemShelfContainerView.Side
    private let chevron = NSImageView()
    private var background: NSView?
    private var shelfLabel: String?
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
        self.setAccessibilityHelp(CarouselShelfPagingControls.accessibilityHint)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func configure(shelfLabel: String, usesLegacyMaterial: Bool) {
        if shelfLabel != self.shelfLabel {
            self.shelfLabel = shelfLabel
            self.setAccessibilityLabel(CarouselShelfPagingControls.accessibilityLabel(shelf: shelfLabel, isLeft: self.side == .left))
        }
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

    private func applyProminence() {
        guard let layer else { return }
        let prominent = self.hasProminence
        layer.shadowOpacity = prominent ? 0.18 : 0.10
        layer.shadowRadius = prominent ? 10 : 8
        layer.shadowOffset = CGSize(width: 0, height: prominent ? -4 : -3)
    }

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard self.isVisible, self.circleContains(self.convert(point, from: self.superview)) else { return nil }
        return self
    }

    private func circleContains(_ point: NSPoint) -> Bool {
        let radius = self.bounds.width / 2
        let dx = point.x - self.bounds.midX
        let dy = point.y - self.bounds.midY
        return dx * dx + dy * dy <= radius * radius
    }

    override func mouseDown(with _: NSEvent) {
        self.isPressed = true
        self.background?.alphaValue = 0.75
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = self.circleContains(self.convert(event.locationInWindow, from: nil))
        self.background?.alphaValue = inside ? 0.75 : 1
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            self.isPressed = false
            self.background?.alphaValue = 1
        }
        guard self.isPressed, self.circleContains(self.convert(event.locationInWindow, from: nil)) else { return }
        self.press()
    }

    private func press() {
        self.pressHandler?(self.side)
    }

    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityPerformPress() -> Bool {
        guard self.isVisible else { return false }
        self.press()
        return true
    }

    override var acceptsFirstResponder: Bool {
        NSApp.isFullKeyboardAccessEnabled && self.isVisible && NSApp.currentEvent?.type != .leftMouseDown
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        self.isFocused = true
        self.animateProminence()
        self.focusHandler?()
        self.scrollToVisible(self.bounds)
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
        self.press()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49:
            self.press()
        default:
            super.keyDown(with: event)
        }
    }
}
