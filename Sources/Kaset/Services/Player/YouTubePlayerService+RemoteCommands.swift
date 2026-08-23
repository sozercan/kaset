import Foundation

@MainActor
extension YouTubePlayerService {
    private static let maximumFutureCommandSkewMilliseconds = 5000.0

    @discardableResult
    func beginYouTubePlaybackIntent(
        issuedAtMilliseconds: Double? = nil
    ) -> UInt64 {
        let now = Date().timeIntervalSince1970 * 1000
        let candidate = issuedAtMilliseconds ?? now
        guard candidate.isFinite else { return self.youtubePlaybackIntentGeneration }
        let previousBoundary = self.youtubePlaybackIntentIssuedAtMilliseconds
        if issuedAtMilliseconds != nil {
            guard candidate <= now + Self.maximumFutureCommandSkewMilliseconds,
                  candidate >= previousBoundary
            else { return self.youtubePlaybackIntentGeneration }
        }
        self.youtubePlaybackIntentGeneration &+= 1
        let generation = self.youtubePlaybackIntentGeneration
        if issuedAtMilliseconds == nil {
            self.youtubePlaybackIntentIssuedAtMilliseconds = previousBoundary > now + Self.maximumFutureCommandSkewMilliseconds
                ? now
                : max(previousBoundary, now)
            self.youtubeRemoteCommandIntentIssuedAtMilliseconds = nil
        } else {
            self.youtubePlaybackIntentIssuedAtMilliseconds = max(previousBoundary, candidate)
            self.youtubeRemoteCommandIntentIssuedAtMilliseconds = nil
        }
        return generation
    }

    func acceptsYouTubeRemoteCommand(issuedAtMilliseconds: Double) -> Bool {
        let now = Date().timeIntervalSince1970 * 1000
        guard issuedAtMilliseconds.isFinite,
              issuedAtMilliseconds <= now + Self.maximumFutureCommandSkewMilliseconds
        else { return false }
        if issuedAtMilliseconds > self.youtubePlaybackIntentIssuedAtMilliseconds {
            return true
        }
        return issuedAtMilliseconds == self.youtubePlaybackIntentIssuedAtMilliseconds
            && self.youtubeRemoteCommandIntentIssuedAtMilliseconds == issuedAtMilliseconds
    }

    @discardableResult
    func admitYouTubeRemoteCommand(issuedAtMilliseconds: Double) -> Bool {
        guard self.acceptsYouTubeRemoteCommand(
            issuedAtMilliseconds: issuedAtMilliseconds
        ) else { return false }
        self.youtubePlaybackIntentIssuedAtMilliseconds = max(
            self.youtubePlaybackIntentIssuedAtMilliseconds,
            issuedAtMilliseconds
        )
        self.youtubeRemoteCommandIntentIssuedAtMilliseconds = issuedAtMilliseconds
        self.youtubePlaybackIntentGeneration &+= 1
        return true
    }

    func handleRemoteTogglePlayPause(issuedAtMilliseconds: Double) {
        guard self.admitYouTubeRemoteCommand(
            issuedAtMilliseconds: issuedAtMilliseconds
        ) else { return }
        self.performPlayPause(resumeIssuedAtMilliseconds: issuedAtMilliseconds)
    }

    func handleRemoteResume(issuedAtMilliseconds: Double) {
        guard self.admitYouTubeRemoteCommand(
            issuedAtMilliseconds: issuedAtMilliseconds
        ) else { return }
        self.performResume(issuedAtMilliseconds: issuedAtMilliseconds)
    }

    func handleRemotePause(issuedAtMilliseconds: Double) {
        guard self.admitYouTubeRemoteCommand(
            issuedAtMilliseconds: issuedAtMilliseconds
        ) else { return }
        self.performPause()
    }

    func handleRemoteSkipForward(issuedAtMilliseconds: Double) async {
        guard self.admitYouTubeRemoteCommand(
            issuedAtMilliseconds: issuedAtMilliseconds
        ) else { return }
        await self.skipForward(ownedBy: self.youtubePlaybackIntentGeneration)
    }

    func handleRemoteSkipBackward(issuedAtMilliseconds: Double) {
        guard self.admitYouTubeRemoteCommand(
            issuedAtMilliseconds: issuedAtMilliseconds
        ) else { return }
        self.skipBackwardWithoutBeginningIntent()
    }
}
