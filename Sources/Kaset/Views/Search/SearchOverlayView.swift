import SwiftUI

// MARK: - SearchOverlayWindowTransitionModifier

private struct SearchOverlayWindowTransitionModifier: ViewModifier {
    let blurRadius: CGFloat
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(self.opacity)
            .scaleEffect(self.scale)
            .blur(radius: self.blurRadius)
    }
}

extension AnyTransition {
    /// Search overlay window transition: BlurIn/BlurOut plus a tiny scale and fade.
    static var searchOverlayWindow: AnyTransition {
        .modifier(
            active: SearchOverlayWindowTransitionModifier(blurRadius: 8, opacity: 0, scale: 0.96),
            identity: SearchOverlayWindowTransitionModifier(blurRadius: 0, opacity: 1, scale: 1)
        )
    }
}

// MARK: - SearchOverlayView

/// Floating glass search window shown as an overlay (replaces the old search
/// page as the entry point). Source-agnostic: the query binding, history, and
/// actions are injected so both Music and YouTube can reuse it.
///
/// - Appears/disappears with Scale + Blur (driven by the presenting container).
/// - Shows a Return hint only when text is entered (Blur in/out).
/// - Lists recent searches; up to 5 hug, more than 5 scroll with top/bottom fades.
/// - While `isSearching`, the whole block shimmers and input is blocked.
struct SearchOverlayView: View {
    @Binding var query: String
    let hint: String
    let placeholder: String
    let isSearching: Bool
    let history: [String]
    let onSubmit: () -> Void
    let onSelectHistory: (String) -> Void
    let onRemoveHistory: (String) -> Void
    let dismiss: () -> Void

    @FocusState private var isInputFocused: Bool
    @Namespace private var namespace

    private static let windowWidth: CGFloat = 440
    private static let historyMaxHeight: CGFloat = 200
    private static let cornerRadius: CGFloat = 16
    private static let topBlockShape = UnevenRoundedRectangle(
        cornerRadii: RectangleCornerRadii(
            topLeading: cornerRadius,
            bottomLeading: 0,
            bottomTrailing: 0,
            topTrailing: cornerRadius
        ),
        style: .continuous
    )
    private static let middleBlockShape = UnevenRoundedRectangle(
        cornerRadii: RectangleCornerRadii(
            topLeading: 0,
            bottomLeading: 0,
            bottomTrailing: 0,
            topTrailing: 0
        ),
        style: .continuous
    )
    private static let bottomBlockShape = UnevenRoundedRectangle(
        cornerRadii: RectangleCornerRadii(
            topLeading: 0,
            bottomLeading: cornerRadius,
            bottomTrailing: cornerRadius,
            topTrailing: 0
        ),
        style: .continuous
    )

    private var trimmedQuery: String {
        self.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasText: Bool {
        !self.trimmedQuery.isEmpty
    }

    private var showsHistory: Bool {
        !self.filteredHistory.isEmpty
    }

    private var filteredHistory: [String] {
        let query = self.trimmedQuery
        guard !query.isEmpty else { return self.history }
        return self.history.filter { item in
            item.localizedCaseInsensitiveContains(query)
        }
    }

    private var historyCompletionSuffix: String? {
        let query = self.query
        guard !query.isEmpty else { return nil }
        guard let match = self.history.first(where: { item in
            item.count > query.count && item.range(of: query, options: [.caseInsensitive, .anchored]) != nil
        }) else { return nil }
        return String(match.dropFirst(query.count))
    }

    private var inputBlockShape: UnevenRoundedRectangle {
        self.showsHistory ? Self.middleBlockShape : Self.bottomBlockShape
    }

    var body: some View {
        CompatGlassContainer(spacing: -1) {
            VStack(alignment: .leading, spacing: -1) {
                self.headerHint
                self.inputRow
                if self.showsHistory {
                    self.historyBlock
                }
            }
            .frame(width: Self.windowWidth)
            .overlay {
                if self.isSearching {
                    SearchShimmerOverlay()
                        .clipShape(.rect(cornerRadius: 16))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .compatGlassTransition(.materialize)
        .animation(.easeInOut(duration: 0.2), value: self.isSearching)
        .onAppear { self.isInputFocused = true }
        .onExitCommand { self.dismiss() }
    }

    // MARK: - Header hint

    private var headerHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(self.hintColor)

            Text(self.hint)
                .font(.system(size: 13))
                .foregroundStyle(self.hintColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .compatGlass(interactive: true, in: Self.topBlockShape)
        .compatGlassID("searchOverlay.hint", in: self.namespace)
    }

    /// Hint icon/text: white at 70% in dark mode, a legible equivalent in light.
    private var hintColor: Color {
        Color.primary.opacity(0.7)
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            TextField(self.placeholder, text: self.$query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused(self.$isInputFocused)
                .disabled(self.isSearching)
                .onSubmit(self.submit)
                .onKeyPress(.return, action: self.submitFromKeyPress)
                .onKeyPress(.tab, action: self.acceptHistoryCompletion)
                .onKeyPress(.rightArrow, action: self.acceptHistoryCompletion)
                .overlay(alignment: .leading) {
                    self.historyCompletionOverlay
                }
                .accessibilityIdentifier(AccessibilityID.SearchOverlay.input)

            self.returnHint
        }
        .padding(16)
        .compatGlass(interactive: true, in: self.inputBlockShape)
        .compatGlassID("searchOverlay.inputBlock", in: self.namespace)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping anywhere in the input block focuses the field.
            guard !self.isSearching else { return }
            self.isInputFocused = true
        }
    }

    @ViewBuilder
    private var historyCompletionOverlay: some View {
        if let completionSuffix = self.historyCompletionSuffix {
            HStack(spacing: 0) {
                Text(self.query)
                    .foregroundStyle(.clear)
                Text(completionSuffix)
                    .foregroundStyle(.primary.opacity(0.35))
                Spacer(minLength: 0)
            }
            .font(.system(size: 16))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var returnHint: some View {
        Button(action: self.submit) {
            Image(systemName: "return")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .opacity(self.hasText ? 0.6 : 0)
        .blur(radius: self.hasText ? 0 : 6)
        .allowsHitTesting(self.hasText && !self.isSearching)
        .animation(.easeInOut(duration: 0.2), value: self.hasText)
        .accessibilityHidden(!self.hasText)
        .accessibilityLabel(String(localized: "Search"))
        .accessibilityIdentifier(AccessibilityID.SearchOverlay.returnHint)
    }

    // MARK: - History block

    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.filteredHistory.count > 5 {
                ScrollView(.vertical, showsIndicators: false) {
                    self.historyRows
                        .padding(.vertical, 1)
                }
                .frame(maxHeight: Self.historyMaxHeight)
                .verticalScrollFade(fadeHeight: 36)
            } else {
                self.historyRows
            }
        }
        .padding(8)
        .compatGlass(interactive: true, in: Self.bottomBlockShape)
        .compatGlassID("searchOverlay.historyBlock", in: self.namespace)
        .disabled(self.isSearching)
    }

    private var historyRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(self.filteredHistory.enumerated()), id: \.element) { index, item in
                SearchHistoryRow(
                    query: item,
                    index: index,
                    onSelect: { self.onSelectHistory(item) },
                    onRemove: { self.onRemoveHistory(item) }
                )
            }
        }
    }

    // MARK: - Actions

    private func submit() {
        guard self.hasText, !self.isSearching else { return }
        HapticService.success()
        self.onSubmit()
    }

    private func submitFromKeyPress() -> KeyPress.Result {
        guard self.hasText, !self.isSearching else { return .ignored }
        self.submit()
        return .handled
    }

    private func acceptHistoryCompletion() -> KeyPress.Result {
        guard let completionSuffix = self.historyCompletionSuffix, !completionSuffix.isEmpty else {
            return .ignored
        }
        self.query += completionSuffix
        return .handled
    }
}

// MARK: - SearchShimmerOverlay

/// A subtle moving highlight swept across the whole window while a search runs.
private struct SearchShimmerOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Highlight color per theme: a brighter white sweep in dark mode; a darker
    /// tinted sweep in light mode (where a white `.plusLighter` sweep is invisible).
    private var highlightColor: Color {
        self.colorScheme == .dark
            ? Color.white.opacity(0.18)
            : Color.black.opacity(0.5)
    }

    private var blendMode: BlendMode {
        self.colorScheme == .dark ? .plusLighter : .multiply
    }

    var body: some View {
        if self.reduceMotion {
            self.highlightColor.opacity(0.5)
        } else {
            TimelineView(.animation) { context in
                let phase = (context.date.timeIntervalSinceReferenceDate * 0.9)
                    .truncatingRemainder(dividingBy: 1)
                GeometryReader { proxy in
                    let width = proxy.size.width
                    LinearGradient(
                        colors: [.clear, self.highlightColor, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width * 0.6)
                    .offset(x: -width * 0.6 + phase * (width * 1.6))
                    .blendMode(self.blendMode)
                }
            }
        }
    }
}
