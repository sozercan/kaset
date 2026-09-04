import SwiftUI

struct WithinWindowBlurView: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = .sidebar // or .hudWindow, .popover, etc.
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}
