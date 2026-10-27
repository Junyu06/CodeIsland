import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// A compaction Claude Code precomputes for an idle session must not bring
/// back a card the idle sweep already removed as "thinking".
@MainActor
final class AppStateIdleCompactionTests: XCTestCase {
    private func hook(_ payload: [String: Any]) throws -> HookEvent {
        var payload = payload
        payload["session_id"] = "finished-session"
        payload["_source"] = "claude"
        payload["cwd"] = "/tmp/project"
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    func testBackgroundCompactionDoesNotBringBackARemovedCardAsThinking() throws {
        let appState = AppState()

        appState.handleEvent(try hook(["hook_event_name": "PreCompact", "trigger": "auto"]))
        XCTAssertNil(appState.sessions["finished-session"])

        appState.handleEvent(try hook(["hook_event_name": "SubagentStop", "agent_id": "compactor-agent"]))
        XCTAssertEqual(appState.sessions["finished-session"]?.status, .idle)
    }

    func testManualCompactStillOpensACard() throws {
        let appState = AppState()

        appState.handleEvent(try hook(["hook_event_name": "PreCompact", "trigger": "manual"]))

        XCTAssertEqual(appState.sessions["finished-session"]?.status, .processing)
    }
}
