import XCTest
@testable import CodeIslandCore

/// Agent Sub-Sessions applied the same way to every kind of child session:
/// each kind's resolver produces a ``SubsessionLink`` and
/// ``SubsessionRouter`` places it.
final class SubsessionRouterTests: XCTestCase {
    private let parent = "parent-session"
    private let child = "child-session"

    // MARK: - Payloads, one per kind of evidence

    private func declared(_ event: String = "PreToolUse") -> [String: Any] {
        ["hook_event_name": event, "session_id": child, "_source": "pi", DeclaredSubsession.parentKey: parent]
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

    // MARK: - A child stays where it is

    func testChildWithACardOfItsOwnKeepsItWhateverTheMode() throws {
        let context = StubSubsessionContext(cards: [parent: subsessionCard(source: "pi"), child: subsessionCard(source: "pi")])
        for mode in [SubsessionMode.merge, .hide] {
            XCTAssertEqual(try placement(declared(), mode, context), .ownCard(linkedTo: parent), "\(mode)")
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

    func testSessionIsNeverItsOwnParent() {
        XCTAssertNil(DeclaredSubsession.link(in: ["session_id": child, DeclaredSubsession.parentKey: child]))
    }

    func testReducerReadsTheRoutersLinkBeforeTheDeclaration() {
        XCTAssertEqual(SubsessionRouter.parentCardId(in: [
            "session_id": child, DeclaredSubsession.parentKey: parent, SubsessionRouter.linkedParentKey: "linked",
        ]), "linked")
        XCTAssertEqual(SubsessionRouter.parentCardId(in: ["session_id": child, DeclaredSubsession.parentKey: parent]), parent)
        XCTAssertNil(SubsessionRouter.parentCardId(in: ["session_id": child, SubsessionRouter.linkedParentKey: " "]))
    }

    func testUnknownSettingReadsAsShowSeparately() {
        XCTAssertEqual(SubsessionMode(setting: nil), .separate)
        XCTAssertEqual(SubsessionMode(setting: "bogus"), .separate)
        XCTAssertEqual(SubsessionMode(setting: "merge"), .merge)
        XCTAssertEqual(SubsessionMode(setting: "hide"), .hide)
    }
}
