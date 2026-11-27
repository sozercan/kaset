import AppKit
import Testing
import WebKit
@testable import Kaset

@Suite(.tags(.service))
struct PlaybackSpaceKeyMonitorTests {
    private static func handles(
        keyCode: UInt16 = PlaybackSpaceKeyMonitor.spaceKeyCode,
        modifiers: NSEvent.ModifierFlags = [],
        isRepeat: Bool = false,
        isPrimaryWindow: Bool = true,
        isTextInputFocused: Bool = false,
        isWebContentFocused: Bool = false,
        isNativeBrowsingContentFocused: Bool = true,
        isPlaybackCommandEnabled: Bool = true
    ) -> Bool {
        PlaybackSpaceKeyMonitor.handlesSpaceKey(PlaybackSpaceKeyContext(
            keyCode: keyCode,
            modifiers: modifiers,
            isRepeat: isRepeat,
            isPrimaryWindow: isPrimaryWindow,
            isTextInputFocused: isTextInputFocused,
            isWebContentFocused: isWebContentFocused,
            isNativeBrowsingContentFocused: isNativeBrowsingContentFocused,
            isPlaybackCommandEnabled: isPlaybackCommandEnabled
        ))
    }

    @Test("Bare Space over native UI is claimed for play/pause")
    func bareSpaceOverNativeUIIsClaimed() {
        #expect(Self.handles())
    }

    @Test("Keys other than Space are never claimed")
    func otherKeysAreNotClaimed() {
        #expect(!Self.handles(keyCode: 123))
        #expect(!Self.handles(keyCode: 124))
        #expect(!Self.handles(keyCode: 36))
    }

    @Test("Space with a modifier is left alone so it stays available as a shortcut")
    func modifiedSpaceIsNotClaimed() {
        #expect(!Self.handles(modifiers: .command))
        #expect(!Self.handles(modifiers: .option))
        #expect(!Self.handles(modifiers: .shift))
        #expect(!Self.handles(modifiers: .function))
        #expect(!Self.handles(modifiers: [.command, .shift]))
    }

    @Test("Caps lock and numeric-pad flags do not stop Space from being claimed")
    func incidentalModifiersAreIgnored() {
        #expect(Self.handles(modifiers: .capsLock))
        #expect(Self.handles(modifiers: [.capsLock, .numericPad]))
    }

    @Test("Space outside the primary playback window is left to that window")
    func spaceOutsidePrimaryWindowIsNotClaimed() {
        #expect(!Self.handles(isPrimaryWindow: false))
    }

    @Test("Repeated Space key-down events are ignored")
    func repeatedSpaceIsNotClaimed() {
        #expect(!Self.handles(isRepeat: true))
    }

    @Test("Space is left to a focused control that uses it for activation")
    func focusedControlKeepsSpace() {
        #expect(!Self.handles(isNativeBrowsingContentFocused: false))
    }

    @Test("Space types normally while a text field is being edited")
    func textInputKeepsSpace() {
        #expect(!Self.handles(isTextInputFocused: true))
    }

    @Test("Space is left to the page while the player WebView holds focus")
    func webContentKeepsSpace() {
        #expect(!Self.handles(isWebContentFocused: true))
    }

    @Test("Space is not claimed when the playback command is disabled")
    func disabledPlaybackCommandKeepsSpace() {
        #expect(!Self.handles(isPlaybackCommandEnabled: false))
    }

    @Test("Only native table browsing focus is eligible for playback interception")
    @MainActor
    func recognisesNativeBrowsingContent() {
        #expect(PlaybackSpaceKeyMonitor.isNativeBrowsingContent(NSOutlineView(frame: .zero)))
        #expect(PlaybackSpaceKeyMonitor.isNativeBrowsingContent(NSTableView(frame: .zero)))
        #expect(!PlaybackSpaceKeyMonitor.isNativeBrowsingContent(NSButton(frame: .zero)))
        #expect(!PlaybackSpaceKeyMonitor.isNativeBrowsingContent(NSSlider(frame: .zero)))
        #expect(!PlaybackSpaceKeyMonitor.isNativeBrowsingContent(NSView(frame: .zero)))
    }

    @Test("Responders inside a WKWebView are recognised as web content")
    @MainActor
    func recognisesWebContentResponders() {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let contentView = NSView(frame: .zero)
        webView.addSubview(contentView)

        #expect(PlaybackSpaceKeyMonitor.isWebContent(webView))
        #expect(PlaybackSpaceKeyMonitor.isWebContent(contentView))
        #expect(!PlaybackSpaceKeyMonitor.isWebContent(NSView(frame: .zero)))
        #expect(!PlaybackSpaceKeyMonitor.isWebContent(NSButton(frame: .zero)))
    }
}
