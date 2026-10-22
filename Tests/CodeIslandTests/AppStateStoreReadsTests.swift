import XCTest
import Darwin
@testable import CodeIsland
@testable import CodeIslandCore

/// The reads of an agent's own store AppState makes for a card it shows
/// (`SessionStoreReaders`) run off the main actor: a hook or a cleanup tick
/// never waits on them, and what they find lands on the card afterwards.
@MainActor
final class AppStateStoreReadsTests: XCTestCase {
    private func event(_ name: String, sessionId: String = "s", source: String = "claude",
                       extra: [String: Any] = [:]) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId,
            "_source": source,
            "cwd": "/tmp/store-reads",
        ]
        payload.merge(extra) { _, new in new }
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    /// Readers that find nothing, so a test only exercises the one it installs.
    private func appStateReadingNothing() -> AppState {
        let appState = AppState()
        appState.storeReaders = SessionStoreReaders(
            title: { _ in nil },
            model: { _, _ in nil },
            nativeAppFinishedTurn: { _, _ in nil },
            cursorYoloMode: { false }
        )
        return appState
    }

    func testProviderTitleIsReadOffTheMainActorAndTheNewestLookupLands() async throws {
        let appState = appStateReadingNothing()
        let probe = StoreReadProbe()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        appState.storeReaders.title = { lookup in
            if probe.record() == 1 {
                _ = release.wait(timeout: .now() + asyncTestTimeout)
            }
            return ResolvedSessionTitle(title: "title of \(lookup.cwd ?? "?")", source: .claudeAiTitle)
        }

        appState.handleEvent(try event("UserPromptSubmit", extra: ["cwd": "/tmp/one", "prompt": "hi"]))
        await waitUntil("the first lookup never started") { probe.calls == 1 }
        appState.handleEvent(try event("PreToolUse", extra: ["cwd": "/tmp/two", "tool_name": "Bash"]))
        appState.handleEvent(try event("PostToolUse", extra: ["cwd": "/tmp/three", "tool_name": "Bash"]))
        XCTAssertNil(appState.sessions["s"]?.sessionTitle, "the hooks did not wait for the lookup")

        release.signal()
        await waitUntil("the newest lookup's title never landed") {
            appState.sessions["s"]?.sessionTitle == "title of /tmp/three"
        }
        XCTAssertEqual(appState.sessions["s"]?.sessionTitleSource, .claudeAiTitle)
        XCTAssertEqual(probe.calls, 2, "the lookups asked for during a read run as one, the newest")
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testModelIsReadOffTheMainActorOneReadAtATime() async throws {
        let appState = appStateReadingNothing()
        let probe = StoreReadProbe()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        appState.storeReaders.model = { _, _ in
            probe.record()
            _ = release.wait(timeout: .now() + asyncTestTimeout)
            return "claude-opus-5-5"
        }

        appState.handleEvent(try event("UserPromptSubmit", extra: ["prompt": "hi"]))
        await waitUntil("the read never started") { probe.calls == 1 }
        appState.handleEvent(try event("PreToolUse", extra: ["tool_name": "Bash"]))
        XCTAssertNil(appState.sessions["s"]?.model, "the hooks did not wait for the read")

        release.signal()
        await waitUntil("the model never landed") { appState.sessions["s"]?.model == "claude-opus-5-5" }
        XCTAssertEqual(probe.calls, 1, "one read per card at a time")
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testAModelAHookSuppliesWhileTheReadRunsIsKept() async throws {
        let appState = appStateReadingNothing()
        let probe = StoreReadProbe()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        appState.storeReaders.model = { _, _ in
            probe.record()
            _ = release.wait(timeout: .now() + asyncTestTimeout)
            return "claude-opus-5-5"
        }

        appState.handleEvent(try event("UserPromptSubmit", extra: ["prompt": "hi"]))
        await waitUntil("the read never started") { probe.calls == 1 }
        appState.handleEvent(try event("SessionStart", extra: ["source": "resume", "model": "claude-sonnet-5"]))
        XCTAssertEqual(appState.sessions["s"]?.model, "claude-sonnet-5")

        release.signal()
        await waitUntil("the read never landed") { !appState.modelReadsInFlight.contains("s") }
        XCTAssertEqual(appState.sessions["s"]?.model, "claude-sonnet-5", "the hook's model wins")
    }

    func testNativeAppTurnEndIsReadOffTheMainActorAndSettlesTheCard() async throws {
        let appState = appStateReadingNothing()
        let probe = StoreReadProbe()
        let lastActivity = Date().addingTimeInterval(-10)
        appState.storeReaders.nativeAppFinishedTurn = { _, _ in
            probe.record()
            return lastActivity.addingTimeInterval(1)
        }
        let card = try watchedThinkingQoderCard(in: appState, lastActivity: lastActivity)
        defer { appState.processMonitor.stop("q") }

        appState.checkNativeAppTurnEnded(sessionId: "q", session: card, settleTime: 3)
        XCTAssertEqual(appState.sessions["q"]?.status, .processing, "the tick did not wait for the read")
        await waitUntil("the turn's end never settled the card") { appState.sessions["q"]?.status == .idle }
        XCTAssertEqual(probe.calls, 1)
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testANativeAppTurnEndBeforeTheCardsLastActivityLeavesItThinking() async throws {
        let appState = appStateReadingNothing()
        let lastActivity = Date().addingTimeInterval(-10)
        appState.storeReaders.nativeAppFinishedTurn = { _, _ in lastActivity.addingTimeInterval(-5) }
        let card = try watchedThinkingQoderCard(in: appState, lastActivity: lastActivity)
        defer { appState.processMonitor.stop("q") }

        appState.checkNativeAppTurnEnded(sessionId: "q", session: card, settleTime: 3)
        await waitUntil("the read never landed") { !appState.nativeAppTurnReadsInFlight.contains("q") }
        XCTAssertEqual(appState.sessions["q"]?.status, .processing)
    }

    func testCursorYoloModeIsReadOffTheMainActorOncePerCard() async throws {
        let appState = appStateReadingNothing()
        let probe = StoreReadProbe()
        appState.storeReaders.cursorYoloMode = {
            probe.record()
            return true
        }

        appState.handleEvent(try event("UserPromptSubmit", sessionId: "c", source: "cursor", extra: ["prompt": "hi"]))
        appState.handleEvent(try event("PreToolUse", sessionId: "c", source: "cursor", extra: ["tool_name": "Shell"]))
        await waitUntil("the YOLO setting never landed") { appState.sessions["c"]?.isYoloMode == true }
        appState.handleEvent(try event("PostToolUse", sessionId: "c", source: "cursor", extra: ["tool_name": "Shell"]))
        XCTAssertEqual(probe.calls, 1, "read once per card")
        XCTAssertFalse(probe.ranOnMainThread)
    }

    /// A Qoder IDE card thinking with no tool, its exit watched on this test
    /// process (alive for as long as the test runs).
    private func watchedThinkingQoderCard(in appState: AppState, lastActivity: Date) throws -> SessionSnapshot {
        var card = SessionSnapshot()
        card.source = "qoder"
        card.termBundleId = "com.qoder.ide"
        card.status = .processing
        card.lastActivity = lastActivity
        XCTAssertTrue(card.isNativeAppMode)
        appState.sessions["q"] = card
        let me = try XCTUnwrap(ProcessTable.liveProcessIdentity(for: getpid()))
        XCTAssertTrue(appState.processMonitor.watch(sessionId: "q", process: me) {})
        return card
    }
}

private final class StoreReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _ranOnMainThread = false

    /// Counts a read; returns its number (1 for the first).
    @discardableResult
    func record() -> Int {
        lock.withLock {
            _calls += 1
            if Thread.isMainThread { _ranOnMainThread = true }
            return _calls
        }
    }

    var calls: Int { lock.withLock { _calls } }
    var ranOnMainThread: Bool { lock.withLock { _ranOnMainThread } }
}
