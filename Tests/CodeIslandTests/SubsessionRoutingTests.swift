import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Agent Sub-Sessions the same way for every kind of child session, end to
/// end: hooks go through HookServer's routing and then AppState, as in the
/// app. Show separately keeps a known child on a card of its own that never
/// rings or pops a completion card; a child stays where it is until it ends;
/// Hide never answers a request for the user.
@MainActor
final class SubsessionRoutingTests: XCTestCase {
    private let cursorChat = "e1247fd5-d9a0-48ef-8457-0304606b1833"
    private let cursorTask = "2528cb91-6379-48f2-aff8-40f4b804dafa"
    private let otherChat = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private var played: [String] = []
    private var savedDefaults: [String: Any?] = [:]

    private let watchedKeys = [
        SettingsKey.pluginSessionMode,
        SettingsKey.soundEnabled,
        SettingsKey.soundSessionStart,
        SettingsKey.soundTaskComplete,
        SettingsKey.soundTaskError,
        SettingsKey.soundApprovalNeeded,
        SettingsKey.soundPromptSubmit,
        SettingsKey.quietHoursEnabled,
        SettingsKey.autoMuteWhenAway,
        SettingsKey.smartSuppress,
        SettingsKey.completionNotificationStyle,
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        played = []
        for key in watchedKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        SoundManager.shared.playSink = { [weak self] name in
            self?.played.append(name)
        }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: SettingsKey.soundEnabled)
        defaults.set(true, forKey: SettingsKey.soundSessionStart)
        defaults.set(true, forKey: SettingsKey.soundTaskComplete)
        defaults.set(true, forKey: SettingsKey.soundTaskError)
        defaults.set(true, forKey: SettingsKey.soundApprovalNeeded)
        defaults.set(false, forKey: SettingsKey.soundPromptSubmit)
        defaults.set(false, forKey: SettingsKey.quietHoursEnabled)
        defaults.set(false, forKey: SettingsKey.autoMuteWhenAway)
        defaults.set(false, forKey: SettingsKey.smartSuppress)
        defaults.set("expand", forKey: SettingsKey.completionNotificationStyle)
        defaults.set("separate", forKey: SettingsKey.pluginSessionMode)
    }

    override func tearDown() {
        SoundManager.shared.playSink = nil
        for key in watchedKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    // MARK: - Helpers

    private func setMode(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: SettingsKey.pluginSessionMode)
    }

    private struct Routed {
        let raw: [String: Any]
        let data: Data
        let response: Data?
        var sessionId: String? { raw["session_id"] as? String }
    }

    private func route(_ payload: [String: Any], server: HookServer) throws -> Routed {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let routed = server.routeSubsessionPayloadIfNeededForTesting(data: data)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: routed.processedData) as? [String: Any])
        return Routed(raw: raw, data: routed.processedData, response: routed.responseData)
    }

    /// Route a non-blocking hook and hand it to AppState, as HookServer does.
    @discardableResult
    private func deliver(_ payload: [String: Any], to appState: AppState, server: HookServer) throws -> Routed {
        let routed = try route(payload, server: server)
        if routed.response == nil {
            appState.handleEvent(try XCTUnwrap(HookEvent(from: routed.data)))
        }
        return routed
    }

    // MARK: - Cursor

    func testCursorTaskNamedByItsTranscriptShownSeparatelyIsQuiet() throws {
        let transcript = "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorChat)/\(cursorChat).jsonl"
        let appState = AppState()
        let server = HookServer(appState: appState)
        func cursor(_ event: String, _ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["hook_event_name": event, "session_id": id, "_source": "cursor", "transcript_path": transcript]
                .merging(extra) { _, new in new }
        }
        try deliver(cursor("beforeSubmitPrompt", cursorChat, ["prompt": "run a task"]), to: appState, server: server)
        try deliver(cursor("beforeSubmitPrompt", cursorTask, ["prompt": "task"]), to: appState, server: server)
        try deliver(cursor("stop", cursorTask), to: appState, server: server)
        XCTAssertEqual(appState.sessions[cursorTask]?.parentSessionId, cursorChat)
        XCTAssertNil(appState.justCompletedSessionId)
        XCTAssertEqual(played, [])

        try deliver(cursor("stop", cursorChat), to: appState, server: server)
        XCTAssertEqual(played, ["8bit_complete"])
        XCTAssertEqual(appState.justCompletedSessionId, cursorChat)
    }

    /// A Task folded in by its IDE process stays folded when a second chat on
    /// that process leaves the `_ppid` fallback unable to pick one: its Stop
    /// still closes its row, and no card of its own appears.
    func testCursorTaskFollowsItsRowWhenItsIdeProcessNoLongerSinglesOutItsChat() throws {
        setMode("merge")
        let ppid = 61_001
        let appState = AppState()
        let server = HookServer(appState: appState)
        func card(_ id: String) -> SessionSnapshot {
            var chat = SessionSnapshot()
            chat.source = "cursor"
            chat.status = .running
            chat.cliPid = pid_t(ppid)
            chat.providerSessionId = id
            chat.transcriptPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(id)/\(id).jsonl"
            return chat
        }
        appState.sessions[cursorChat] = card(cursorChat)
        func task(_ event: String) -> [String: Any] {
            ["hook_event_name": event, "session_id": cursorTask, "_source": "cursor", "_ppid": ppid]
        }

        let first = try deliver(task("beforeShellExecution"), to: appState, server: server)
        XCTAssertEqual(first.sessionId, cursorChat)
        XCTAssertEqual(appState.sessions[cursorChat]?.subagents[cursorTask]?.subsessionKind, .cursorTask)

        appState.sessions[otherChat] = card(otherChat)
        let later = try deliver(task("afterShellExecution"), to: appState, server: server)
        XCTAssertEqual(later.sessionId, cursorChat)
        try deliver(task("stop"), to: appState, server: server)
        XCTAssertNil(appState.sessions[cursorTask], "no card of its own")
        XCTAssertNil(appState.sessions[cursorChat]?.subagents[cursorTask])
    }

    /// The Cursor pass runs after any hook while a default-Claude card is on
    /// the island. It leaves a hidden Task's card alone while a request on it
    /// waits, and hides the Task again once the request is answered.
    func testHiddenCursorTasksRequestWaitsThroughTheCursorPass() async throws {
        setMode("hide")
        let previousScanner = AppState.cursorSubagentIndexScanner
        AppState.cursorSubagentIndexScanner = { CursorSubagentTranscriptIndex(pathsBySessionId: [:], builtAt: Date()) }
        defer { AppState.cursorSubagentIndexScanner = previousScanner }

        let appState = AppState()
        var chat = SessionSnapshot()
        chat.source = "cursor"
        chat.status = .running
        chat.transcriptPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorChat)/\(cursorChat).jsonl"
        appState.sessions[cursorChat] = chat
        var claude = SessionSnapshot()
        claude.source = "claude"
        claude.status = .processing
        appState.sessions["claude-session"] = claude
        let server = HookServer(appState: appState)

        let request = try route([
            "hook_event_name": "PermissionRequest", "session_id": cursorTask, "_source": "cursor",
            "transcript_path": "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorChat)/subagents/\(cursorTask).jsonl",
            "tool_name": "Shell", "tool_input": ["command": "ls"],
        ], server: server)
        XCTAssertNil(request.response)
        let event = try XCTUnwrap(HookEvent(from: request.data))
        let task = await startHookRequest { appState.handlePermissionRequest(event, continuation: $0) }

        // Another session's hook runs the Cursor pass.
        appState.handleEvent(try XCTUnwrap(HookEvent(json: [
            "hook_event_name": "PostToolUse", "session_id": "claude-session", "tool_name": "Read",
        ])))
        XCTAssertNotNil(appState.sessions[cursorTask], "its request still waits for the user")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.approvePermission()
        let response = String(decoding: try await awaitValue(of: task), as: UTF8.self)
        XCTAssertTrue(response.contains(#""allow""#), response)
        appState.applyCursorSubsessionModeToKnownSessions()
        XCTAssertNil(appState.sessions[cursorTask], "hidden again once answered")
    }

    // MARK: - Plugin proxies

    /// Hide used to answer a proxy's permission request `allow`. It now goes
    /// back to the agent undecided (`{}`, as with no hook installed), so the
    /// agent asks the user itself; the proxy stays hidden throughout.
    func testHiddenPluginProxyRequestGoesBackToItsAgentUndecided() throws {
        setMode("hide")
        let appState = AppState()
        let server = HookServer(appState: appState)
        func proxy(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["hook_event_name": event, "session_id": "ses_proxy", "_source": "opencode", "_via_plugin": true, "_ppid": 62_001]
                .merging(extra) { _, new in new }
        }

        for payload in [
            proxy("PreToolUse", ["tool_name": "bash"]),
            proxy("PermissionRequest", ["tool_name": "bash", "tool_input": ["command": "rm -rf build"]]),
            proxy("PermissionRequest", [
                "tool_name": "AskUserQuestion",
                "tool_input": ["questions": [["question": "Which?", "options": [["label": "A"]]]]],
            ]),
            proxy("Stop"),
        ] {
            let routed = try route(payload, server: server)
            XCTAssertEqual(routed.response.flatMap { String(data: $0, encoding: .utf8) }, "{}", "\(payload["hook_event_name"]!)")
        }
        XCTAssertNil(appState.sessions["ses_proxy"])
        XCTAssertTrue(appState.permissionQueue.isEmpty)
        XCTAssertEqual(played, [])
    }

    func testMergedPluginProxyJoinsItsAgentsCardAsItsOwnEvents() throws {
        setMode("merge")
        let ppid = 62_002
        let appState = AppState()
        var main = SessionSnapshot()
        main.source = "opencode"
        main.status = .running
        main.cliPid = pid_t(ppid)
        appState.sessions["opencode-main"] = main
        let routed = try route([
            "hook_event_name": "PostToolUse", "session_id": "ses_proxy",
            "_source": "opencode", "_via_plugin": true, "_ppid": ppid,
        ], server: HookServer(appState: appState))
        XCTAssertEqual(routed.sessionId, "opencode-main")
        XCTAssertNil(routed.raw["agent_id"])
    }
}
