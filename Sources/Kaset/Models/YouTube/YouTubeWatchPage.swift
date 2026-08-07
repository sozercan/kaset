import Foundation

/// One watch-page response parsed into both the existing companion data and an
/// optional, watch-scoped Ask Gemini bootstrap from the same `next` request.
struct YouTubeWatchPage {
    let data: WatchNextData
    let askBootstrap: YouTubeAskBootstrap?
}
