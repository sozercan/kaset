import AppKit
import Testing
@testable import Kaset

@Suite("Dock menu Like item", .serialized)
@MainActor
struct AppDelegateDockMenuTests {
    private func loggedInPlayer() -> PlayerService {
        let authService = AuthService(webKitManager: MockWebKitManager())
        authService.completeLogin(sapisid: "test-sapisid")
        let player = PlayerService()
        player.setAuthService(authService)
        return player
    }

    init() {
        SongLikeStatusManager.shared.clearCache()
        SongLikeStatusManager.shared.setActiveAccountID(nil)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0 ..< 20 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func likeItem(_ delegate: AppDelegate) -> NSMenuItem? {
        let menu = delegate.applicationDockMenu(NSApplication.shared)
        return menu?.items.first { $0.action == NSSelectorFromString("dockMenuToggleLike") }
    }

    @Test("Disabled and reads 'Like' for a live player with no current track")
    func disabledWithNoTrack() {
        let delegate = AppDelegate()
        let player = self.loggedInPlayer()
        delegate.playerService = player
        #expect(player.currentTrack == nil)

        let item = self.likeItem(delegate)

        #expect(item?.title == "Like")
        #expect(item?.isEnabled == false)
    }

    @Test("Reads 'Like' and is enabled for an unliked current track")
    func likeForUnlikedTrack() {
        let delegate = AppDelegate()
        let player = self.loggedInPlayer()
        player.currentTrack = TestFixtures.makeSong(id: "v1")
        player.currentTrackLikeStatus = .indifferent
        delegate.playerService = player

        let item = self.likeItem(delegate)

        #expect(item?.title == "Like")
        #expect(item?.isEnabled == true)
    }

    @Test("Like item is disabled for a guest current track")
    func likeDisabledForGuestTrack() {
        let delegate = AppDelegate()
        let player = PlayerService()
        player.currentTrack = TestFixtures.makeSong(id: "v1")
        player.currentTrackLikeStatus = .indifferent
        delegate.playerService = player

        let item = self.likeItem(delegate)

        #expect(item?.title == "Like")
        #expect(item?.isEnabled == false)
    }

    @Test("Reads 'Unlike' for an already-liked current track")
    func unlikeForLikedTrack() {
        let delegate = AppDelegate()
        let player = self.loggedInPlayer()
        player.currentTrack = TestFixtures.makeSong(id: "v1")
        player.currentTrackLikeStatus = .like
        delegate.playerService = player

        let item = self.likeItem(delegate)

        #expect(item?.title == "Unlike")
        #expect(item?.isEnabled == true)
    }

    @Test("Triggering the item toggles the like state via likeCurrentTrack()")
    func triggeringItemTogglesLike() async {
        let delegate = AppDelegate()
        let player = self.loggedInPlayer()
        player.currentTrack = TestFixtures.makeSong(id: "v1")
        player.currentTrackLikeStatus = .indifferent
        delegate.playerService = player

        let item = self.likeItem(delegate)
        #expect(item?.target === delegate)

        guard let action = item?.action else {
            Issue.record("Like item has no action wired")
            return
        }
        _ = delegate.perform(action)

        await self.waitUntil { player.currentTrackLikeStatus == .like }
        #expect(player.currentTrackLikeStatus == .like)
    }

    @Test("Triggering the item un-likes an already-liked track")
    func triggeringItemUnlikesLikedTrack() async {
        let delegate = AppDelegate()
        let player = self.loggedInPlayer()
        player.currentTrack = TestFixtures.makeSong(id: "v1")
        player.currentTrackLikeStatus = .like
        delegate.playerService = player

        let item = self.likeItem(delegate)
        guard let action = item?.action else {
            Issue.record("Like item has no action wired")
            return
        }
        _ = delegate.perform(action)

        await self.waitUntil { player.currentTrackLikeStatus == .indifferent }
        #expect(player.currentTrackLikeStatus == .indifferent)
    }

    @Test("Transport items stay enabled even with no current track")
    func transportItemsEnabledWithNoTrack() {
        let delegate = AppDelegate()
        let player = self.loggedInPlayer()
        delegate.playerService = player
        #expect(player.currentTrack == nil)

        let menu = delegate.applicationDockMenu(NSApplication.shared)
        for title in ["Play/Pause", "Next Track", "Previous Track"] {
            let item = menu?.items.first { $0.title == title }
            #expect(item?.isEnabled == true, "\(title) should remain enabled under autoenablesItems = false")
        }
    }
}
