import JavaScriptCore
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct QueueInjectionScriptTests {
    @Test("Queue injection confirms only after the target is the actual next queue item")
    func confirmsQueueReadback() throws {
        let context = try #require(self.makeContext(menuAvailableAfterLookup: 1))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video",
                attemptGeneration: 7
            ),
            in: context
        )
        self.runTimersUntilMessage(in: context)

        #expect(context.evaluateScript("messageCount")?.toInt32() == 1)
        #expect(context.evaluateScript("lastMessage.success")?.toBool() == true)
        #expect(context.evaluateScript("lastMessage.reason")?.toString() == "queue-readback-confirmed")
        #expect(context.evaluateScript("lastMessage.videoId")?.toString() == "target-video")
        #expect(context.evaluateScript("lastMessage.attemptGeneration")?.toInt32() == 7)
        #expect(context.evaluateScript("clickedVideoId")?.toString() == "target-video")
        #expect(context.evaluateScript("clickedFallbackVideoId")?.toString() == "target-video")
        #expect(context.evaluateScript("queueVideoIds[1]")?.toString() == "target-video")
        #expect(context.evaluateScript("originalQueueTarget.videoId")?.toString() == "source-video")
        #expect(context.evaluateScript("originalQueueTarget.onEmptyQueue.watchEndpoint.videoId")?.toString() == "source-video")
    }

    @Test("Queue injection waits for the player-bar action menu to mount")
    func waitsForPlayerBarMenu() throws {
        let context = try #require(self.makeContext(menuAvailableAfterLookup: 3))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "delayed-target",
                afterVideoId: "source-video"
            ),
            in: context
        )
        self.runTimersUntilMessage(in: context)

        #expect(context.evaluateScript("menuLookupCount")?.toInt32() ?? 0 >= 3)
        #expect(context.evaluateScript("lastMessage.success")?.toBool() == true)
        #expect(context.evaluateScript("queueVideoIds[1]")?.toString() == "delayed-target")
    }

    @Test("Queue injection uses the native click path without global payload rewriting")
    func usesNativeClickPath() {
        let script = SingletonPlayerWebView.queueInjectionScript(
            videoId: "target-video",
            afterVideoId: "source-video"
        )

        #expect(script.contains("targetItem.click()"))
        #expect(script.contains("queue-readback-confirmed"))
        #expect(!script.contains("app.resolveCommand"))
        #expect(!script.contains("JSON.stringify ="))
    }

    @Test("An already aligned queue is confirmed without clicking Play Next again")
    func alreadyAlignedQueueIsANoOpSuccess() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            clickMode: "duplicateInsert",
            initialQueueVideoIds: ["source-video", "target-video", "autoplay-video"],
            queueCurrentIndex: 0
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )

        #expect(context.evaluateScript("lastMessage.success")?.toBool() == true)
        #expect(context.evaluateScript("lastMessage.reason")?.toString() == "queue-readback-confirmed")
        #expect(context.evaluateScript("clickedVideoId === null")?.toBool() == true)
        #expect(context.evaluateScript("queueVideoIds.length")?.toInt32() == 3)
    }

    @Test("A historical target before the selected source cannot confirm readback")
    func historicalTargetBeforeCurrentSourceDoesNotConfirm() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            clickMode: "noInsert",
            initialQueueVideoIds: ["target-video", "source-video", "other-next"],
            queueCurrentIndex: 1
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )
        self.runTimersUntilMessage(in: context, limit: 200)

        #expect(context.evaluateScript("lastMessage.success")?.toBool() == false)
        #expect(context.evaluateScript("lastMessage.reason")?.toString() == "queue-readback-timeout")
    }

    @Test("Queue readback fails closed when the selected source row is not rendered")
    func missingSelectedSourceRowDoesNotConfirm() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            clickMode: "noInsert",
            initialQueueVideoIds: ["target-video", "history-video"],
            queueCurrentIndex: nil
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )
        self.runTimersUntilMessage(in: context, limit: 200)

        #expect(context.evaluateScript("lastMessage.success")?.toBool() == false)
        #expect(context.evaluateScript("lastMessage.reason")?.toString() == "queue-readback-timeout")
    }

    @Test("Queue readback scans beyond the first forty rendered rows")
    func queueReadbackFindsLateSelectedSource() throws {
        var videoIds = (0 ..< 45).map { "history-\($0)" }
        videoIds.append(contentsOf: ["source-video", "other-next"])
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            initialQueueVideoIds: videoIds,
            queueCurrentIndex: 45
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )
        self.runTimersUntilMessage(in: context)

        #expect(context.evaluateScript("lastMessage.success")?.toBool() == true)
        #expect(context.evaluateScript("queueVideoIds[46]")?.toString() == "target-video")
    }

    @Test("Queue readback resolves a nonzero selected source row")
    func confirmsTargetAfterNonzeroCurrentRow() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            initialQueueVideoIds: ["history-video", "source-video", "other-next"],
            queueCurrentIndex: 1
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )
        self.runTimersUntilMessage(in: context)

        #expect(context.evaluateScript("lastMessage.success")?.toBool() == true)
        #expect(context.evaluateScript("queueVideoIds[2]")?.toString() == "target-video")
    }

    @Test("Queue injection fails closed when readback never shows the target")
    func readbackTimeoutDoesNotConfirmInjection() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            clickMode: "noInsert"
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )
        self.runTimersUntilMessage(in: context, limit: 200)

        #expect(context.evaluateScript("messageCount")?.toInt32() == 1)
        #expect(context.evaluateScript("lastMessage.success")?.toBool() == false)
        #expect(context.evaluateScript("lastMessage.reason")?.toString() == "queue-readback-timeout")
        #expect(context.evaluateScript("queueVideoIds[1]")?.toString() == "autoplay-video")
    }

    @Test("A later duplicate source occurrence cannot falsely confirm stale readback")
    func laterDuplicateSourceDoesNotConfirmStaleQueue() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            clickMode: "noInsert",
            initialQueueVideoIds: ["source-video", "wrong-next", "source-video", "target-video"]
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )
        self.runTimersUntilMessage(in: context, limit: 200)

        #expect(context.evaluateScript("lastMessage.success")?.toBool() == false)
        #expect(context.evaluateScript("lastMessage.reason")?.toString() == "queue-readback-timeout")
        #expect(context.evaluateScript("queueVideoIds[1]")?.toString() == "wrong-next")
    }

    @Test("Queue injection reports a native Play Next click exception")
    func clickExceptionDoesNotConfirmInjection() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            clickMode: "throw"
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )

        #expect(context.evaluateScript("messageCount")?.toInt32() == 1)
        #expect(context.evaluateScript("lastMessage.success")?.toBool() == false)
        #expect(context.evaluateScript("lastMessage.reason")?.toString() == "play-next-click-threw")
        #expect(context.evaluateScript("originalQueueTarget.videoId")?.toString() == "source-video")
    }

    @Test("Queue readback cannot confirm after the active source changes")
    func readbackAfterSourceChangeFailsClosed() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            clickMode: "insertThenSourceChanges"
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )
        self.runTimersUntilMessage(in: context)

        #expect(context.evaluateScript("lastMessage.success")?.toBool() == false)
        #expect(context.evaluateScript("lastMessage.reason")?.toString() == "source-video-changed-before-readback")
        #expect(context.evaluateScript("queueVideoIds[1]")?.toString() == "target-video")
    }

    @Test("Queue injection dismisses the player menu on pre-dispatch failure")
    func dismissesMenuOnMissingPlayNextItem() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            itemLabel: "Add to queue"
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )

        #expect(context.evaluateScript("messageCount")?.toInt32() == 1)
        #expect(context.evaluateScript("lastMessage.reason")?.toString() == "play-next-item-not-found")
        #expect(context.evaluateScript("bodyClickCount")?.toInt32() == 1)
    }

    @Test("Delayed queue injection does not click after the source video changes")
    func rejectsChangedSourceVideo() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            originalVideoId: "source-video",
            currentVideoId: "new-source-video"
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )

        #expect(context.evaluateScript("messageCount")?.toInt32() == 1)
        #expect(context.evaluateScript("lastMessage.success")?.toBool() == false)
        #expect(context.evaluateScript("lastMessage.reason")?.toString() == "source-video-changed")
        #expect(context.evaluateScript("clickedVideoId === null")?.toBool() == true)
    }

    @Test("Queue injection retries while the menu endpoint catches up to the current source")
    func retriesTransientMenuSourceMismatch() throws {
        let context = try #require(self.makeContext(
            menuAvailableAfterLookup: 1,
            originalVideoId: "stale-source-video",
            currentVideoId: "source-video",
            refreshMenuSourceOnTimer: true
        ))

        self.evaluate(
            SingletonPlayerWebView.queueInjectionScript(
                videoId: "target-video",
                afterVideoId: "source-video"
            ),
            in: context
        )
        self.runTimersUntilMessage(in: context)

        #expect(context.evaluateScript("lastMessage.success")?.toBool() == true)
        #expect(context.evaluateScript("clickedVideoId")?.toString() == "target-video")
    }

    // swiftlint:disable:next function_body_length
    private func makeContext(
        menuAvailableAfterLookup: Int,
        clickMode: String = "insertTarget",
        itemLabel: String = "Play next",
        originalVideoId: String = "source-video",
        currentVideoId: String? = nil,
        refreshMenuSourceOnTimer: Bool = false,
        initialQueueVideoIds: [String]? = nil,
        queueCurrentIndex: Int? = 0
    ) -> JSContext? {
        guard let context = JSContext() else { return nil }
        let clickModeLiteral = SingletonPlayerWebView.javaScriptStringLiteral(clickMode)
        let itemLabelLiteral = SingletonPlayerWebView.javaScriptStringLiteral(itemLabel)
        let originalVideoIdLiteral = SingletonPlayerWebView.javaScriptStringLiteral(originalVideoId)
        let currentVideoIdLiteral = SingletonPlayerWebView.javaScriptStringLiteral(currentVideoId ?? originalVideoId)
        let initialQueueVideoIds = initialQueueVideoIds ?? [originalVideoId, "autoplay-video"]
        let initialQueueLiteral = "[" + initialQueueVideoIds
            .map(SingletonPlayerWebView.javaScriptStringLiteral)
            .joined(separator: ",") + "]"
        let queueCurrentIndexLiteral = queueCurrentIndex.map(String.init) ?? "null"
        self.evaluate(
            """
            var window = this;
            var messageCount = 0;
            var lastMessage = null;
            var clickedVideoId = null;
            var clickedFallbackVideoId = null;
            var menuLookupCount = 0;
            var bodyClickCount = 0;
            var clickMode = \(clickModeLiteral);
            var activeVideoId = \(currentVideoIdLiteral);
            var timerID = 0;
            var timerSequence = 0;
            var timers = [];
            var fakeNow = 0;
            var refreshMenuSourceOnTimer = \(refreshMenuSourceOnTimer ? "true" : "false");
            var queueVideoIds = \(initialQueueLiteral);
            var queueCurrentIndexValue = \(queueCurrentIndexLiteral);
            Date.now = function() { return fakeNow; };
            function setTimeout(callback, delay) {
                timerID += 1;
                timerSequence += 1;
                timers.push({
                    id: timerID,
                    callback: callback,
                    dueAt: fakeNow + delay,
                    sequence: timerSequence,
                    cancelled: false
                });
                return timerID;
            }
            function clearTimeout(id) {
                const timer = timers.find(function(candidate) { return candidate.id === id; });
                if (timer) timer.cancelled = true;
            }
            function runNextTimer() {
                timers.sort(function(lhs, rhs) {
                    if (lhs.dueAt !== rhs.dueAt) return lhs.dueAt - rhs.dueAt;
                    return lhs.sequence - rhs.sequence;
                });
                while (timers.length > 0) {
                    const timer = timers.shift();
                    if (!timer.cancelled) {
                        fakeNow = timer.dueAt;
                        if (refreshMenuSourceOnTimer) {
                            originalQueueTarget.videoId = \(currentVideoIdLiteral);
                            originalQueueTarget.onEmptyQueue.watchEndpoint.videoId = \(currentVideoIdLiteral);
                            if (queueCurrentIndexValue !== null) {
                                queueVideoIds[queueCurrentIndexValue] = \(currentVideoIdLiteral);
                            }
                            refreshMenuSourceOnTimer = false;
                        }
                        timer.callback();
                        return true;
                    }
                }
                return false;
            }

            window.webkit = {
                messageHandlers: {
                    singletonPlayer: {
                        postMessage: function(message) {
                            if (message.type === 'QUEUE_INJECTION_RESULT') {
                                messageCount += 1;
                                lastMessage = message;
                            }
                        }
                    }
                }
            };

            var originalQueueTarget = {
                videoId: \(originalVideoIdLiteral),
                onEmptyQueue: { watchEndpoint: { videoId: \(originalVideoIdLiteral) } },
                backingQueuePlaylistId: ''
            };
            var playNextItem = {
                textContent: \(itemLabelLiteral),
                getAttribute: function() { return ''; },
                querySelector: function() { return null; },
                data: {
                    serviceEndpoint: {
                        clickTrackingParams: 'tracking',
                        queueAddEndpoint: {
                            queueTarget: originalQueueTarget,
                            queueInsertPosition: 'INSERT_AFTER_CURRENT_VIDEO',
                            commands: []
                        }
                    }
                },
                click: function() {
                    clickedVideoId = originalQueueTarget.videoId;
                    clickedFallbackVideoId = originalQueueTarget.onEmptyQueue.watchEndpoint.videoId;
                    if (clickMode === 'throw') throw new Error('click failed');
                    if (clickMode === 'insertTarget'
                        || clickMode === 'duplicateInsert'
                        || clickMode === 'insertThenSourceChanges') {
                        const insertedVideoId = clickedVideoId;
                        setTimeout(function() {
                            if (queueCurrentIndexValue !== null) {
                                queueVideoIds.splice(queueCurrentIndexValue + 1, 0, insertedVideoId);
                            } else {
                                queueVideoIds.unshift(insertedVideoId);
                            }
                            if (clickMode === 'insertThenSourceChanges') {
                                activeVideoId = 'advanced-video';
                            }
                        }, 250);
                    }
                }
            };
            var ytmusicPlayer = {
                playerApi: {
                    getVideoData: function() { return { video_id: activeVideoId }; }
                }
            };
            var lastObserver = null;
            function MutationObserver(callback) {
                this.callback = callback;
                lastObserver = this;
            }
            MutationObserver.prototype.observe = function() {};
            MutationObserver.prototype.disconnect = function() {};

            var menuButton = {
                getAttribute: function(name) {
                    return name === 'aria-label' ? 'Action menu' : '';
                },
                click: function() {
                    if (lastObserver) lastObserver.callback([], lastObserver);
                }
            };
            function queueItems() {
                return queueVideoIds.map(function(videoId, index) {
                    return {
                        __kasetIsCurrent: queueCurrentIndexValue === index,
                        data: { playlistItemData: { videoId: videoId } },
                        hasAttribute: function(name) {
                            return this.__kasetIsCurrent && name === 'selected';
                        },
                        getAttribute: function(name) {
                            return this.__kasetIsCurrent && name === 'aria-current' ? 'true' : null;
                        },
                        classList: { contains: function() { return false; } }
                    };
                });
            }
            var document = {
                body: { click: function() { bodyClickCount += 1; } },
                querySelector: function(selector) {
                    if (selector === 'ytmusic-player') return ytmusicPlayer;
                    if (selector === 'ytmusic-player-queue') {
                        return { data: { contents: queueItems().map(function(item) { return item.data; }) } };
                    }
                    if (selector.indexOf('.middle-controls-buttons.ytmusic-player-bar') === 0) {
                        menuLookupCount += 1;
                        return menuLookupCount >= \(menuAvailableAfterLookup) ? menuButton : null;
                    }
                    return null;
                },
                querySelectorAll: function(selector) {
                    if (selector === 'ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer') {
                        return [playNextItem];
                    }
                    if (selector === 'ytmusic-player-bar button') {
                        return menuLookupCount >= \(menuAvailableAfterLookup) ? [menuButton] : [];
                    }
                    if (selector.indexOf('ytmusic-player-queue-item') >= 0) {
                        return queueItems();
                    }
                    return [];
                },
                getElementById: function() { return null; }
            };
            """,
            in: context
        )
        return context
    }

    private func runTimersUntilMessage(in context: JSContext, limit: Int = 100) {
        self.evaluate(
            """
            for (let i = 0; i < \(limit) && messageCount === 0; i += 1) {
                if (!runNextTimer()) break;
            }
            """,
            in: context
        )
    }

    private func evaluate(_ script: String, in context: JSContext) {
        context.exception = nil
        _ = context.evaluateScript(script)
        #expect(context.exception == nil, Comment(rawValue: context.exception?.toString() ?? "Unknown JavaScript error"))
    }
}
