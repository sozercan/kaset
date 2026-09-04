import AppKit
import Testing
@testable import Kaset

@Suite("Kaset WebView")
struct KasetWebViewTests {
    @Test("Hidden WebView declines command-arrow playback shortcuts")
    func hiddenWebViewDeclinesCommandArrows() {
        for keyCode in [KasetWebView.leftArrowKeyCode, KasetWebView.rightArrowKeyCode] {
            #expect(KasetWebView.declinesHiddenPlaybackKeyEquivalent(
                keyCode: keyCode,
                modifiers: [.command, .numericPad],
                isHidden: true
            ))
        }
    }

    @Test("Visible WebView keeps command-arrow handling")
    func visibleWebViewKeepsCommandArrows() {
        #expect(!KasetWebView.declinesHiddenPlaybackKeyEquivalent(
            keyCode: KasetWebView.leftArrowKeyCode,
            modifiers: .command,
            isHidden: false
        ))
    }

    @Test("Hidden WebView keeps unrelated key equivalents")
    func hiddenWebViewKeepsUnrelatedKeyEquivalents() {
        #expect(!KasetWebView.declinesHiddenPlaybackKeyEquivalent(
            keyCode: PlaybackSpaceKeyMonitor.spaceKeyCode,
            modifiers: [],
            isHidden: true
        ))
        #expect(!KasetWebView.declinesHiddenPlaybackKeyEquivalent(
            keyCode: KasetWebView.rightArrowKeyCode,
            modifiers: [.command, .option],
            isHidden: true
        ))
        #expect(!KasetWebView.declinesHiddenPlaybackKeyEquivalent(
            keyCode: KasetWebView.rightArrowKeyCode,
            modifiers: [.command, .function],
            isHidden: true
        ))
    }
}
