import AppKit
import SwiftUI

// MARK: - Player Bar Volume Overlay Host

extension View {
    /// Presents the volume capsule in a borderless child panel so it remains
    /// interactive outside the player bar's compact safe-area inset.
    func playerBarVolumeOverlay(
        isPresented: Binding<Bool>,
        @ViewBuilder overlay: @escaping () -> some View
    ) -> some View {
        self.modifier(
            PlayerBarVolumeOverlayModifier(
                isPresented: isPresented,
                overlay: overlay
            )
        )
    }
}

// MARK: - PlayerBarVolumeOverlayModifier

private struct PlayerBarVolumeOverlayModifier<Overlay: View>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.usesLegacyMacOS15UI) private var usesLegacyMacOS15UI

    @Binding var isPresented: Bool
    @ViewBuilder let overlay: () -> Overlay

    func body(content: Content) -> some View {
        content.background {
            PlayerBarVolumeOverlayAnchor(
                isPresented: self.$isPresented,
                overlay: AnyView(
                    self.overlay()
                        .environment(\.colorScheme, self.colorScheme)
                        .environment(\.usesLegacyMacOS15UI, self.usesLegacyMacOS15UI)
                )
            )
            .allowsHitTesting(false)
        }
    }
}

// MARK: - PlayerBarVolumeOverlayAnchor

private struct PlayerBarVolumeOverlayAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let overlay: AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlayerBarVolumeOverlayAnchorView {
        let anchorView = PlayerBarVolumeOverlayAnchorView()
        anchorView.setAccessibilityElement(false)
        anchorView.onGeometryChange = { [weak coordinator = context.coordinator] anchorView in
            coordinator?.positionOverlay(relativeTo: anchorView)
        }
        return anchorView
    }

    func updateNSView(_ anchorView: PlayerBarVolumeOverlayAnchorView, context: Context) {
        context.coordinator.update(
            anchorView: anchorView,
            isPresented: self.isPresented,
            overlay: self.overlay,
            onDismiss: {
                self.isPresented = false
            }
        )
    }

    static func dismantleNSView(
        _ anchorView: PlayerBarVolumeOverlayAnchorView,
        coordinator: Coordinator
    ) {
        anchorView.onGeometryChange = nil
        coordinator.removeOverlay()
    }

    @MainActor
    final class Coordinator {
        private var isPresented = false
        private var panel: NSPanel?
        private var hostingView: PlayerBarVolumeOverlayHostingView?
        private weak var anchorView: PlayerBarVolumeOverlayAnchorView?
        private var mouseDownMonitor: Any?
        private var onDismiss: (() -> Void)?

        func update(
            anchorView: PlayerBarVolumeOverlayAnchorView,
            isPresented: Bool,
            overlay: AnyView,
            onDismiss: @escaping () -> Void
        ) {
            self.anchorView = anchorView
            self.onDismiss = onDismiss
            self.isPresented = isPresented
            guard isPresented else {
                self.hideOverlay()
                return
            }

            let panel = self.overlayPanel(overlay: overlay)
            self.hostingView?.rootView = PlayerBarVolumeOverlayRoot(overlay: overlay)
            self.positionOverlay(relativeTo: anchorView)
            guard self.isPresented, panel.parent != nil else { return }
            panel.orderFront(nil)
            self.startMonitoringMouseDown()
        }

        func positionOverlay(relativeTo anchorView: PlayerBarVolumeOverlayAnchorView) {
            guard self.isPresented,
                  let panel = self.panel
            else { return }
            guard let parentWindow = anchorView.window else {
                self.dismissOverlay()
                return
            }

            let anchorTop = NSPoint(
                x: anchorView.bounds.midX,
                y: anchorView.isFlipped ? anchorView.bounds.minY : anchorView.bounds.maxY
            )
            let anchorTopInWindow = anchorView.convert(anchorTop, to: nil)
            let anchorTopOnScreen = parentWindow.convertPoint(toScreen: anchorTopInWindow)

            if panel.parent !== parentWindow {
                panel.parent?.removeChildWindow(panel)
                parentWindow.addChildWindow(panel, ordered: .above)
            }

            panel.setFrame(
                PlayerBarVolumeOverlayMetrics.hostFrame(anchorTopCenter: anchorTopOnScreen),
                display: true
            )
        }

        func removeOverlay() {
            self.isPresented = false
            self.hideOverlay()
            self.panel?.contentView = nil
            self.panel?.close()
            self.panel = nil
            self.hostingView = nil
            self.anchorView = nil
            self.onDismiss = nil
        }

        private func overlayPanel(overlay: AnyView) -> NSPanel {
            if let panel = self.panel {
                return panel
            }

            let rootView = PlayerBarVolumeOverlayRoot(overlay: overlay)
            let hostingView = PlayerBarVolumeOverlayHostingView(rootView: rootView)
            hostingView.frame = NSRect(origin: .zero, size: PlayerBarVolumeOverlayMetrics.hostSize)
            hostingView.autoresizingMask = [.width, .height]

            let panel = NSPanel(
                contentRect: hostingView.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = hostingView
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.isMovable = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.animationBehavior = .none
            panel.collectionBehavior = [.fullScreenAuxiliary, .transient]

            self.hostingView = hostingView
            self.panel = panel
            return panel
        }

        private func hideOverlay() {
            self.stopMonitoringMouseDown()
            guard let panel = self.panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        private func dismissOverlay() {
            guard self.isPresented else { return }
            self.isPresented = false
            self.hideOverlay()
            self.onDismiss?()
        }

        private func startMonitoringMouseDown() {
            guard self.mouseDownMonitor == nil else { return }
            self.mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.dismissOverlayIfNeeded(for: event)
                }
                return event
            }
        }

        private func stopMonitoringMouseDown() {
            guard let mouseDownMonitor = self.mouseDownMonitor else { return }
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }

        private func dismissOverlayIfNeeded(for event: NSEvent) {
            guard let panel = self.panel else { return }
            let locationOnScreen = event.window?.convertPoint(
                toScreen: event.locationInWindow
            ) ?? NSEvent.mouseLocation
            if panel.frame.contains(locationOnScreen) {
                return
            }
            if let anchorView = self.anchorView,
               let anchorWindow = anchorView.window
            {
                let locationInWindow = anchorWindow.convertPoint(fromScreen: locationOnScreen)
                let locationInAnchor = anchorView.convert(locationInWindow, from: nil)
                if anchorView.bounds.contains(locationInAnchor) {
                    return
                }
            }
            self.dismissOverlay()
        }
    }
}

// MARK: - PlayerBarVolumeOverlayRoot

private struct PlayerBarVolumeOverlayRoot: View {
    let overlay: AnyView

    var body: some View {
        self.overlay
            .padding(.horizontal, PlayerBarVolumeOverlayMetrics.horizontalOutset)
            .padding(.top, PlayerBarVolumeOverlayMetrics.topOutset)
            .padding(.bottom, PlayerBarVolumeOverlayMetrics.bottomOutset)
            .frame(
                width: PlayerBarVolumeOverlayMetrics.hostSize.width,
                height: PlayerBarVolumeOverlayMetrics.hostSize.height
            )
    }
}

// MARK: - PlayerBarVolumeOverlayHostingView

@MainActor
private final class PlayerBarVolumeOverlayHostingView: NSHostingView<PlayerBarVolumeOverlayRoot> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

// MARK: - PlayerBarVolumeOverlayAnchorView

@MainActor
private final class PlayerBarVolumeOverlayAnchorView: NSView {
    var onGeometryChange: ((PlayerBarVolumeOverlayAnchorView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        self.onGeometryChange?(self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        self.onGeometryChange?(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.onGeometryChange?(self)
    }

    @objc private func frameDidChange(_: Notification) {
        self.onGeometryChange?(self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - PlayerBarVolumeOverlayMetrics

private enum PlayerBarVolumeOverlayMetrics {
    static let contentSize = CGSize(width: 46, height: 168)
    static let horizontalOutset: CGFloat = 22
    static let topOutset: CGFloat = 22
    static let bottomOutset: CGFloat = 8
    static let hostSize = CGSize(
        width: Self.contentSize.width + Self.horizontalOutset * 2,
        height: Self.contentSize.height + Self.topOutset + Self.bottomOutset
    )

    static func hostFrame(anchorTopCenter: NSPoint) -> NSRect {
        NSRect(
            origin: NSPoint(
                x: anchorTopCenter.x - self.hostSize.width / 2,
                y: anchorTopCenter.y
            ),
            size: self.hostSize
        )
    }
}
