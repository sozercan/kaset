import AppKit
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct PlaybackSpaceKeyMonitorTests {
    private static func handles(
        keyCode: UInt16 = PlaybackSpaceKeyMonitor.spaceKeyCode,
        modifiers: NSEvent.ModifierFlags = [],
        isTextInputFocused: Bool = false,
        isWebContentFocused: Bool = false,
        isPlaybackCommandEnabled: Bool = true
    ) -> Bool {
        PlaybackSpaceKeyMonitor.handlesSpaceKey(
            keyCode: keyCode,
            modifiers: modifiers,
            isTextInputFocused: isTextInputFocused,
            isWebContentFocused: isWebContentFocused,
            isPlaybackCommandEnabled: isPlaybackCommandEnabled
        )
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
        #expect(!Self.handles(modifiers: [.command, .shift]))
    }

    @Test("Caps lock and function flags do not stop Space from being claimed")
    func incidentalModifiersAreIgnored() {
        #expect(Self.handles(modifiers: .capsLock))
        #expect(Self.handles(modifiers: .function))
        #expect(Self.handles(modifiers: [.capsLock, .numericPad]))
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

    @Test("WebKit responder class names are recognised as web content")
    func recognisesWebContentResponders() {
        #expect(PlaybackSpaceKeyMonitor.isWebContent("KasetWebView"))
        #expect(PlaybackSpaceKeyMonitor.isWebContent("WKWebView"))
        #expect(PlaybackSpaceKeyMonitor.isWebContent("WKContentView"))
        #expect(!PlaybackSpaceKeyMonitor.isWebContent("SwiftUIOutlineListView"))
        #expect(!PlaybackSpaceKeyMonitor.isWebContent("NSButton"))
    }
}
