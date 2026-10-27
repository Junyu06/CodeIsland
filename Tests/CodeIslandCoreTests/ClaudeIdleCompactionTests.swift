import XCTest
@testable import CodeIslandCore

/// Claude Code precomputes a compaction while a finished session sits idle:
/// PreCompact (trigger "auto"), then the SubagentStop of the agent that ran
/// it, and no Stop after. The card must read as it did before.
final class ClaudeIdleCompactionTests: XCTestCase {
    private let sessionId = "idle-claude-session"

    private func hookEvent(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> HookEvent {
        var payload = payload
        payload["session_id"] = sessionId
        payload["_source"] = "claude"
        payload["cwd"] = "/tmp/project"
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), file: file, line: line)
    }

    private func reduce(
        _ payload: [String: Any],
        _ sessions: inout [String: SessionSnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        _ = reduceEvent(sessions: &sessions, event: try hookEvent(payload, file: file, line: line), maxHistory: 20)
    }

    private let preCompact: [String: Any] = [
        "hook_event_name": "PreCompact",
        "trigger": "auto",
        "custom_instructions": NSNull(),
    ]

    private let compactorStop: [String: Any] = [
        "hook_event_name": "SubagentStop",
        "agent_id": "compactor-agent",
        "stop_hook_active": false,
    ]

    private func finishedTurn() throws -> [String: SessionSnapshot] {
        var sessions: [String: SessionSnapshot] = [:]
        try reduce(["hook_event_name": "UserPromptSubmit", "prompt": "upgrade the engine"], &sessions)
        try reduce(["hook_event_name": "Stop", "last_assistant_message": "Upgrade done."], &sessions)
        XCTAssertEqual(sessions[sessionId]?.status, .idle)
        return sessions
    }

    func testBackgroundCompactionLeavesAFinishedCardIdle() throws {
        var sessions = try finishedTurn()
        let lastActivity = try XCTUnwrap(sessions[sessionId]?.lastActivity)

        try reduce(preCompact, &sessions)
        XCTAssertEqual(sessions[sessionId]?.status, .idle)
        XCTAssertNil(sessions[sessionId]?.toolDescription, "no \"Compacting context…\" on a finished card")
        XCTAssertEqual(sessions[sessionId]?.lastActivity, lastActivity, "background work is not activity")

        try reduce(compactorStop, &sessions)
        XCTAssertEqual(sessions[sessionId]?.status, .idle)
        XCTAssertNil(sessions[sessionId]?.currentTool)
    }

    func testBackgroundCompactionDoesNotBringBackARemovedCardAsThinking() throws {
        // The idle sweep removed the card long before the compaction ran.
        var sessions: [String: SessionSnapshot] = [:]

        try reduce(preCompact, &sessions)
        XCTAssertNil(sessions[sessionId])

        // The stop still closes the agent's id, so late requests from it get
        // no card; the card that holds that is idle.
        try reduce(compactorStop, &sessions)
        XCTAssertEqual(sessions[sessionId]?.status, .idle)
    }

    func testCompactionMidTurnStillShows() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try reduce(["hook_event_name": "UserPromptSubmit", "prompt": "keep going"], &sessions)

        try reduce(preCompact, &sessions)

        XCTAssertEqual(sessions[sessionId]?.status, .processing)
        XCTAssertEqual(sessions[sessionId]?.toolDescription, "Compacting context\u{2026}")
    }

    func testManualCompactOnAFinishedCardStillShows() throws {
        var sessions = try finishedTurn()
        var manual = preCompact
        manual["trigger"] = "manual"

        try reduce(manual, &sessions)

        XCTAssertEqual(sessions[sessionId]?.status, .processing)
        XCTAssertEqual(sessions[sessionId]?.toolDescription, "Compacting context\u{2026}")
    }
}
