import Foundation

/// Verified playback captured while the coordinator is still determining whether a long video is
/// a mix. Once chapters arrive, the progress ranges can be apportioned to their real sub-tracks.
struct ProvisionalMixPlaybackHistory {
    struct Credit {
        var accumulatedPlayTime: TimeInterval = 0
        var startTime: Date?
        var endProgress: TimeInterval = 0
        var hasScrobbled = false
        var isActiveAtEnd = false
    }

    private struct Segment {
        let startProgress: TimeInterval
        var endProgress: TimeInterval
        let startTime: Date
        var isDiscontinuity = false
    }

    private var segments: [Segment] = []

    var isEmpty: Bool {
        self.segments.isEmpty
    }

    var hasPlayback: Bool {
        self.segments.contains { !$0.isDiscontinuity && $0.endProgress > $0.startProgress }
    }

    mutating func record(
        startProgress: TimeInterval,
        endProgress: TimeInterval,
        startTime: Date
    ) {
        let segment = Segment(
            startProgress: startProgress,
            endProgress: endProgress,
            startTime: startTime
        )
        if let lastIndex = self.segments.indices.last {
            let lastSegment = self.segments[lastIndex]
            let expectedEndTime = lastSegment.startTime.addingTimeInterval(
                lastSegment.endProgress - lastSegment.startProgress
            )
            let isProgressContiguous = abs(lastSegment.endProgress - segment.startProgress) < 0.001
            let isTimeContiguous = abs(segment.startTime.timeIntervalSince(expectedEndTime)) < 2
            if !lastSegment.isDiscontinuity, isProgressContiguous, isTimeContiguous {
                self.segments[lastIndex].endProgress = segment.endProgress
                return
            }
        }

        self.segments.append(segment)
    }

    mutating func recordDiscontinuity(at progress: TimeInterval, startTime: Date) {
        self.segments.append(Segment(
            startProgress: progress,
            endProgress: progress,
            startTime: startTime,
            isDiscontinuity: true
        ))
    }

    mutating func removeAll() {
        self.segments.removeAll()
    }

    func credits(
        tracklist: MixTracklist,
        videoDuration: TimeInterval?,
        thresholds: PlaybackScrobbleTracker.Thresholds
    ) -> [UUID: [Credit]] {
        var credits: [UUID: [Credit]] = [:]

        for (index, entry) in tracklist.entries.enumerated() {
            let isFinalEntry = tracklist.entries.last?.id == entry.id
            let nextEntryStart = tracklist.entries.indices.contains(index + 1)
                ? tracklist.entries[index + 1].startTime
                : nil
            let boundedEntryEnd = entry.endTime ?? nextEntryStart ?? (isFinalEntry ? videoDuration : nil)
            let duration = tracklist.effectiveDuration(for: entry, videoDuration: videoDuration)
            var currentCredit: Credit?
            var lastOverlapEnd: TimeInterval?
            var completedScrobbledPlay = false

            for segment in self.segments {
                if segment.isDiscontinuity {
                    if let finishedCredit = currentCredit {
                        credits[entry.id, default: []].append(finishedCredit)
                        completedScrobbledPlay = completedScrobbledPlay || finishedCredit.hasScrobbled
                        currentCredit = nil
                    }
                    lastOverlapEnd = segment.startProgress
                    continue
                }

                let entryEnd = boundedEntryEnd ?? (isFinalEntry ? segment.endProgress : nil)
                guard let entryEnd, entryEnd > entry.startTime else { continue }
                let overlapStart = max(segment.startProgress, entry.startTime)
                let overlapEnd = min(segment.endProgress, entryEnd)
                guard overlapEnd > overlapStart else {
                    if let finishedCredit = currentCredit {
                        credits[entry.id, default: []].append(finishedCredit)
                        completedScrobbledPlay = completedScrobbledPlay || finishedCredit.hasScrobbled
                        currentCredit = nil
                        lastOverlapEnd = nil
                    }
                    continue
                }

                let overlapStartTime = segment.startTime.addingTimeInterval(overlapStart - segment.startProgress)
                let progressJump = lastOverlapEnd.map { overlapStart - $0 } ?? 0
                let isSignificantJump = abs(progressJump) > 5

                if let credit = currentCredit, isSignificantJump {
                    let isReplay = credit.hasScrobbled
                        && progressJump < -5
                        && overlapStart <= entry.startTime + 5
                    if isReplay {
                        credits[entry.id, default: []].append(credit)
                        currentCredit = nil
                    } else if credit.hasScrobbled {
                        lastOverlapEnd = overlapEnd
                        continue
                    } else {
                        currentCredit = nil
                    }
                }

                if currentCredit == nil {
                    if completedScrobbledPlay {
                        guard overlapStart <= entry.startTime + 5 else {
                            lastOverlapEnd = overlapEnd
                            continue
                        }
                        completedScrobbledPlay = false
                    }
                    currentCredit = Credit(startTime: overlapStartTime, endProgress: overlapEnd)
                }
                currentCredit?.accumulatedPlayTime += overlapEnd - overlapStart
                currentCredit?.endProgress = overlapEnd
                if let accumulatedPlayTime = currentCredit?.accumulatedPlayTime {
                    currentCredit?.hasScrobbled = PlaybackScrobbleTracker.meetsThreshold(
                        accumulatedPlayTime: accumulatedPlayTime,
                        duration: duration,
                        thresholds: thresholds
                    )
                }
                lastOverlapEnd = overlapEnd
            }

            if var currentCredit {
                currentCredit.isActiveAtEnd = true
                credits[entry.id, default: []].append(currentCredit)
            }
        }

        return credits
    }

    func scrobbles(
        tracklist: MixTracklist,
        song: Song,
        videoDuration: TimeInterval?,
        thresholds: PlaybackScrobbleTracker.Thresholds
    ) -> [ScrobbleTrack] {
        let credits = self.credits(
            tracklist: tracklist,
            videoDuration: videoDuration,
            thresholds: thresholds
        )

        var scrobbles: [ScrobbleTrack] = []
        for entry in tracklist.entries {
            let duration = tracklist.effectiveDuration(for: entry, videoDuration: videoDuration)
            for credit in credits[entry.id] ?? [] {
                guard credit.hasScrobbled, let startTime = credit.startTime else { continue }

                scrobbles.append(ScrobbleTrack(
                    title: entry.title,
                    artist: entry.artist ?? song.artistsDisplay,
                    album: nil,
                    duration: duration,
                    timestamp: startTime,
                    videoId: song.videoId
                ))
            }
        }
        return scrobbles
    }
}
