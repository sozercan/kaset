import AppKit
import SwiftUI

// MARK: - NavigationSwipeTracker

/// Recognizes the trackpad's two-finger "swipe between pages" gesture as a
/// request to go back, and reports how far along it is for the indicator.
///
/// Fed with scroll phases and deltas normalized so a positive `dx` means the
/// fingers moved right, whatever the natural scrolling setting.
struct NavigationSwipeTracker: Equatable {
    /// Horizontal finger travel, in points, that completes the swipe.
    static let completionDistance: CGFloat = 140

    /// Travel before the gesture's direction is decided, so a vertical scroll
    /// that starts with a little sideways motion isn't taken for a swipe.
    static let decisionSlop: CGFloat = 8

    enum Phase {
        case began
        case changed
        case ended
        case cancelled
    }

    enum Outcome: Equatable {
        /// Not a back swipe: the event belongs to the content.
        case passThrough
        /// A back swipe in progress: the event is consumed.
        case tracking(progress: CGFloat)
        /// The swipe ended past the completion distance: go back.
        case completed
        /// The swipe fell short or was abandoned.
        case cancelled
    }

    private enum State: Equatable {
        case idle
        case deciding(dx: CGFloat, dy: CGFloat)
        case tracking(offset: CGFloat)
        case rejected
    }

    private var state: State = .idle

    var isTracking: Bool {
        if case .tracking = self.state {
            return true
        }
        return false
    }

    /// Whether the current gesture's direction is still undecided, the only
    /// time `handle` reads `canGoBack` after `.began`.
    var isDeciding: Bool {
        if case .deciding = self.state {
            return true
        }
        return false
    }

    /// - Parameter canGoBack: whether this swipe may go back right now: there
    ///   is a page to return to and no horizontal scroller under the pointer
    ///   that still has room to scroll toward its leading edge.
    mutating func handle(_ phase: Phase, dx: CGFloat, dy: CGFloat, canGoBack: Bool) -> Outcome {
        switch phase {
        case .began:
            self.state = .deciding(dx: 0, dy: 0)
            return self.accumulate(dx: dx, dy: dy, canGoBack: canGoBack)
        case .changed:
            return self.accumulate(dx: dx, dy: dy, canGoBack: canGoBack)
        case .ended:
            defer { self.state = .idle }
            if case let .tracking(offset) = self.state {
                return offset >= Self.completionDistance ? .completed : .cancelled
            }
            return .passThrough
        case .cancelled:
            defer { self.state = .idle }
            return self.isTracking ? .cancelled : .passThrough
        }
    }

    static func progress(forOffset offset: CGFloat) -> CGFloat {
        min(max(offset / self.completionDistance, 0), 1)
    }

    /// Whether a scroll view can still scroll horizontally toward an edge.
    ///
    /// SwiftUI scrolls a full-width shelf under the sidebar by insetting its
    /// clip view, so the range starts at the inset leading edge rather than at
    /// the document's. A vertical page's insets are on the scroll view, not
    /// the clip view, so its range stays empty.
    static func hasHorizontalScrollRoom(
        visible: CGRect,
        document: CGRect,
        clipInsets: NSEdgeInsets,
        towardLeadingEdge: Bool
    ) -> Bool {
        let minOriginX = document.minX - clipInsets.left
        let maxOriginX = max(minOriginX, document.maxX + clipInsets.right - visible.width)
        guard maxOriginX - minOriginX > 1 else { return false }
        return towardLeadingEdge
            ? visible.minX > minOriginX + 1
            : visible.minX < maxOriginX - 1
    }

    private mutating func accumulate(dx: CGFloat, dy: CGFloat, canGoBack: Bool) -> Outcome {
        switch self.state {
        case .idle, .rejected:
            return .passThrough
        case let .deciding(totalX, totalY):
            let x = totalX + dx
            let y = totalY + dy
            guard abs(x) + abs(y) >= Self.decisionSlop else {
                self.state = .deciding(dx: x, dy: y)
                return .passThrough
            }
            // Mostly rightward: a diagonal or vertical scroll stays a scroll.
            guard canGoBack, x > 0, x > abs(y) * 2 else {
                self.state = .rejected
                return .passThrough
            }
            self.state = .tracking(offset: x)
            return .tracking(progress: Self.progress(forOffset: x))
        case let .tracking(offset):
            let newOffset = max(offset + dx, 0)
            self.state = .tracking(offset: newOffset)
            return .tracking(progress: Self.progress(forOffset: newOffset))
        }
    }
}

// MARK: - NavigationSwipeBackAction

/// Goes back one level in the enclosing navigation stack. Provided by
/// `navigationSwipeBack(path:)` on the stack to its root content, where the
/// destination builders hand it to each pushed page.
struct NavigationSwipeBackAction: @unchecked Sendable {
    let canGoBack: @MainActor () -> Bool
    let goBack: @MainActor () -> Void
}

extension EnvironmentValues {
    @Entry var navigationSwipeBackAction: NavigationSwipeBackAction?
}

// MARK: - View Modifiers

extension View {
    /// Lets pages pushed onto this stack go back with a trackpad swipe to the
    /// right, the way browsers do.
    ///
    /// Apply to each `NavigationStack` that has a path. The destination
    /// builders pass the action on to each pushed page, whose
    /// `navigationSwipeBackTarget(_:)` does the tracking. The stack itself
    /// can't carry the target: SwiftUI detaches a covered page's views from
    /// the window, so only the page on top is reachable.
    func navigationSwipeBack(path: Binding<NavigationPath>) -> some View {
        self.environment(
            \.navigationSwipeBackAction,
            NavigationSwipeBackAction(
                canGoBack: { !path.wrappedValue.isEmpty },
                goBack: {
                    guard !path.wrappedValue.isEmpty else { return }
                    path.wrappedValue.removeLast()
                }
            )
        )
    }

    /// Tracks the trackpad swipe back on a pushed page and shows its indicator.
    /// Applied by the navigation destination builders to every pushed page,
    /// and passed on to destinations the page declares itself.
    /// Follows the "Swipe between pages" gesture in System Settings → Trackpad
    /// (two fingers, or three) and Settings → General → Swipe to Go Back.
    ///
    /// - Parameter action: the stack's action, read from the environment where
    ///   the destination is declared. A pushed page doesn't inherit it: inside a
    ///   `NavigationSplitView`, pushed pages take the split view's environment,
    ///   not the stack's.
    func navigationSwipeBackTarget(_ action: NavigationSwipeBackAction?) -> some View {
        self.modifier(NavigationSwipeBackTargetModifier(action: action))
    }

    /// `navigationDestination(for:destination:)` whose pages go back with the
    /// trackpad swipe. Use it for destinations a view declares itself, outside
    /// the shared destination builders. Like them, it reads the stack's action
    /// where it is declared and hands it to each pushed page.
    func swipeBackNavigationDestination<D: Hashable>(
        for _: D.Type,
        @ViewBuilder destination: @escaping (D) -> some View
    ) -> some View {
        self.modifier(SwipeBackNavigationDestinationModifier(destination: destination))
    }
}

// MARK: - SwipeBackNavigationDestinationModifier

private struct SwipeBackNavigationDestinationModifier<D: Hashable, Destination: View>: ViewModifier {
    let destination: (D) -> Destination

    @Environment(\.navigationSwipeBackAction) private var swipeBackAction

    func body(content: Content) -> some View {
        content.navigationDestination(for: D.self) { value in
            self.destination(value)
                .navigationSwipeBackTarget(self.swipeBackAction)
        }
    }
}

// MARK: - NavigationSwipeBackTargetModifier

private struct NavigationSwipeBackTargetModifier: ViewModifier {
    let action: NavigationSwipeBackAction?

    @State private var settings = SettingsManager.shared
    @State private var progress: CGFloat?

    func body(content: Content) -> some View {
        content
            // Destinations the page declares itself read the action from here.
            .environment(\.navigationSwipeBackAction, self.action)
            .background {
                if let action = self.action, self.settings.swipeToGoBackEnabled {
                    NavigationSwipeTarget(
                        canGoBack: action.canGoBack,
                        onProgress: { self.progress = $0 },
                        onGoBack: action.goBack
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .overlay {
                ZStack(alignment: .leading) {
                    if let progress = self.progress {
                        NavigationSwipeIndicator(progress: progress)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                // The gesture is a rightward swipe in every language, so the
                // indicator enters from the left edge in right-to-left ones too.
                .environment(\.layoutDirection, .leftToRight)
                .animation(AppAnimation.quick, value: self.progress == nil)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: self.settings.swipeToGoBackEnabled) { _, isEnabled in
                if !isEnabled {
                    self.progress = nil
                }
            }
    }
}

// MARK: - NavigationSwipeIndicator

/// A chevron that slides in from the leading edge as the swipe progresses and
/// fills once letting go would go back.
private struct NavigationSwipeIndicator: View {
    let progress: CGFloat

    private static let diameter: CGFloat = 40
    private static let travel: CGFloat = 56

    private var isArmed: Bool {
        self.progress >= 1
    }

    var body: some View {
        Image(systemName: "chevron.backward")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(self.isArmed ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: Self.diameter, height: Self.diameter)
            .compatGlass(tint: self.isArmed ? .accentColor : nil, in: .circle)
            .scaleEffect(self.isArmed ? 1.08 : 0.9)
            .opacity(min(1, 0.25 + self.progress))
            .offset(x: -Self.diameter + self.progress * Self.travel)
            .animation(AppAnimation.quick, value: self.isArmed)
            .onChange(of: self.isArmed) { _, isArmed in
                if isArmed {
                    HapticService.navigation()
                }
            }
    }
}

// MARK: - NavigationSwipeTarget

/// Registers its page with ``NavigationSwipeMonitor``.
private struct NavigationSwipeTarget: NSViewRepresentable {
    let canGoBack: @MainActor () -> Bool
    let onProgress: @MainActor (CGFloat?) -> Void
    let onGoBack: @MainActor () -> Void

    func makeNSView(context _: Context) -> NavigationSwipeTargetView {
        let view = NavigationSwipeTargetView(frame: .zero)
        self.update(view)
        NavigationSwipeMonitor.shared.register(view)
        return view
    }

    func updateNSView(_ view: NavigationSwipeTargetView, context _: Context) {
        self.update(view)
    }

    static func dismantleNSView(_ view: NavigationSwipeTargetView, coordinator _: ()) {
        view.onProgress?(nil)
        NavigationSwipeMonitor.shared.unregister(view)
    }

    private func update(_ view: NavigationSwipeTargetView) {
        view.canGoBack = self.canGoBack
        view.onProgress = self.onProgress
        view.onGoBack = self.onGoBack
    }
}

// MARK: - NavigationSwipeTargetView

@MainActor
final class NavigationSwipeTargetView: NSView {
    var canGoBack: (@MainActor () -> Bool)?
    var onProgress: (@MainActor (CGFloat?) -> Void)?
    var onGoBack: (@MainActor () -> Void)?

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    /// Whether the event's pointer location is over this page in its window.
    /// Pages covered by a later one are detached from the window, so only the
    /// page on top matches.
    func contains(_ event: NSEvent) -> Bool {
        guard let window = self.window,
              event.window === window,
              !self.isHiddenOrHasHiddenAncestor
        else {
            return false
        }
        return self.bounds.contains(self.convert(event.locationInWindow, from: nil))
    }
}

// MARK: - NavigationSwipeMonitor

/// One app-wide event monitor that routes each trackpad swipe to the
/// innermost pushed page under the pointer.
@MainActor
final class NavigationSwipeMonitor {
    static let shared = NavigationSwipeMonitor()

    private var targets: [WeakTarget] = []
    private var monitor: Any?
    private var tracker = NavigationSwipeTracker()
    private weak var activeTarget: NavigationSwipeTargetView?
    /// After a tracked swipe, its momentum scroll would move the page.
    private var swallowsMomentum = false
    /// When a tracked swipe last went back.
    private var lastTrackedBack: ContinuousClock.Instant?

    private struct WeakTarget {
        weak var view: NavigationSwipeTargetView?
    }

    func register(_ view: NavigationSwipeTargetView) {
        self.targets.removeAll { $0.view == nil || $0.view === view }
        self.targets.append(WeakTarget(view: view))
        self.installIfNeeded()
    }

    /// The monitor stays installed after the last page goes: going back to a
    /// root page unregisters the page that tracked the swipe, and the swipe's
    /// momentum, which arrives after that, must still be swallowed. With no
    /// pages registered it returns each event untouched.
    func unregister(_ view: NavigationSwipeTargetView) {
        self.targets.removeAll { $0.view == nil || $0.view === view }
        if self.activeTarget === view {
            self.activeTarget = nil
            self.tracker = NavigationSwipeTracker()
        }
    }

    private func installIfNeeded() {
        guard self.monitor == nil else { return }
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Returns whether the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .swipe:
            self.handleThreeFingerSwipe(event)
        case .scrollWheel:
            self.handleScroll(event)
        default:
            false
        }
    }

    /// A three-finger page swipe ("Swipe with three fingers" or "with two or
    /// three fingers" in System Settings) arrives as one discrete event; a
    /// positive `deltaX` means back, as in WebKit. One that lands while a
    /// tracked swipe runs or right after it went back is the same gesture.
    private func handleThreeFingerSwipe(_ event: NSEvent) -> Bool {
        let followsTrackedSwipe = self.lastTrackedBack.map { ContinuousClock.now - $0 < .seconds(1) } ?? false
        guard event.deltaX > 0,
              !self.tracker.isTracking,
              !followsTrackedSwipe,
              let target = self.target(for: event, needsBack: true)
        else {
            return false
        }
        target.onGoBack?()
        return true
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        if event.momentumPhase != [] {
            let swallows = self.swallowsMomentum
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                self.swallowsMomentum = false
            }
            return swallows
        }
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              event.hasPreciseScrollingDeltas,
              let phase = Self.phase(of: event)
        else {
            return false
        }

        if phase == .began {
            self.swallowsMomentum = false
            self.activeTarget = self.target(for: event, needsBack: true)
        }
        guard let target = self.activeTarget else { return false }

        // Fingers moving right read as a positive delta with natural scrolling
        // on, and as a negative one with it off.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        // Only read while the direction is undecided; skipping it otherwise
        // keeps the view-tree search out of ordinary scrolling.
        let needsDecision = phase == .began || self.tracker.isDeciding
        let canGoBack = needsDecision
            && (target.canGoBack?() ?? false)
            && !Self.scrollRoomExists(under: event)
        let outcome = self.tracker.handle(
            phase,
            dx: event.scrollingDeltaX * sign,
            dy: event.scrollingDeltaY,
            canGoBack: canGoBack
        )

        switch outcome {
        case .passThrough:
            return false
        case let .tracking(progress):
            target.onProgress?(progress)
            return true
        case .completed:
            target.onProgress?(nil)
            target.onGoBack?()
            self.lastTrackedBack = .now
            self.swallowsMomentum = true
            self.activeTarget = nil
            return true
        case .cancelled:
            target.onProgress?(nil)
            self.swallowsMomentum = true
            self.activeTarget = nil
            return true
        }
    }

    /// The innermost registered page under the pointer, or with `needsBack`
    /// the innermost one there that can go back.
    private func target(for event: NSEvent, needsBack: Bool) -> NavigationSwipeTargetView? {
        self.targets
            .compactMap(\.view)
            .filter { $0.contains(event) && (!needsBack || ($0.canGoBack?() ?? false)) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    private static func phase(of event: NSEvent) -> NavigationSwipeTracker.Phase? {
        if event.phase.contains(.began) {
            return .began
        }
        if event.phase.contains(.changed) {
            return .changed
        }
        if event.phase.contains(.ended) {
            return .ended
        }
        if event.phase.contains(.cancelled) {
            return .cancelled
        }
        return nil
    }

    /// Whether a horizontal scroller under the pointer (a shelf, a carousel)
    /// can still scroll the way a back swipe moves it. Like a browser page,
    /// it keeps the swipe until it reaches that edge. The tracker only takes
    /// rightward finger motion, which moves content toward its leading edge
    /// with natural scrolling and toward its trailing one without, so the
    /// direction comes from that setting rather than this event's delta,
    /// which can be zero on the event that settles the direction.
    private static func scrollRoomExists(under event: NSEvent) -> Bool {
        guard let contentView = event.window?.contentView else { return false }
        return Self.scrollRoomExists(
            in: contentView,
            at: event.locationInWindow,
            towardLeadingEdge: event.isDirectionInvertedFromDevice
        )
    }

    /// Searches the view tree rather than following `hitTest(_:)`: SwiftUI's
    /// hit testing lands in the page's vertical scroll view and skips the
    /// nested horizontal ones.
    private static func scrollRoomExists(
        in view: NSView,
        at pointInWindow: NSPoint,
        towardLeadingEdge: Bool
    ) -> Bool {
        guard !view.isHidden, view.convert(view.bounds, to: nil).contains(pointInWindow) else {
            return false
        }
        if let scrollView = view as? NSScrollView,
           let documentView = scrollView.documentView,
           NavigationSwipeTracker.hasHorizontalScrollRoom(
               visible: scrollView.contentView.bounds,
               document: documentView.frame,
               clipInsets: scrollView.contentView.contentInsets,
               towardLeadingEdge: towardLeadingEdge
           )
        {
            return true
        }
        return view.subviews.contains {
            Self.scrollRoomExists(in: $0, at: pointInWindow, towardLeadingEdge: towardLeadingEdge)
        }
    }
}
