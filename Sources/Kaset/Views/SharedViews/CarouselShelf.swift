import SwiftUI

// MARK: - CarouselShelf

/// A native horizontal shelf with edge fades and glass paging controls.
struct CarouselShelf<Content: View>: View {
    let accessibilityLabel: String
    let fadeWidth: CGFloat
    let pageFraction: CGFloat
    let showsControls: Bool
    let controlVerticalAlignment: VerticalAlignment

    private let content: () -> Content

    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollMetrics = CarouselShelfScrollMetrics()
    @State private var isShelfHovering = false
    @FocusState private var focusedDirection: CarouselShelfDirection?

    init(
        accessibilityLabel: String,
        fadeWidth: CGFloat = 56,
        pageFraction: CGFloat = 0.85,
        showsControls: Bool = true,
        controlVerticalAlignment: VerticalAlignment = .center,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.fadeWidth = fadeWidth
        self.pageFraction = pageFraction
        self.showsControls = showsControls
        self.controlVerticalAlignment = controlVerticalAlignment
        self.content = content
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            self.content()
        }
        .scrollClipDisabled()
        .scrollPosition(self.$scrollPosition)
        .onScrollGeometryChange(for: CarouselShelfScrollMetrics.self) { geometry in
            CarouselShelfScrollMetrics(geometry: geometry)
        } action: { _, newMetrics in
            self.scrollMetrics = newMetrics
        }
        .mask {
            self.edgeFadeMask
        }
        .overlay(alignment: Alignment(horizontal: .leading, vertical: self.controlVerticalAlignment)) {
            if self.showsLeadingControl {
                self.controlButton(for: .leading)
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .overlay(alignment: Alignment(horizontal: .trailing, vertical: self.controlVerticalAlignment)) {
            if self.showsTrailingControl {
                self.controlButton(for: .trailing)
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(AppAnimation.quick, value: self.showsLeadingControl)
        .animation(AppAnimation.quick, value: self.showsTrailingControl)
        .animation(AppAnimation.quick, value: self.hasControlProminence)
        .onHover { isHovering in
            self.isShelfHovering = isHovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var edgeFadeMask: some View {
        HStack(spacing: 0) {
            self.edgeFadeMaskSegment(for: .leading)

            Rectangle()
                .fill(.black)

            self.edgeFadeMaskSegment(for: .trailing)
        }
        .animation(AppAnimation.quick, value: self.hasLeadingOverflow)
        .animation(AppAnimation.quick, value: self.hasTrailingOverflow)
    }

    private var hasLeadingOverflow: Bool {
        self.scrollMetrics.contentOffsetX > 1
    }

    private var hasTrailingOverflow: Bool {
        self.scrollMetrics.remainingContentWidth > 1
    }

    private var showsLeadingControl: Bool {
        self.showsControls && self.hasLeadingOverflow
    }

    private var showsTrailingControl: Bool {
        self.showsControls && self.hasTrailingOverflow
    }

    private var hasControlProminence: Bool {
        self.isShelfHovering || self.focusedDirection != nil
    }

    private func controlButton(for direction: CarouselShelfDirection) -> some View {
        Button {
            self.page(in: direction)
        } label: {
            Image(systemName: direction.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .focused(self.$focusedDirection, equals: direction)
        .compatGlass(interactive: true, in: .circle)
        .opacity(self.hasControlProminence || self.focusedDirection == direction ? 1 : 0.72)
        .scaleEffect(self.focusedDirection == direction ? 1.04 : 1)
        .shadow(
            color: .black.opacity(self.hasControlProminence ? 0.18 : 0.10),
            radius: self.hasControlProminence ? 10 : 8,
            x: 0,
            y: self.hasControlProminence ? 4 : 3
        )
        .accessibilityLabel(self.accessibilityLabel(for: direction))
        .accessibilityHint(String(localized: "Scrolls this shelf by one page"))
    }

    private func edgeFadeMaskSegment(for direction: CarouselShelfDirection) -> some View {
        LinearGradient(
            colors: direction.maskColors(
                isFaded: direction == .leading ? self.hasLeadingOverflow : self.hasTrailingOverflow
            ),
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: self.fadeWidth)
    }

    private func page(in direction: CarouselShelfDirection) {
        let pageWidth = max(1, self.scrollMetrics.viewportWidth * self.pageFraction)
        let destination = switch direction {
        case .leading:
            self.scrollMetrics.contentOffsetX - pageWidth
        case .trailing:
            self.scrollMetrics.contentOffsetX + pageWidth
        }
        let clampedDestination = min(max(destination, 0), self.scrollMetrics.maxContentOffsetX)

        withAnimation(AppAnimation.smooth) {
            self.scrollPosition.scrollTo(x: clampedDestination)
        }
    }

    private func accessibilityLabel(for direction: CarouselShelfDirection) -> String {
        switch direction {
        case .leading:
            String(localized: "Scroll \(self.accessibilityLabel) left")
        case .trailing:
            String(localized: "Scroll \(self.accessibilityLabel) right")
        }
    }
}

// MARK: - CarouselShelfSection

/// A reusable section that renders a header and a horizontal ``CarouselShelf`` of items.
struct CarouselShelfSection<Items: RandomAccessCollection, ID: Hashable, Header: View, ItemContent: View>: View {
    let accessibilityLabel: String
    let items: Items
    let id: KeyPath<Items.Element, ID>
    let sectionSpacing: CGFloat
    let itemAlignment: VerticalAlignment
    let itemSpacing: CGFloat
    let fadeWidth: CGFloat
    let pageFraction: CGFloat
    let showsControls: Bool
    let controlVerticalAlignment: VerticalAlignment

    private let header: () -> Header
    private let itemContent: (Items.Element) -> ItemContent

    init(
        accessibilityLabel: String,
        items: Items,
        id: KeyPath<Items.Element, ID>,
        sectionSpacing: CGFloat = 12,
        itemAlignment: VerticalAlignment = .center,
        itemSpacing: CGFloat = 16,
        fadeWidth: CGFloat = 56,
        pageFraction: CGFloat = 0.85,
        showsControls: Bool = true,
        controlVerticalAlignment: VerticalAlignment = .center,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder itemContent: @escaping (Items.Element) -> ItemContent
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.items = items
        self.id = id
        self.sectionSpacing = sectionSpacing
        self.itemAlignment = itemAlignment
        self.itemSpacing = itemSpacing
        self.fadeWidth = fadeWidth
        self.pageFraction = pageFraction
        self.showsControls = showsControls
        self.controlVerticalAlignment = controlVerticalAlignment
        self.header = header
        self.itemContent = itemContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.sectionSpacing) {
            self.header()

            CarouselShelf(
                accessibilityLabel: self.accessibilityLabel,
                fadeWidth: self.fadeWidth,
                pageFraction: self.pageFraction,
                showsControls: self.showsControls,
                controlVerticalAlignment: self.controlVerticalAlignment
            ) {
                LazyHStack(alignment: self.itemAlignment, spacing: self.itemSpacing) {
                    ForEach(self.items, id: self.id) { item in
                        self.itemContent(item)
                    }
                }
            }
        }
    }
}

extension CarouselShelfSection where Items.Element: Identifiable, ID == Items.Element.ID {
    init(
        accessibilityLabel: String,
        items: Items,
        sectionSpacing: CGFloat = 12,
        itemAlignment: VerticalAlignment = .center,
        itemSpacing: CGFloat = 16,
        fadeWidth: CGFloat = 56,
        pageFraction: CGFloat = 0.85,
        showsControls: Bool = true,
        controlVerticalAlignment: VerticalAlignment = .center,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder itemContent: @escaping (Items.Element) -> ItemContent
    ) {
        self.init(
            accessibilityLabel: accessibilityLabel,
            items: items,
            id: \.id,
            sectionSpacing: sectionSpacing,
            itemAlignment: itemAlignment,
            itemSpacing: itemSpacing,
            fadeWidth: fadeWidth,
            pageFraction: pageFraction,
            showsControls: showsControls,
            controlVerticalAlignment: controlVerticalAlignment,
            header: header,
            itemContent: itemContent
        )
    }
}

// MARK: - CarouselShelfScrollMetrics

private struct CarouselShelfScrollMetrics: Equatable {
    var contentOffsetX: CGFloat = 0
    var viewportWidth: CGFloat = 0
    var contentWidth: CGFloat = 0

    init() {}

    init(geometry: ScrollGeometry) {
        self.viewportWidth = max(0, geometry.containerSize.width)
        self.contentWidth = max(0, geometry.contentSize.width)
        self.contentOffsetX = min(max(geometry.contentOffset.x, 0), max(0, self.contentWidth - self.viewportWidth))
    }

    var maxContentOffsetX: CGFloat {
        max(0, self.contentWidth - self.viewportWidth)
    }

    var remainingContentWidth: CGFloat {
        max(0, self.maxContentOffsetX - self.contentOffsetX)
    }
}

// MARK: - CarouselShelfDirection

private enum CarouselShelfDirection: Hashable {
    case leading
    case trailing

    var systemImage: String {
        switch self {
        case .leading:
            "chevron.left"
        case .trailing:
            "chevron.right"
        }
    }

    func maskColors(isFaded: Bool) -> [Color] {
        guard isFaded else {
            return [.black, .black]
        }

        switch self {
        case .leading:
            return [.clear, .black]
        case .trailing:
            return [.black, .clear]
        }
    }
}
