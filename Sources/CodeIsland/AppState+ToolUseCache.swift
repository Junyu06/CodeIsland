import Foundation
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "PermissionDeny")

/// Cached metadata for an in-flight tool_use_id, written on PreToolUse and consumed by
/// downstream PermissionRequest / PostToolUse events.
///
/// This lets us (1) correlate PermissionRequest payloads back to the originating tool
/// invocation even when some providers strip fields on re-emit, (2) drain stale queue
/// entries when the agent moved on (PostToolUse arrives while a PermissionRequest for
/// the same id is still queued), and (3) dedupe duplicate PermissionRequest replays.
struct PreToolUseRecord {
    let sessionId: String
    let toolName: String?
    let toolDescription: String?
    let toolInput: [String: Any]?
    let receivedAt: Date
}

extension AppState {
    /// TTL for cached PreToolUse records. Generous — tool calls may block on user input
    /// or long-running subprocesses; pruning reclaims memory for aborted/abandoned ids.
    static let pendingToolUseTTL: TimeInterval = 900  // 15 minutes

    /// The answer to a held request that decides nothing.
    ///
    /// The island answers for the user only when the user answers. A request
    /// it takes off the queue because its agent got past it gets this, and
    /// the agent goes on as it would without the island:
    /// - Claude Code, Codex and the Claude-format hooks (Qoder, CodeBuddy,
    ///   Trae, custom CLIs) find no `hookSpecificOutput.decision` and keep to
    ///   their own approval prompt; ZCode, whose schema is strict, falls back
    ///   to its own dialog.
    /// - Gemini CLI gets `{}` through the bridge's decision translation: no
    ///   `decision`, so its own policy and confirmation decide.
    /// - pi's, OMP's and OpenClaw's plugins find no `behavior` and fall
    ///   through to the agent's own gate, as when the island is not running;
    ///   OpenCode's plugin sends OpenCode no reply, which keeps its own prompt.
    /// - Nothing of Cursor's, Copilot's or Antigravity's is ever held: the
    ///   bridge prints nothing to a Cursor hook, Copilot sends no permission
    ///   request, and Antigravity's `PreToolUse` is answered `ask` at the edge.
    nonisolated static let noDecisionAnswer = Data("{}".utf8)

    /// Cache a PreToolUse so later PermissionRequest / PostToolUse events carrying the
    /// same tool_use_id can be correlated back to the originating invocation.
    func cachePreToolUseIfApplicable(_ event: HookEvent) {
        guard EventNormalizer.normalize(event.eventName) == "PreToolUse" else { return }
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return }

        pendingToolUses[toolUseId] = PreToolUseRecord(
            sessionId: event.sessionId ?? "default",
            toolName: event.activityLabel,
            toolDescription: event.toolDescription,
            toolInput: event.toolInput,
            receivedAt: Date()
        )
    }

    /// Drop cache entries for a completed tool invocation. If a PermissionRequest for the
    /// same id is still sitting in the queue (e.g. agent moved on after a local timeout),
    /// drain it with a deny so we don't hold the UI hostage to a dead waiter.
    func resolveToolUseIfCompleted(_ event: HookEvent) {
        let normalized = EventNormalizer.normalize(event.eventName)
        guard normalized == "PostToolUse"
                || normalized == "PostToolUseFailure"
                || normalized == "PermissionDenied"
        else { return }
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return }

        pendingToolUses.removeValue(forKey: toolUseId)

        guard let staleIndex = permissionQueue.firstIndex(where: { $0.toolUseId == toolUseId })
        else { return }

        if shouldKeepQueuedPermissionForCompletedEvent(event, normalizedEventName: normalized) {
            return
        }

        let stale = permissionQueue.remove(at: staleIndex)
        log.notice("⚠️ permission deny reason=resolveToolUseIfCompleted session=\(stale.event.sessionId ?? "nil", privacy: .public) toolUseId=\(toolUseId, privacy: .public) tool=\(stale.event.toolName ?? "nil", privacy: .public) triggerEvent=\(normalized, privacy: .public)")
        let denyBody = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        stale.continuation.resume(returning: Data(denyBody.utf8))

        // If the card we were showing was the drained one, advance to the next pending
        // request (or collapse if nothing is left).
        let wasHead = staleIndex == 0
        if wasHead {
            if permissionQueue.isEmpty {
                if case .approvalCard = surface {
                    surface = .collapsed
                }
            } else {
                showNextPending()
            }
        }
    }

    /// What shows an agent got past a request it asked: a tool step of its
    /// own, its turn ending, its user typing again. A new request or question
    /// has enqueue paths of its own.
    private static let movedOnEvents: Set<String> = [
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "UserPromptSubmit"
    ]

    /// Drops the requests with no tool_use_id that `event` shows their agent
    /// already got past (#216).
    ///
    /// Claude Code's and Codex's PermissionRequest carry no tool_use_id, so
    /// nothing correlates one with what follows it: answered in the terminal,
    /// its card stayed up. A later step of the agent that asked is the sign it
    /// moved on — but only of that agent. Subagents share their parent's
    /// session_id and go on working while it waits on the user (a background
    /// one, or several Task agents at once), and a sibling's Read says nothing
    /// about a pending `rm -rf`. Where the step names a tool call, it must be
    /// the request's: another call of the same agent is not this one (#147).
    ///
    /// Nor is the step ever taken for the user's answer. What the user chose
    /// in the terminal is not known here — a denied call is followed by a
    /// prompt just as an approved one is by its PostToolUse — and whoever can
    /// send a hook to the socket can send this step. The request is answered
    /// with no decision (``noDecisionAnswer``), which leaves it to the agent's
    /// own prompt: where it was answered, if its hook is still waiting at all.
    func resolveOrphanPermissionsOnActivity(_ event: HookEvent) {
        let normalized = EventNormalizer.normalize(event.eventName)
        guard Self.movedOnEvents.contains(normalized) else { return }

        let sessionId = event.sessionId ?? "default"
        let stale = permissionQueue.indices.filter { index in
            let request = permissionQueue[index]
            return (request.event.sessionId ?? "default") == sessionId
                && (request.toolUseId?.isEmpty ?? true)
                && Self.step(event, isPastRequest: request.event)
        }
        dropPermissionsTheirAgentGotPast(at: stale, reason: "resolveOrphanPermissionsOnActivity", triggerEvent: normalized)
    }

    /// Whether `step` comes from the agent that asked `request` — the same
    /// subagent, or the main thread for the main thread's — and, where both
    /// name a tool call, is that call.
    nonisolated static func step(_ step: HookEvent, isPastRequest request: HookEvent) -> Bool {
        guard step.agentId == request.agentId else { return false }
        if let tool = step.toolName, let asked = request.toolName, tool != asked {
            return false
        }
        if let input = step.toolInput, let asked = request.toolInput,
           !NSDictionary(dictionary: input).isEqual(to: asked) {
            return false
        }
        return true
    }

    /// Takes requests off the queue that their agent already got past, each
    /// answered with no decision. A card showing one moves on to the next
    /// request, or folds.
    private func dropPermissionsTheirAgentGotPast(at indices: [Int], reason: String, triggerEvent: String) {
        guard !indices.isEmpty else { return }
        let dropped = indices.map { permissionQueue[$0] }
        let droppedIds = Set(dropped.map(\.id))
        let headWasDropped = indices.contains(0)
        permissionQueue.removeAll { droppedIds.contains($0.id) }
        for stale in dropped {
            log.notice("⚠️ permission dropped, no decision reason=\(reason, privacy: .public) session=\(stale.event.sessionId ?? "nil", privacy: .public) toolUseId=\(stale.toolUseId ?? "nil", privacy: .public) tool=\(stale.event.toolName ?? "nil", privacy: .public) triggerEvent=\(triggerEvent, privacy: .public)")
            stale.continuation.resume(returning: Self.noDecisionAnswer)
        }

        // If the card we were showing was a dropped one, advance to the next
        // pending request (or collapse if nothing is left). A card the user
        // opened on a request further down the queue counts too.
        let cardLostItsRequest = surface.approvalSessionId.map { pendingPermission(forSession: $0) == nil } ?? false
        if headWasDropped || cardLostItsRequest {
            if permissionQueue.isEmpty {
                if case .approvalCard = surface {
                    surface = .collapsed
                }
            } else {
                showNextPending()
            }
        }
    }

    /// Remove stale cache entries. Called from the cleanup timer tick.
    func prunePendingToolUses(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-AppState.pendingToolUseTTL)
        pendingToolUses = pendingToolUses.filter { $0.value.receivedAt >= cutoff }
    }

    /// Try to merge this permission request into an existing queue entry for the same
    /// tool_use_id. Returns true when the new arrival was treated as a replay and its
    /// continuation has already been resolved (caller must not enqueue).
    ///
    /// Behavior: the newer continuation replaces the queued one in-place. The older
    /// continuation is denied so Claude's prior waiter doesn't hang; the queue slot and
    /// its position remain the same so the visible card doesn't reshuffle under the user.
    func mergeDuplicatePermissionRequest(_ request: PermissionRequest) -> Bool {
        guard let toolUseId = request.toolUseId, !toolUseId.isEmpty else { return false }
        guard let existingIndex = permissionQueue.firstIndex(where: { $0.toolUseId == toolUseId })
        else { return false }

        let existing = permissionQueue[existingIndex]
        // #169: a shared tool_use_id alone is not enough to call this a replay.
        // Claude Code can emit several *parallel* tool calls (e.g. reading 4
        // files at once); if they carry the same id but different inputs they are
        // distinct requests and each needs its own decision. Treat it as a replay
        // — deny the old waiter, keep the new one in place — only when the tool
        // inputs match. Otherwise let the new request enqueue on its own.
        let existingInput = existing.event.toolInput ?? [:]
        let newInput = request.event.toolInput ?? [:]
        guard NSDictionary(dictionary: existingInput).isEqual(to: NSDictionary(dictionary: newInput)) else {
            return false
        }
        log.notice("⚠️ permission deny reason=mergeDuplicatePermissionRequest session=\(existing.event.sessionId ?? "nil", privacy: .public) toolUseId=\(toolUseId, privacy: .public) tool=\(existing.event.toolName ?? "nil", privacy: .public)")
        let denyBody = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        existing.continuation.resume(returning: Data(denyBody.utf8))
        // Same request, new waiter: it keeps its identity, so its reminders
        // and the card showing it carry on rather than starting over. It now
        // goes with the new waiter's hook; the old one has its answer.
        permissionQueue[existingIndex] = PermissionRequest(
            id: existing.id,
            event: request.event,
            continuation: request.continuation,
            hookConnectionId: request.hookConnectionId
        )
        return true
    }

    func shouldKeepQueuedPermissionForCompletedEvent(_ event: HookEvent, normalizedEventName: String) -> Bool {
        guard normalizedEventName != "PermissionDenied" else { return false }

        let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
            ?? permissionQueue.first(where: { $0.toolUseId == event.toolUseId })
                .flatMap { SessionSnapshot.normalizedSupportedSource($0.event.rawJSON["_source"] as? String) }

        switch source {
        case "trae", "traecn", "traecli":
            return true
        default:
            return false
        }
    }

    /// Backfill tool metadata from the cached PreToolUse when the PermissionRequest
    /// payload is missing fields (observed with some third-party CLIs that re-emit
    /// permission events without replaying the tool input).
    func enrichPermissionRequestFromCache(sessionId: String, event: HookEvent) {
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return }
        guard let record = pendingToolUses[toolUseId] else { return }

        if sessions[sessionId]?.currentTool == nil, let name = record.toolName {
            sessions[sessionId]?.currentTool = name
        }
        if sessions[sessionId]?.toolDescription == nil, let desc = record.toolDescription {
            sessions[sessionId]?.toolDescription = desc
        }
    }
}
