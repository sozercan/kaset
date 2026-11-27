import Foundation
import Testing
@testable import Kaset

@Suite("AppSource", .serialized, .tags(.model))
@MainActor
struct AppSourceTests {
    @Test("Raw values round-trip")
    func rawValueRoundTrip() {
        for source in AppSource.allCases {
            #expect(AppSource(rawValue: source.rawValue) == source)
        }
    }

    @Test("Identifiers are unique")
    func identifiersUnique() {
        let ids = AppSource.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Display names and icons are non-empty")
    func displayNamesAndIcons() {
        for source in AppSource.allCases {
            #expect(!source.displayName.isEmpty)
            #expect(!source.icon.isEmpty)
        }
    }

    @Test("Music is the first segment in the toggle order")
    func musicIsFirst() {
        #expect(AppSource.allCases.first == .music)
    }

    @Test("SettingsManager persists appSource to UserDefaults")
    func settingsManagerPersistsAppSource() {
        let manager = SettingsManager.shared
        let original = manager.appSource
        defer {
            manager.appSource = original
        }

        manager.appSource = .video
        #expect(
            UserDefaults.standard.string(forKey: SettingsManager.Keys.appSource)
                == AppSource.video.rawValue
        )

        manager.appSource = .music
        #expect(
            UserDefaults.standard.string(forKey: SettingsManager.Keys.appSource)
                == AppSource.music.rawValue
        )
    }

    @Test("AppExperience raw values, identifiers, and display names")
    func appExperienceBasics() {
        for experience in AppExperience.allCases {
            #expect(AppExperience(rawValue: experience.rawValue) == experience)
            #expect(!experience.displayName.isEmpty)
        }
        let ids = AppExperience.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("AppExperience source resolution and URL filtering")
    func appExperiencePolicies() {
        #expect(AppExperience.both.includesMusic)
        #expect(AppExperience.both.includesVideo)
        #expect(AppExperience.both.showsSourceToggle)
        #expect(AppExperience.both.resolvedSource(for: .music) == .music)
        #expect(AppExperience.both.resolvedSource(for: .video) == .video)
        #expect(AppExperience.both.allows(.song(videoId: "abc")))
        #expect(AppExperience.both.allows(.youtubeVideo(videoId: "xyz")))

        #expect(AppExperience.musicOnly.includesMusic)
        #expect(!AppExperience.musicOnly.includesVideo)
        #expect(!AppExperience.musicOnly.showsSourceToggle)
        #expect(AppExperience.musicOnly.resolvedSource(for: .video) == .music)
        #expect(AppExperience.musicOnly.allows(.song(videoId: "abc")))
        #expect(AppExperience.musicOnly.allows(.playlist(id: "PL1")))
        #expect(!AppExperience.musicOnly.allows(.youtubeVideo(videoId: "xyz")))

        #expect(!AppExperience.videoOnly.includesMusic)
        #expect(AppExperience.videoOnly.includesVideo)
        #expect(!AppExperience.videoOnly.showsSourceToggle)
        #expect(AppExperience.videoOnly.resolvedSource(for: .music) == .video)
        #expect(!AppExperience.videoOnly.allows(.song(videoId: "abc")))
        #expect(!AppExperience.videoOnly.allows(.album(id: "MPRE1")))
        #expect(AppExperience.videoOnly.allows(.youtubeVideo(videoId: "xyz")))
    }

    @Test("SettingsManager loads and clamps appExperience and appSource from UserDefaults")
    func settingsManagerLoadsAppExperience() throws {
        let suiteName = "AppSourceTests.appExperience.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsManager.loadAppExperience(from: defaults) == .both)
        #expect(SettingsManager.loadAppSource(from: defaults, experience: .both) == .music)

        defaults.set(AppExperience.videoOnly.rawValue, forKey: SettingsManager.Keys.appExperience)
        defaults.set(AppSource.music.rawValue, forKey: SettingsManager.Keys.appSource)
        let loadedVideoOnly = SettingsManager.loadAppExperience(from: defaults)
        #expect(loadedVideoOnly == .videoOnly)
        #expect(SettingsManager.loadAppSource(from: defaults, experience: loadedVideoOnly) == .video)

        defaults.set(AppExperience.musicOnly.rawValue, forKey: SettingsManager.Keys.appExperience)
        defaults.set(AppSource.video.rawValue, forKey: SettingsManager.Keys.appSource)
        let loadedMusicOnly = SettingsManager.loadAppExperience(from: defaults)
        #expect(loadedMusicOnly == .musicOnly)
        #expect(SettingsManager.loadAppSource(from: defaults, experience: loadedMusicOnly) == .music)
    }

    @Test("SettingsManager enforces appSource when appExperience restricts it")
    func settingsManagerEnforcesAppExperience() {
        let manager = SettingsManager.shared
        let originalExperience = manager.appExperience
        let originalSource = manager.appSource
        defer {
            manager.appExperience = originalExperience
            manager.appSource = originalSource
        }

        manager.appExperience = .both
        manager.appSource = .video

        manager.appExperience = .musicOnly
        #expect(manager.appSource == .music)
        #expect(
            UserDefaults.standard.string(forKey: SettingsManager.Keys.appExperience)
                == AppExperience.musicOnly.rawValue
        )
        manager.appSource = .video
        #expect(manager.appSource == .music)

        manager.appExperience = .videoOnly
        #expect(manager.appSource == .video)
        manager.appSource = .music
        #expect(manager.appSource == .video)

        manager.appExperience = .both
        manager.appSource = .music
        #expect(manager.appSource == .music)
    }

    @Test("Tearing down for experience change preserves saved queue across repeated empty saves")
    func experienceTeardownPreservesSavedSessionAcrossRepeatedSaves() {
        let player = PlayerService()
        let song = TestFixtures.makeSong(id: "preserve-session-song")
        player.setQueue([song])
        player.saveQueueForPersistence()
        defer {
            player.clearPlaybackForSignOut()
        }

        player.tearDownForExperienceChange()
        #expect(player.preservesSavedSessionWhileDisabled)
        #expect(player.queue.isEmpty)

        player.saveQueueForPersistence()
        player.saveQueueForPersistence()

        player.resumeAfterExperienceChange()
        #expect(!player.preservesSavedSessionWhileDisabled)
        #expect(player.queue.map(\.videoId) == ["preserve-session-song"])
    }
}
