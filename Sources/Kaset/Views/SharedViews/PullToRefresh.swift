import SwiftUI

// MARK: - PullToRefreshState

struct PullToRefreshState: Equatable {
    enum Phase: Equatable {
        case idle
        case pulling
        case armed
        case refreshing
        case settling
    }

    static let threshold: CGFloat = 64

    static let disarmThreshold: CGFloat = 48

    private static let restTolerance: CGFloat = 0.5

    private(set) var pullDistance: CGFloat = 0
    private(set) var phase: Phase = .idle

    var progress: CGFloat {
        self.isArmed ? 1 : min(self.pullDistance / Self.threshold, 1)
    }

    var isArmed: Bool {
        self.phase == .armed
    }

    var isRefreshing: Bool {
        self.phase == .refreshing || self.phase == .settling
    }

    var showsIndicator: Bool {
        self.phase != .idle
    }

    static func normalizedPullDistance(contentOffsetY: CGFloat, topInset: CGFloat) -> CGFloat {
        max(0, -(contentOffsetY + topInset))
    }

    mutating func update(pullDistance: CGFloat, isInteracting: Bool) {
        self.pullDistance = max(0, pullDistance)

        switch self.phase {
        case .idle:
            guard isInteracting else { return }
            if self.pullDistance >= Self.threshold {
                self.phase = .armed
            } else if self.pullDistance > Self.restTolerance {
                self.phase = .pulling
            }
        case .pulling:
            if isInteracting {
                if self.pullDistance >= Self.threshold {
                    self.phase = .armed
                } else if self.pullDistance <= Self.restTolerance {
                    self.phase = .idle
                }
            } else if self.pullDistance <= Self.restTolerance {
                self.phase = .idle
            }
        case .armed:
            if isInteracting, self.pullDistance < Self.disarmThreshold {
                self.phase = self.pullDistance <= Self.restTolerance ? .idle : .pulling
            } else if !isInteracting, self.pullDistance <= Self.restTolerance {
                self.phase = .idle
            }
        case .refreshing:
            break
        case .settling:
            if self.pullDistance <= Self.restTolerance {
                self.phase = .idle
            }
        }
    }

    /// Returns `true` once when the user releases an armed pull.
    mutating func release(pullDistance: CGFloat) -> Bool {
        guard !self.isRefreshing else { return false }

        // Apply the finger's final position before deciding whether the pull is
        // still armed. This preserves hysteresis while allowing cancellation.
        self.update(pullDistance: pullDistance, isInteracting: true)
        guard self.phase == .armed else { return false }

        self.phase = .refreshing
        return true
    }

    mutating func beginRefreshing() -> Bool {
        guard !self.isRefreshing else { return false }
        self.pullDistance = 0
        self.phase = .refreshing
        return true
    }

    mutating func finishRefreshing() {
        guard self.isRefreshing else { return }
        self.phase = self.pullDistance <= Self.restTolerance ? .idle : .settling
    }
}

// MARK: - PullToRefreshModifier

private struct PullToRefreshModifier: ViewModifier {
    @State private var state = PullToRefreshState()
    @State private var isInteracting = false

    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .scrollBounceBehavior(.always, axes: .vertical)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                PullToRefreshState.normalizedPullDistance(
                    contentOffsetY: geometry.contentOffset.y,
                    topInset: geometry.contentInsets.top
                )
            } action: { _, pullDistance in
                self.state.update(
                    pullDistance: pullDistance,
                    isInteracting: self.isInteracting
                )
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                let wasInteracting = Self.isUserInteracting(oldPhase)
                let isInteracting = Self.isUserInteracting(newPhase)
                let pullDistance = PullToRefreshState.normalizedPullDistance(
                    contentOffsetY: context.geometry.contentOffset.y,
                    topInset: context.geometry.contentInsets.top
                )
                let shouldRefresh: Bool

                if wasInteracting, !isInteracting {
                    shouldRefresh = self.state.release(pullDistance: pullDistance)
                } else {
                    self.state.update(
                        pullDistance: pullDistance,
                        isInteracting: isInteracting
                    )
                    shouldRefresh = false
                }
                self.isInteracting = isInteracting

                guard shouldRefresh else { return }
                self.startRefresh()
            }
            .accessibilityAction(named: Text("Refresh")) {
                guard self.state.beginRefreshing() else { return }
                self.startRefresh()
            }
            .overlay(alignment: .top) {
                if self.state.showsIndicator {
                    Group {
                        if self.state.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(self.state.isArmed ? .primary : .secondary)
                                .rotationEffect(.degrees(self.state.progress * 180))
                        }
                    }
                    .frame(width: 28, height: 28)
                    .compatGlass(in: .circle)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }

    private static func isUserInteracting(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting
    }

    private func startRefresh() {
        Task { @MainActor in
            await self.action()
            self.state.finishRefreshing()
        }
    }
}

extension View {
    func pullToRefresh(action: @escaping @MainActor () async -> Void) -> some View {
        self.modifier(PullToRefreshModifier(action: action))
    }
}
