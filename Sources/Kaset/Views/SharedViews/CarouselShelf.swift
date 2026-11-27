import SwiftUI

struct CarouselShelf<Content: View>: View {
    let accessibilityLabel: String
    let pageFraction: CGFloat
    let showsControls: Bool
    let controlVerticalAlignment: VerticalAlignment
    let contentInset: CGFloat

    private let content: () -> Content

    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var hover = CarouselShelfHover()
    @State private var metricsStore = CarouselShelfMetricsStore()
    @State private var overflow = CarouselShelfOverflow()

    init(
        accessibilityLabel: String,
        pageFraction: CGFloat = 0.85,
        showsControls: Bool = true,
        controlVerticalAlignment: VerticalAlignment = .center,
        contentInset: CGFloat = 0,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.pageFraction = pageFraction
        self.showsControls = showsControls
        self.controlVerticalAlignment = controlVerticalAlignment
        self.contentInset = contentInset
        self.content = content
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                if self.contentInset > 0 {
                    Spacer()
                        .frame(width: self.contentInset)
                }
                self.content()
                if self.contentInset > 0 {
                    Spacer()
                        .frame(width: self.contentInset)
                }
            }
        }
        .scrollPosition(self.$scrollPosition)
        .onScrollGeometryChange(for: CarouselShelfScrollMetrics.self) { geometry in
            CarouselShelfScrollMetrics(geometry: geometry)
        } action: { _, newMetrics in
            self.metricsStore.metrics = newMetrics
            let overflow = CarouselShelfOverflow(metrics: newMetrics)
            if overflow != self.overflow {
                self.overflow = overflow
            }
        }
        .modifier(CarouselShelfPagingControls(
            accessibilityLabel: self.accessibilityLabel,
            showsLeading: self.showsControls && self.overflow.leading,
            showsTrailing: self.showsControls && self.overflow.trailing,
            controlVerticalAlignment: self.controlVerticalAlignment,
            contentInset: self.contentInset,
            page: self.page(in:),
            hover: self.hover
        ))
        .onHover { isHovering in
            self.hover.isHovering = isHovering
        }
    }

    private func page(in direction: CarouselShelfDirection) {
        let metrics = self.metricsStore.metrics
        let pageWidth = max(1, metrics.viewportWidth * self.pageFraction)
        let destination = switch direction {
        case .leading:
            metrics.contentOffsetX - pageWidth
        case .trailing:
            metrics.contentOffsetX + pageWidth
        }
        let clampedDestination = min(max(destination, 0), metrics.maxContentOffsetX)

        withAnimation(AppAnimation.smooth) {
            self.scrollPosition.scrollTo(x: clampedDestination)
        }
    }
}

@MainActor
@Observable
final class CarouselShelfHover {
    var isHovering = false
}

struct CarouselShelfPagingControls: ViewModifier {
    let accessibilityLabel: String
    let showsLeading: Bool
    let showsTrailing: Bool
    let controlVerticalAlignment: VerticalAlignment
    let contentInset: CGFloat
    let page: (CarouselShelfDirection) -> Void
    let hover: CarouselShelfHover

    @FocusState private var focusedDirection: CarouselShelfDirection?
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        content
            .overlay(alignment: Alignment(horizontal: .leading, vertical: self.controlVerticalAlignment)) {
                if self.showsLeading {
                    self.controlButton(for: .leading)
                        .padding(.leading, self.contentInset + 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .overlay(alignment: Alignment(horizontal: .trailing, vertical: self.controlVerticalAlignment)) {
                if self.showsTrailing {
                    self.controlButton(for: .trailing)
                        .padding(.trailing, self.contentInset + 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(AppAnimation.quick, value: self.showsLeading)
            .animation(AppAnimation.quick, value: self.showsTrailing)
            .animation(AppAnimation.quick, value: self.hasControlProminence)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(self.accessibilityLabel)
    }

    private var hasControlProminence: Bool {
        self.hover.isHovering || self.focusedDirection != nil
    }

    private func controlButton(for direction: CarouselShelfDirection) -> some View {
        Button {
            self.page(direction)
        } label: {
            Image(systemName: direction.isLeft(in: self.layoutDirection) ? "chevron.left" : "chevron.right")
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
        .accessibilityLabel(Self.accessibilityLabel(shelf: self.accessibilityLabel, isLeft: direction.isLeft(in: self.layoutDirection)))
        .accessibilityHint(Self.accessibilityHint)
    }

    static func accessibilityLabel(shelf: String, isLeft: Bool) -> String {
        if isLeft {
            String(localized: "Scroll \(shelf) left")
        } else {
            String(localized: "Scroll \(shelf) right")
        }
    }

    static var accessibilityHint: String {
        String(localized: "Scrolls this shelf by one page")
    }
}

struct CarouselShelfSection<Items: RandomAccessCollection, ID: Hashable, Header: View, ItemContent: View>: View {
    let accessibilityLabel: String
    let items: Items
    let id: KeyPath<Items.Element, ID>
    let sectionSpacing: CGFloat
    let itemAlignment: VerticalAlignment
    let itemSpacing: CGFloat
    let pageFraction: CGFloat
    let showsControls: Bool
    let controlVerticalAlignment: VerticalAlignment
    let contentInset: CGFloat

    private let header: () -> Header
    private let itemContent: (Items.Element) -> ItemContent

    init(
        accessibilityLabel: String,
        items: Items,
        id: KeyPath<Items.Element, ID>,
        sectionSpacing: CGFloat = 12,
        itemAlignment: VerticalAlignment = .center,
        itemSpacing: CGFloat = 16,
        pageFraction: CGFloat = 0.85,
        showsControls: Bool = true,
        controlVerticalAlignment: VerticalAlignment = .center,
        contentInset: CGFloat = 0,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder itemContent: @escaping (Items.Element) -> ItemContent
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.items = items
        self.id = id
        self.sectionSpacing = sectionSpacing
        self.itemAlignment = itemAlignment
        self.itemSpacing = itemSpacing
        self.pageFraction = pageFraction
        self.showsControls = showsControls
        self.controlVerticalAlignment = controlVerticalAlignment
        self.contentInset = contentInset
        self.header = header
        self.itemContent = itemContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.sectionSpacing) {
            self.header()
                .padding(.horizontal, self.contentInset)

            CarouselShelf(
                accessibilityLabel: self.accessibilityLabel,
                pageFraction: self.pageFraction,
                showsControls: self.showsControls,
                controlVerticalAlignment: self.controlVerticalAlignment,
                contentInset: self.contentInset
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
        pageFraction: CGFloat = 0.85,
        showsControls: Bool = true,
        controlVerticalAlignment: VerticalAlignment = .center,
        contentInset: CGFloat = 0,
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
            pageFraction: pageFraction,
            showsControls: showsControls,
            controlVerticalAlignment: controlVerticalAlignment,
            contentInset: contentInset,
            header: header,
            itemContent: itemContent
        )
    }
}

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

@MainActor
private final class CarouselShelfMetricsStore {
    var metrics = CarouselShelfScrollMetrics()
}

struct CarouselShelfOverflow: Equatable {
    var leading = false
    var trailing = false

    init() {}

    fileprivate init(metrics: CarouselShelfScrollMetrics) {
        self.leading = metrics.contentOffsetX > 1
        self.trailing = metrics.remainingContentWidth > 1
    }
}

enum CarouselShelfDirection: Hashable {
    case leading
    case trailing

    init(isLeft: Bool, in layoutDirection: LayoutDirection) {
        self = isLeft == (layoutDirection == .leftToRight) ? .leading : .trailing
    }

    func isLeft(in layoutDirection: LayoutDirection) -> Bool {
        (self == .leading) == (layoutDirection == .leftToRight)
    }
}
