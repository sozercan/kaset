import AppKit

enum MainWindowLayout {
    static let sceneIdentifier = "main"
    static let autosaveName = "KasetMainWindow"
    static let windowTitle = "Kaset"
    static let minimumWidth: CGFloat = 980
    static let minimumHeight: CGFloat = 600
    static let defaultWidth: CGFloat = 1100
    static let defaultHeight: CGFloat = 760
    static let aiTaskSurfaceTopPadding: CGFloat = 72

    static var minimumContentSize: NSSize {
        NSSize(width: minimumWidth, height: minimumHeight)
    }

    static func isPrimaryWindowIdentity(
        title: String,
        frameAutosaveName: String,
        identifier: String? = nil
    ) -> Bool {
        identifier == self.sceneIdentifier
            || frameAutosaveName == self.sceneIdentifier
            || frameAutosaveName == self.autosaveName
            || title == self.windowTitle
    }

    @MainActor
    static func isPrimaryWindow(_ window: NSWindow) -> Bool {
        self.isPrimaryWindowIdentity(
            title: window.title,
            frameAutosaveName: window.frameAutosaveName,
            identifier: window.identifier?.rawValue
        )
    }

    @MainActor
    static func configure(_ window: NSWindow) {
        guard self.isPrimaryWindow(window) else { return }

        self.configureKnownPrimaryWindow(window)
    }

    @MainActor
    static func configureKnownPrimaryWindow(_ window: NSWindow) {
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName(self.autosaveName)
        }

        window.contentMinSize = self.minimumContentSize
        self.expandIfNeeded(window)
    }

    static func clampedContentSize(_ contentSize: NSSize) -> NSSize {
        NSSize(
            width: max(contentSize.width, self.minimumWidth),
            height: max(contentSize.height, self.minimumHeight)
        )
    }

    @MainActor
    private static func expandIfNeeded(_ window: NSWindow) {
        let currentFrame = window.frame
        let currentContentSize = window.contentRect(forFrameRect: currentFrame).size
        let clampedContentSize = Self.clampedContentSize(currentContentSize)

        guard clampedContentSize.width > currentContentSize.width
            || clampedContentSize.height > currentContentSize.height
        else { return }

        let clampedFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: clampedContentSize)
        ).size
        var clampedFrame = currentFrame
        clampedFrame.size = clampedFrameSize
        clampedFrame.origin.y = currentFrame.maxY - clampedFrameSize.height

        let constrainedFrame = window.constrainFrameRect(clampedFrame, to: window.screen)
        window.setFrame(constrainedFrame, display: true)
    }
}
