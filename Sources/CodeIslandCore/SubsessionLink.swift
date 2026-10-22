import Foundation

/// A child session and the card it works for: the one internal answer to
/// "whose card is this hook's", whichever agent the child comes from.
///
/// Agents spawn sessions of their own: a Codex subagent thread, a Cursor
/// Agent Task, a pi-subagents child, a plugin firing another agent's hooks
/// (omo in OpenCode). Each kind's resolver reads its own evidence (a declared
/// parent, a transcript path, a rollout's `session_meta`, a shared process)
/// and produces a link; ``SubsessionRouter`` then applies Agent Sub-Sessions
/// to every kind the same way. A new integration plugs in by producing a link.
///
/// Claude Code's own subagents (`agent_id` on the parent's hooks) are not
/// links: the agent already files them under its session.
public struct SubsessionLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The child named its parent (`_parent_session_id`, #378).
        case declared
        /// A Cursor Agent Task: its transcript path names the chat it runs
        /// for, or it shares that chat's IDE process.
        case cursorTask = "cursor"
        /// A Codex subagent thread: its rollout's `session_meta` names the
        /// parent thread, it shares the parent's CLI process, or Codex filed
        /// its hook under the parent itself.
        case codexThread = "codex"
        /// Another agent firing this agent's hooks (`_via_plugin`, #123).
        case pluginProxy = "plugin"

        /// The subagent row label for a folded child whose hook names no
        /// `agent_type`.
        public var defaultAgentType: String {
            switch self {
            case .declared: return "subagent"
            case .cursorTask: return "cursor-subagent"
            case .codexThread: return "default"
            case .pluginProxy: return "subagent"
            }
        }

        /// Whether Merge may fold the child into a parent card the island
        /// does not show yet, which the fold then creates. Only a Cursor
        /// transcript names the parent conversation's own session id, so the
        /// card it would create is the one the parent's hooks land on; for
        /// every other kind an unknown parent is not invented.
        public var mayCreateParentCard: Bool {
            self == .cursorTask
        }
    }

    public let kind: Kind
    /// The card the child's own hooks file under (``HookEvent/sessionId``).
    public let childCardId: String
    /// The id the child goes by as a subagent row of the card it is folded
    /// into.
    public let agentId: String
    /// The card the child works for, by key; it may not exist (yet). nil
    /// when the evidence says the hook is a child's without naming whose
    /// (a plugin proxy with no card of its agent on the island).
    public let parentCardId: String?
    /// The id the parent goes by as a subagent row, for a parent that is a
    /// child itself: Merge folds a grandchild into the card its parent is
    /// folded into.
    public let parentAgentId: String?
    /// The subagent row label the evidence offers; the hook's own
    /// `agent_type` wins, and ``Kind/defaultAgentType`` stands in for both.
    public let agentType: String?
    /// The parent is a guess from a process the two share, not something the
    /// child or its transcript said. Merge and Hide act on such a guess, as
    /// they always have; Show separately does not, since it is the default
    /// and a wrong guess would silence a session the user started.
    public let isInferred: Bool
    /// The agent itself filed the hook under the parent's session, as
    /// subagent ``agentId`` (Codex's own subagent hooks). It already sits
    /// where Merge would put it.
    public let isProviderFolded: Bool

    public init(
        kind: Kind,
        childCardId: String,
        agentId: String,
        parentCardId: String?,
        parentAgentId: String? = nil,
        agentType: String? = nil,
        isInferred: Bool = false,
        isProviderFolded: Bool = false
    ) {
        self.kind = kind
        self.childCardId = childCardId
        self.agentId = agentId
        self.parentCardId = parentCardId
        self.parentAgentId = parentAgentId
        self.agentType = agentType
        self.isInferred = isInferred
        self.isProviderFolded = isProviderFolded
    }
}

/// The Agent Sub-Sessions setting (`pluginSessionMode`).
public enum SubsessionMode: String, Sendable {
    /// A child keeps a card of its own, linked to its parent: quiet, since
    /// its turns are the parent's business.
    case separate
    /// A child folds into its parent's card as a subagent.
    case merge
    /// A child is not shown; a request it is blocked on still surfaces.
    case hide

    /// An unknown setting reads as Show separately, the default.
    public init(setting: String?) {
        self = setting.flatMap(SubsessionMode.init(rawValue:)) ?? .separate
    }
}

/// What the resolvers and the router need to know about the island. AppState
/// answers it in the app; tests hand in a stub, so every resolver runs
/// without one.
public protocol SubsessionContext {
    /// The cards on the island, by key (`AppState.sessions`).
    var cards: [String: SessionSnapshot] { get }
}

/// Lookups over the island's cards that resolving a child's parent needs.
public enum SubsessionCards {
    /// The card filed under `providerSessionId`: its own key, its Codex
    /// Desktop key, or a card that records it as its provider session id.
    public static func cardId(
        forProviderSessionId providerSessionId: String,
        in cards: [String: SessionSnapshot]
    ) -> String? {
        if cards[providerSessionId] != nil {
            return providerSessionId
        }
        let codexAppId = "codexapp:" + providerSessionId
        if cards[codexAppId] != nil {
            return codexAppId
        }
        return cards.first(where: { _, snap in
            snap.providerSessionId == providerSessionId
        })?.key
    }

    /// The card a child session with this subagent id is folded into, if
    /// any. Only rows that are child sessions count (``SubagentState/subsessionKind``):
    /// a Codex parent's own SubagentStart row for a thread whose hooks keep a
    /// card of their own must not pull that thread off it.
    public static func cardHosting(
        foldedSubsession agentId: String,
        in cards: [String: SessionSnapshot]
    ) -> String? {
        cards.first { $0.value.subagents[agentId]?.subsessionKind != nil }?.key
    }
}
