import SwiftUI

enum DetailContentLayout {
    static let horizontalInset: CGFloat = 24
}

extension View {
    func detailScrollContentInset() -> some View {
        self.padding(.horizontal, DetailContentLayout.horizontalInset)
    }
}
