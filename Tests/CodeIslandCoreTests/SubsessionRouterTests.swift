import XCTest
@testable import CodeIslandCore

/// Agent Sub-Sessions applied the same way to every kind of child session:
/// each kind's resolver produces a ``SubsessionLink`` and
/// ``SubsessionRouter`` places it.
final class SubsessionRouterTests: XCTestCase {
    private let parent = "parent-session"
    private let child = "child-session"
    private let cursorChat = "e1247fd5-d9a0-48ef-8457-0304606b1833"
    private let cursorTask = "2528cb91-6379-48f2-aff8-40f4b804dafa"

    private var cursorTranscript: String {
        "/Users/u/.cursor/projects/x/agent-transcripts/\(cursorChat)/\(cursorChat).jsonl"
    }

    // MARK: - Payloads, one per kind of evidence

    private func declared(_ event: String = "PreToolUse") -> [String: Any] {
        ["hook_event_name": event, "session_id": child, "_source": "pi", DeclaredSubsession.parentKey: parent]
    }

    private func cursorByTranscript(_ event: String = "beforeReadFile") -> [String: Any] {
        ["hook_event_name": event, "session_id": cursorTask, "_source": "cursor", "transcript_path": cursorTranscript]
    }

    private func cursorByProcess(_ event: String = "beforeReadFile") -> [String: Any] {
        ["hook_event_name": event, "session_id": cursorTask, "_source": "cursor", "_ppid": 4242]
    }

    private func pluginProxy(_ event: String = "PostToolUse") -> [String: Any] {
        ["hook_event_name": event, "session_id": child, "_source": "opencode", "_via_plugin": true, "_ppid": 9090]
    }

    // MARK: - Helpers

    private func link(_ raw: [String: Any], _ context: StubSubsessionContext, file: StaticString = #filePath, line: UInt = #line) throws -> SubsessionLink {
        try XCTUnwrap(SubsessionRouter.link(in: raw, context: context), "no link for \(raw)", file: file, line: line)
    }

    private func placement(
        _ raw: [String: Any],
        _ mode: SubsessionMode,
        _ context: StubSubsessionContext,
        blocking: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SubsessionPlacement {
        SubsessionRouter.placement(
            for: try link(raw, context, file: file, line: line),
            mode: mode,
            cards: context.cards,
            isBlockingRequest: { blocking }
        )
    }

    // MARK: - Every kind × every mode

    func testDeclaredChildInEveryMode() throws {
        let noParent = StubSubsessionContext()
        let withParent = StubSubsessionContext(cards: [parent: subsessionCard(source: "pi")])
        XCTAssertEqual(try placement(declared(), .separate, withParent), .ownCard(linkedTo: parent))
        XCTAssertEqual(try placement(declared(), .merge, withParent), .fold(into: parent))
        XCTAssertEqual(try placement(declared(), .merge, noParent), .ownCard(linkedTo: parent), "an unknown parent is not invented")
        XCTAssertEqual(try placement(declared(), .hide, withParent), .hidden)
        XCTAssertEqual(try placement(declared("PermissionRequest"), .hide, withParent, blocking: true), .ownCard(linkedTo: parent))
    }

    func testCursorTaskNamedByItsTranscriptInEveryMode() throws {
        let context = StubSubsessionContext()
        XCTAssertEqual(try placement(cursorByTranscript(), .separate, context), .ownCard(linkedTo: cursorChat))
        XCTAssertEqual(
            try placement(cursorByTranscript(), .merge, context), .fold(into: cursorChat),
            "the transcript names the chat's own session id: its card may be created"
        )
        XCTAssertEqual(try placement(cursorByTranscript(), .hide, context), .hidden)
    }

    func testCursorTaskFoundByItsIdeProcessInEveryMode() throws {
        var chat = subsessionCard(source: "cursor", status: .running, transcriptPath: cursorTranscript, cliPid: 4242)
        chat.providerSessionId = cursorChat
        let context = StubSubsessionContext(cards: [cursorChat: chat])
        let guess = try link(cursorByProcess(), context)
        XCTAssertTrue(guess.isInferred)
        XCTAssertEqual(guess.parentCardId, cursorChat)
        XCTAssertEqual(try placement(cursorByProcess(), .separate, context), .unchanged, "Show separately does not act on a guess")
        XCTAssertEqual(try placement(cursorByProcess(), .merge, context), .fold(into: cursorChat))
        XCTAssertEqual(try placement(cursorByProcess(), .hide, context), .hidden)
    }

    func testPluginProxyInEveryMode() throws {
        let alone = StubSubsessionContext()
        let withAgent = StubSubsessionContext(cards: [
            "opencode-main": subsessionCard(source: "opencode", status: .running, cliPid: 9090),
        ])
        XCTAssertEqual(try link(pluginProxy(), withAgent).parentCardId, "opencode-main")
        XCTAssertEqual(try placement(pluginProxy(), .separate, withAgent), .unchanged, "the agent's card is only a guess")
        XCTAssertEqual(try placement(pluginProxy(), .merge, withAgent), .fold(into: "opencode-main"))
        XCTAssertEqual(try placement(pluginProxy(), .merge, alone), .unchanged)
        XCTAssertEqual(try placement(pluginProxy(), .hide, alone), .hidden, "a proxy is hidden even when its agent has no card")
        // Answered `{}`: undecided, so the agent asks the user itself (#165).
        for context in [alone, withAgent] {
            XCTAssertEqual(try placement(pluginProxy("PermissionRequest"), .hide, context, blocking: true), .hidden)
        }
        // A card of its own does not bring it back in Hide.
        withAgent.cards[child] = subsessionCard(source: "opencode")
        XCTAssertEqual(try placement(pluginProxy(), .hide, withAgent), .hidden)
    }

    func testHookOfASessionNobodySpawnedHasNoLink() {
        let context = StubSubsessionContext()
        XCTAssertNil(SubsessionRouter.link(in: ["hook_event_name": "Stop", "session_id": parent], context: context))
        XCTAssertNil(SubsessionRouter.link(in: [
            "hook_event_name": "Stop", "session_id": cursorChat, "_source": "cursor", "transcript_path": cursorTranscript,
        ], context: context))
    }

    // MARK: - A child stays where it is

    func testChildWithACardOfItsOwnKeepsItWhateverTheMode() throws {
        let context = StubSubsessionContext(cards: [parent: subsessionCard(source: "pi"), child: subsessionCard(source: "pi")])
        for mode in [SubsessionMode.merge, .hide] {
            XCTAssertEqual(try placement(declared(), mode, context), .ownCard(linkedTo: parent), "\(mode)")
        }
    }

    func testFoldedChildFollowsItsRowWhateverTheModeOrEvidence() throws {
        var host = subsessionCard(source: "cursor", status: .running)
        var row = SubagentState(agentId: cursorTask, agentType: "cursor-subagent")
        row.subsessionKind = .cursorTask
        host.subagents[cursorTask] = row
        // Two chats on the IDE process: the `_ppid` fallback can no longer
        // single one out, but the Task already lives on `host`.
        let context = StubSubsessionContext(cards: [
            "chat-a": host,
            "chat-b": subsessionCard(source: "cursor", status: .running, cliPid: 4242),
            "chat-c": subsessionCard(source: "cursor", status: .running, cliPid: 4242),
        ])
        for mode in [SubsessionMode.separate, .merge, .hide] {
            XCTAssertEqual(try placement(cursorByProcess(), mode, context), .fold(into: "chat-a"), "\(mode)")
        }
    }

    func testGrandchildFoldsIntoTheCardItsParentIsFoldedInto() throws {
        var root = subsessionCard(source: "pi")
        var folded = SubagentState(agentId: parent, agentType: "worker")
        folded.subsessionKind = .declared
        root.subagents[parent] = folded
        let context = StubSubsessionContext(cards: ["root": root])
        XCTAssertEqual(try placement(declared(), .merge, context), .fold(into: "root"))
    }

    // MARK: - The rewrite

    func testPluginProxyJoinsItsAgentsCardAsItsOwnEvents() throws {
        let context = StubSubsessionContext(cards: [
            "opencode-main": subsessionCard(source: "opencode", status: .running, cliPid: 9090),
        ])
        var raw = pluginProxy("Stop")
        XCTAssertEqual(
            SubsessionRouter.route(&raw, link: try link(raw, context), mode: .merge, cards: context.cards, isBlockingRequest: { false }),
            .rewritten
        )
        XCTAssertEqual(raw["session_id"] as? String, "opencode-main")
        XCTAssertNil(raw["agent_id"], "omo mirrors the session's own turn: no subagent row waiting on a Stop")
        XCTAssertNil(raw[SubsessionRouter.foldedKey])
    }

    func testChildOnItsOwnCardIsLinkedToItsParent() throws {
        var raw: [String: Any] = ["hook_event_name": "Stop", "session_id": child, "_source": "codex"]
        let codexLink = SubsessionLink(kind: .codexThread, childCardId: child, agentId: child, parentCardId: parent)
        XCTAssertEqual(
            SubsessionRouter.route(&raw, link: codexLink, mode: .separate, cards: [:], isBlockingRequest: { false }),
            .rewritten
        )
        XCTAssertEqual(raw["session_id"] as? String, child)
        XCTAssertEqual(SubsessionRouter.parentCardId(in: raw), parent)

        // A declared child already says so: nothing to rewrite.
        var pi = declared("Stop")
        XCTAssertEqual(
            SubsessionRouter.route(&pi, link: try link(pi, StubSubsessionContext()), mode: .separate, cards: [:], isBlockingRequest: { false }),
            .unchanged
        )
    }

    func testFoldThePayloadCannotAddressKeepsTheChildOnItsOwnLinkedCard() throws {
        // A Codex Desktop thread can only land on a `codexapp:` card.
        var raw: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": child, "_source": "codex", "_term_bundle": "com.openai.codex",
        ]
        let link = SubsessionLink(kind: .codexThread, childCardId: "codexapp:\(child)", agentId: child, parentCardId: "cli-parent")
        XCTAssertEqual(
            SubsessionRouter.route(&raw, link: link, mode: .merge, cards: ["cli-parent": subsessionCard(source: "codex")], isBlockingRequest: { false }),
            .rewritten
        )
        XCTAssertEqual(raw["session_id"] as? String, child)
        XCTAssertNil(raw["agent_id"])
        XCTAssertEqual(raw[SubsessionRouter.linkedParentKey] as? String, "cli-parent")
    }

    // MARK: - Resolution order

    func testDeclaredParentBeatsEveryOtherResolver() throws {
        var raw = cursorByTranscript()
        raw[DeclaredSubsession.parentKey] = parent
        XCTAssertEqual(try link(raw, StubSubsessionContext()).kind, .declared)
    }

    func testSessionIsNeverItsOwnParent() {
        // A Task card that reused the chat's id as its provider session id.
        var task = subsessionCard(source: "cursor")
        task.providerSessionId = cursorChat
        let context = StubSubsessionContext(cards: [cursorTask: task])
        XCTAssertEqual(SubsessionRouter.link(in: cursorByTranscript(), context: context)?.parentCardId, cursorChat)
        XCTAssertNil(DeclaredSubsession.link(in: ["session_id": child, DeclaredSubsession.parentKey: child]))
    }

    func testReducerReadsTheRoutersLinkBeforeTheDeclaration() {
        XCTAssertEqual(SubsessionRouter.parentCardId(in: [
            "session_id": child, DeclaredSubsession.parentKey: parent, SubsessionRouter.linkedParentKey: "linked",
        ]), "linked")
        XCTAssertEqual(SubsessionRouter.parentCardId(in: ["session_id": child, DeclaredSubsession.parentKey: parent]), parent)
        XCTAssertNil(SubsessionRouter.parentCardId(in: ["session_id": child, SubsessionRouter.linkedParentKey: " "]))
    }

    func testProcessIdOutsidePidRangeIsIgnored() {
        XCTAssertEqual(SubsessionRouter.positivePpid(in: ["_ppid": "4242"]), 4242)
        XCTAssertEqual(SubsessionRouter.positivePpid(in: ["_ppid": NSNumber(value: 4242)]), 4242)
        XCTAssertNil(SubsessionRouter.positivePpid(in: ["_ppid": "99999999999"]))
        XCTAssertNil(SubsessionRouter.positivePpid(in: ["_ppid": NSNumber(value: Int64(1) << 40)]))
        XCTAssertNil(SubsessionRouter.positivePpid(in: ["_ppid": 0]))
        // A malformed one never reaches a PID comparison, which trapped on it.
        let context = StubSubsessionContext(cards: [
            cursorChat: subsessionCard(source: "cursor", status: .running, cliPid: 4242),
            parent: subsessionCard(source: "codex", status: .running, cliPid: 4242),
        ])
        for source in ["cursor", "codex"] {
            XCTAssertNil(SubsessionRouter.link(in: [
                "hook_event_name": "PreToolUse", "session_id": cursorTask, "_source": source, "_ppid": "99999999999",
            ], context: context), source)
        }
    }

    func testUnknownSettingReadsAsShowSeparately() {
        XCTAssertEqual(SubsessionMode(setting: nil), .separate)
        XCTAssertEqual(SubsessionMode(setting: "bogus"), .separate)
        XCTAssertEqual(SubsessionMode(setting: "merge"), .merge)
        XCTAssertEqual(SubsessionMode(setting: "hide"), .hide)
    }
}
