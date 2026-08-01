import Testing
@testable import Kaset

extension YouTubeWatchScriptTests {
    @Test("Archived live-origin media is not reported as currently live")
    func archivedLiveOriginIsNotCurrentlyLive() throws {
        let context = try self.makeObserverContext(paused: false)
        try self.evaluate(
            """
            moviePlayer.getVideoData = function() {
                return {
                    video_id: 'abc123',
                    title: 'Archived Stream',
                    isLive: false,
                    isLiveContent: true
                };
            };
            video.duration = 120;
            """,
            in: context
        )

        try self.evaluate(YouTubeWatchWebView.observerScript, in: context)

        #expect(context.evaluateScript("postedMessages[0].isLive").toBool() == false)
    }
}
