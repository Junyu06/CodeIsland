import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Records nothing and answers every push with success: nothing here reaches
/// a real push service.
private final class AcceptingTransport: PushTransport, @unchecked Sendable {
    func send(_ request: PushHTTPRequest) async -> PushTransportResponse {
        PushTransportResponse(statusCode: 200, body: Data(#"{"code":200,"message":"success"}"#.utf8))
    }
}

/// Attention bugs that predate `AttentionPolicy` and were fixed in it, end to
/// end through AppState: sounds into a sink, pushes into a private suite with
/// one Bark channel, follow-ups on an injected clock.
@MainActor
final class AttentionRegressionTests: XCTestCase {
    private var played: [String] = []
    private var saved: [String: Any?] = [:]
    private let suiteName = "AttentionRegressionTests"
    private var suite: UserDefaults!
    private var now = Date(timeIntervalSinceReferenceDate: 50_000)
    private var pending: [Task<Data, Never>] = []

    private let keys = [
        SettingsKey.soundEnabled, SettingsKey.soundTaskComplete, SettingsKey.soundTaskError,
        SettingsKey.soundApprovalNeeded, SettingsKey.soundPromptSubmit, SettingsKey.soundSessionStart,
        SettingsKey.quietHoursEnabled, SettingsKey.autoMuteWhenAway, SettingsKey.completionNotificationStyle,
        SettingsKey.smartSuppress, SettingsKey.autoExpandOnPermission, SettingsKey.pluginSessionMode,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        played = []
        now = Date(timeIntervalSinceReferenceDate: 50_000)
        pending = []
        SoundManager.shared.playSink = { [weak self] in self?.played.append($0) }
        for key in [SettingsKey.soundEnabled, SettingsKey.soundTaskComplete, SettingsKey.soundTaskError,
                    SettingsKey.soundApprovalNeeded, SettingsKey.soundPromptSubmit, SettingsKey.soundSessionStart] {
            UserDefaults.standard.set(true, forKey: key)
        }
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        UserDefaults.standard.set(false, forKey: SettingsKey.autoMuteWhenAway)
        UserDefaults.standard.set("expand", forKey: SettingsKey.completionNotificationStyle)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)

        // Push settings live in a private suite, never in `.standard`.
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        suite.set(true, forKey: SettingsKey.pushEnabled)
        var bark = PushChannelConfig(kind: .bark)
        bark.enabled = true
        bark.target = "TESTKEY"
        bark.events = PushEventKind.defaultSelection
        suite.set(PushChannelConfig.encodeList([bark]), forKey: SettingsKey.pushChannels)
        let notifier = PushNotifier.shared
        notifier.resetForTesting()
        notifier.defaults = suite
        notifier.transport = AcceptingTransport()
        notifier.presence = { PushPresenceSnapshot(screenLocked: true) }
        notifier.armsCatchUpTimer = false
    }

    override func tearDown() async throws {
        for task in pending { task.cancel() }
        SoundManager.shared.playSink = nil
        SceneMuteMonitor.shared.resetForTesting()
        TerminalVisibilityDetector.probe = .unknown
        let notifier = PushNotifier.shared
        notifier.transport = URLSessionPushTransport.shared
        notifier.presence = { PushPresence.current() }
        notifier.armsCatchUpTimer = true
        notifier.clock = Date.init
        notifier.defaults = .standard
        notifier.resetForTesting()
        suite.removePersistentDomain(forName: suiteName)
        for key in keys {
            if let value = saved[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try await super.tearDown()
    }

    private func event(_ payload: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: payload)))
    }

    private func appStateWithFollowUps() -> AppState {
        let appState = AppState()
        appState.completionAutoCollapseDelay = 600
        let followUps = appState.followUps
        followUps.armsTimer = false
        followUps.clock = { [unowned self] in self.now }
        followUps.intervalProvider = { 60 }
        followUps.isPointerOverPanel = { false }
        followUps.terminalFrontmost = { _ in false }
        followUps.tabVisible = { _ in false }
        return appState
    }

    /// A subagent's StopFailure is filed under its parent's session. Its
    /// error used to be pushed under the parent's name, and the push dedupe's
    /// error shadow (60 s) then swallowed the parent's own completion — the
    /// phone heard "error" and never "done" for a turn that finished fine.
    func testASubagentsFailureDoesNotSwallowItsParentsCompletionPush() throws {
        PushNotifier.shared.clock = { [unowned self] in self.now }
        let appState = appStateWithFollowUps()
        appState.handleEvent(try event(["hook_event_name": "SessionStart", "session_id": "P"]))
        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "P", "prompt": "fan out"]))
        appState.handleEvent(try event(["hook_event_name": "SubagentStart", "session_id": "P", "agent_id": "a1", "agent_type": "Explore"]))
        appState.handleEvent(try event(["hook_event_name": "StopFailure", "session_id": "P", "agent_id": "a1", "error": "overloaded"]))
        XCTAssertNil(PushNotifier.shared.lastDecision, "the subagent's failure is not pushed as the parent's")

        now = now.addingTimeInterval(20)
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "P", "last_assistant_message": "all done"]))
        XCTAssertEqual(appState.sessions["P"]?.lastTurnFailed, false, "the parent's turn finished fine")
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]), "the parent's completion is pushed")
    }
}
