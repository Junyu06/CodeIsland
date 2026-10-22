import Foundation

/// A child session that names the session it works for (#378).
///
/// Some agents run each delegated task as a CLI session of its own: a
/// pi-subagents child is a full pi session in a detached runner, loading the
/// same CodeIsland extension as its parent. Nothing about such a session says
/// "subagent" unless it is told, so the child says so itself:
/// `_parent_session_id` carries the parent's session id, in the same form as
/// `session_id`. Agent Sub-Sessions then applies to it as it does to Codex
/// and Cursor children, and its turns are never mistaken for the user's own.
public enum DeclaredSubsession {
    /// Payload key holding the parent's session id.
    public static let parentKey = "_parent_session_id"
    /// Set on a child's event that was folded into its parent's card.
    public static let mergedKey = "_declared_subagent"
    /// Subagent label for a folded child that names no `agent_type`.
    public static let defaultAgentType = "subagent"

    /// The card key of the parent this payload's session declares, or nil.
    /// Filed like `session_id` (remote and Codex Desktop namespaces), so it
    /// names the parent's card exactly.
    public static func parentSessionId(in raw: [String: Any]) -> String? {
        guard let parent = nonEmptyString(raw[parentKey]) else { return nil }
        // A session cannot be its own parent: a malformed declaration.
        if parent == CursorSubsessionRouter.sessionId(from: raw) { return nil }
        return HookEvent.cardSessionId(forRawSessionId: parent, in: raw)
    }

    /// Whether a hook event is a declared child's, folded into its parent.
    public static func isMergedEvent(_ event: HookEvent) -> Bool {
        (event.rawJSON[mergedKey] as? Bool) == true
    }

    /// Rewrite a child's event onto the card `parentCardId`, as the subagent
    /// `childCardId` of that card.
    ///
    /// Returns false, leaving `raw` untouched, when this payload cannot
    /// address that card: a remote child's event can only land on a card of
    /// the same host, and a Codex Desktop one only on a `codexapp:` card. Nor
    /// can a source whose `agent_id` is not a subagent marker (TRAE) fold.
    @discardableResult
    public static func applyMerge(
        to raw: inout [String: Any],
        parentCardId: String,
        childCardId: String
    ) -> Bool {
        guard HookEvent.agentIdMarksSubagent(source: raw["_source"] as? String),
              let sessionId = payloadSessionId(addressing: parentCardId, in: raw) else {
            return false
        }
        raw["session_id"] = sessionId
        raw["agent_id"] = nonEmptyString(raw["agent_id"]) ?? childCardId
        if nonEmptyString(raw["agent_type"]) == nil {
            raw["agent_type"] = defaultAgentType
        }
        raw[mergedKey] = true
        // It named the parent of the old `session_id`; the event is now the
        // parent card's own, so the declaration no longer applies.
        raw.removeValue(forKey: parentKey)
        return true
    }

    /// The `session_id` that makes this payload file under `cardId`, if any.
    static func payloadSessionId(addressing cardId: String, in raw: [String: Any]) -> String? {
        var candidate = cardId
        if let host = raw["_remote_host_id"] as? String,
           !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let prefix = "remote:\(host):"
            guard cardId.hasPrefix(prefix) else { return nil }
            candidate = String(cardId.dropFirst(prefix.count))
        }
        guard HookEvent.cardSessionId(forRawSessionId: candidate, in: raw) == cardId else {
            return nil
        }
        return candidate
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
