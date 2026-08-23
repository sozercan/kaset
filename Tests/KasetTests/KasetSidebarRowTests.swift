import SwiftUI
import Testing
@testable import Kaset

@MainActor
@Suite(.tags(.model))
struct KasetSidebarRowTests {
    @Test("KasetSidebarRow constructs selected and unselected rows")
    func constructsSelectedAndUnselectedRows() {
        let selected = KasetSidebarRow(
            title: "Home",
            systemImage: "house",
            isSelected: true,
            action: {}
        )
        let unselected = KasetSidebarRow(
            title: "Search",
            systemImage: "magnifyingglass",
            isSelected: false,
            action: {}
        )

        #expect(String(describing: selected).isEmpty == false)
        #expect(String(describing: unselected).isEmpty == false)
    }
}
