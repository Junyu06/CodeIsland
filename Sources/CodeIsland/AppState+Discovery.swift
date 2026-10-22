import AppKit
import CodeIslandCore

/// AppState's side of session discovery: starting it, and integrating the
/// sessions each scan finds (`SessionDiscoveryCoordinator` runs the scans
/// off the main actor) into the cards.
extension AppState {
    func startSessionDiscovery() {
        startCleanupTimer()
        // Restore persisted sessions before process scan (deduped by scan)
        restoreSessions()

        // Initial scan for already-running sessions, respecting per-source toggles.
        discovery.requestScan()
        // Watch all known session-store roots so discovery keeps working when hooks are missed.
        discovery.startProjectsWatcher()
    }

    /// Re-arm discovery after the watched roots changed — an extra config dir
    /// was added, removed or paused in Settings → Hooks — and rescan at once so
    /// sessions already running under a newly added root show up.
    func restartProjectsWatcher() {
        discovery.restartProjectsWatcher()
    }

    /// Provider thread IDs are authoritative when both sides have one. Two
    /// native Codex Desktop threads can legitimately share a source and CWD
    /// while having no PID, so they must not be collapsed into one card merely
    /// because the generic discovery heuristic sees the same project path.
    nonisolated static func providerSessionIdentifiersMayRepresentSameSession(
        existing: String?,
        discovered: String?
    ) -> Bool {
        guard let discovered, !discovered.isEmpty else { return true }
        guard let existing, !existing.isEmpty else { return false }
        return existing == discovered
    }

    /// Native-app and CLI discoveries are separate namespaces even when they
    /// share the same provider and working directory. In particular, a Codex
    /// CLI rollout has no native host bundle and must not be folded into a
    /// Codex Desktop card left by state-database discovery.
    nonisolated static func discoveryAppModesMayRepresentSameSession(
        existingIsNativeAppMode: Bool,
        discoveredTermBundleId: String?
    ) -> Bool {
        existingIsNativeAppMode == (discoveredTermBundleId != nil)
    }

    /// Completed Codex subagents are transient workers, not idle top-level
    /// sessions. Their spawn-edge row may remain `open`, so transcript lifecycle
    /// is the reliable signal for removing them from the island.
    nonisolated static func isCompletedCodexSubagentDiscovery(
        source: String,
        parentSessionId: String?,
        status: AgentStatus?
    ) -> Bool {
        source == "codex"
            && parentSessionId?.isEmpty == false
            && status == .idle
    }

    /// Update existing session's messages from discovered transcript data.
    private func backfillSessionMessages(sessionId: String, from info: DiscoveredSession) -> Bool {
        guard var session = sessions[sessionId], !info.recentMessages.isEmpty else { return false }
        guard info.modifiedAt >= session.lastActivity || session.recentMessages.isEmpty else {
            return false
        }
        var mutated = false
        let messagesChanged = session.recentMessages.count != info.recentMessages.count ||
            zip(session.recentMessages, info.recentMessages).contains { $0.isUser != $1.isUser || $0.text != $1.text }
        if messagesChanged {
            session.recentMessages = info.recentMessages
            mutated = true
        }
        if let lastUser = info.recentMessages.last(where: { $0.isUser }),
           session.lastUserPrompt != lastUser.text {
            session.lastUserPrompt = lastUser.text
            mutated = true
        }
        if let lastAssistant = info.recentMessages.last(where: { !$0.isUser }),
           session.lastAssistantMessage != lastAssistant.text {
            session.lastAssistantMessage = lastAssistant.text
            mutated = true
        }
        if mutated {
            sessions[sessionId] = session
        }
        return mutated
    }

    /// Merge discovered sessions into current state (skip already-known ones)
    func integrateDiscovered(_ discovered: [DiscoveredSession]) {
        var didMutate = false
        for info in discovered {
            if shouldSuppressClosedCodexDesktopDiscovery(info) {
                continue
            }
            if isSupersededGrokDiscovery(info) {
                continue
            }
            if routeDiscoveredSubsessionIfNeeded(info) {
                didMutate = true
                continue
            }

            if Self.isCompletedCodexSubagentDiscovery(
                source: info.source,
                parentSessionId: info.parentSessionId,
                status: info.status
            ), !hasWaitingRequest(onCard: info.sessionId) {
                if sessions[info.sessionId] != nil {
                    removeSession(info.sessionId)
                    didMutate = true
                }
                continue
            }

            // Session already known — try to update PID and attach monitor.
            // Discovery PIDs are heuristic (matched by CWD), so when the session already
            // has a known-good alive PID that differs from discovery, we trust the existing
            // one for both cliPid and monitor to avoid cross-session contamination.
            if sessions[info.sessionId] != nil {
                if applyDiscoveredRuntimeState(info, to: info.sessionId) {
                    didMutate = true
                }
                if let pid = info.pid, pid > 0 {
                    let existingPid = sessions[info.sessionId]?.cliPid ?? 0
                    let existingProcess = resolvedSessionProcessIdentity(for: info.sessionId)
                    let existingAlive = existingProcess.map(ProcessTable.isLiveProcess) ?? false
                    if existingAlive && existingPid != pid {
                        // Existing PID is alive and different — discovery PID is unreliable.
                    } else {
                        // No existing PID, or it's dead, or it matches — safe to use discovery PID.
                        if !existingAlive, let process = ProcessTable.liveProcessIdentity(for: pid) {
                            setSessionProcessIdentity(process, for: info.sessionId)
                            didMutate = true
                        }
                    }
                }
                if backfillSessionMessages(sessionId: info.sessionId, from: info) {
                    didMutate = true
                }
                if applyDiscoveredMetadata(info, to: info.sessionId) {
                    didMutate = true
                }
                if linkDiscoveredChild(info) {
                    didMutate = true
                }
                attachTranscriptTailerIfNeeded(sessionId: info.sessionId)
                tryMonitorSession(info.sessionId)
                refreshProviderTitle(
                    for: info.sessionId,
                    providerSessionId: info.providerSessionId ?? info.sessionId
                )
                continue
            }

            // Dedup: if a hook-created session already exists with same source + cwd + pid,
            // skip the discovered one to avoid duplicate entries (e.g. Codex hooks vs
            // file-based discovery produce different session IDs for the same process).
            // Only dedup when PID matches (or discovered has no PID), so concurrent
            // sessions in the same repo aren't incorrectly merged.
            // Never merge a discovery (CLI) session with an existing native app session —
            // they're fundamentally different even if they share source + cwd.
            let duplicateKey = sessions.first(where: { (_, existing) in
                guard existing.source == info.source,
                      existing.cwd != nil, existing.cwd == info.cwd else { return false }
                guard Self.discoveryAppModesMayRepresentSameSession(
                    existingIsNativeAppMode: existing.isNativeAppMode,
                    discoveredTermBundleId: info.termBundleId
                ) else { return false }
                guard Self.providerSessionIdentifiersMayRepresentSameSession(
                    existing: existing.providerSessionId,
                    discovered: info.providerSessionId
                ) else { return false }
                // Don't merge CLI discovery into a stale native app session whose app has quit —
                // the PID was likely reattached incorrectly. If the native app IS running, allow merge.
                if existing.isNativeAppMode,
                   let bid = existing.termBundleId,
                   !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bid }) {
                    return false
                }
                // If we have PIDs for both and the existing one is still alive, they must match.
                // Dead persisted PIDs should not block dedup / reattachment.
                if let discoveredPid = info.pid, let existingPid = existing.cliPid,
                   discoveredPid != existingPid,
                   ProcessTable.isLiveProcess(ProcessIdentity(pid: existingPid, startTime: existing.cliStartTime)) { return false }
                return true
            })?.key

            if let existingKey = duplicateKey {
                if applyDiscoveredRuntimeState(info, to: existingKey) {
                    didMutate = true
                }
                // Same guard as above: don't let unreliable discovery PID contaminate
                // an existing session that has a known-good alive PID.
                if let pid = info.pid, pid > 0 {
                    let existingPid = sessions[existingKey]?.cliPid ?? 0
                    let existingProcess = resolvedSessionProcessIdentity(for: existingKey)
                    let existingAlive = existingProcess.map(ProcessTable.isLiveProcess) ?? false
                    if existingAlive && existingPid != pid {
                    } else {
                        if !existingAlive, let process = ProcessTable.liveProcessIdentity(for: pid) {
                            setSessionProcessIdentity(process, for: existingKey)
                            didMutate = true
                        }
                    }
                }
                if backfillSessionMessages(sessionId: existingKey, from: info) {
                    didMutate = true
                }
                if applyDiscoveredMetadata(info, to: existingKey) {
                    didMutate = true
                }
                attachTranscriptTailerIfNeeded(sessionId: existingKey)
                tryMonitorSession(existingKey)
                refreshProviderTitle(
                    for: existingKey,
                    providerSessionId: info.providerSessionId ?? info.sessionId
                )
                continue
            }

            var session = SessionSnapshot(startTime: info.modifiedAt)
            session.cwd = info.cwd
            session.model = info.model
            session.ttyPath = info.tty
            session.recentMessages = info.recentMessages
            session.source = info.source
            session.status = info.status ?? .idle
            session.lastActivity = info.modifiedAt
            session.termBundleId = info.termBundleId
            if let pid = info.pid, let process = ProcessTable.liveProcessIdentity(for: pid) {
                session.cliPid = process.pid
                session.cliStartTime = process.startTime
            } else {
                session.cliPid = info.pid
            }
            session.providerSessionId = SessionTitleStore.supports(provider: info.source)
                ? (info.providerSessionId ?? info.sessionId)
                : nil
            if let last = info.recentMessages.last(where: { $0.isUser }) {
                session.lastUserPrompt = last.text
            }
            if let last = info.recentMessages.last(where: { !$0.isUser }) {
                session.lastAssistantMessage = last.text
            }
            session.transcriptPath = info.transcriptPath
            session.parentSessionId = discoveredParentCardId(info)
            sessions[info.sessionId] = session
            refreshProviderTitle(
                for: info.sessionId,
                providerSessionId: info.providerSessionId ?? info.sessionId
            )
            tryMonitorSession(info.sessionId)
            attachTranscriptTailerIfNeeded(sessionId: info.sessionId)
            didMutate = true
        }
        if applyCodexSubsessionModeToKnownSessions() {
            didMutate = true
        }
        if applyCursorSubsessionModeToKnownSessions() {
            didMutate = true
        }
        if didMutate && activeSessionId == nil {
            activeSessionId = sessions.keys.sorted().first
        }
        if didMutate {
            scheduleSave()
        }
        refreshDerivedState()
    }

    private func shouldSuppressClosedCodexDesktopDiscovery(_ info: DiscoveredSession) -> Bool {
        guard info.source == "codex",
              info.termBundleId == Self.codexAppBundleId,
              let providerSessionId = info.providerSessionId,
              let closedAt = closedCodexAppThreads[providerSessionId] else {
            return false
        }
        if info.modifiedAt <= closedAt {
            return true
        }
        // A terminal flush may land just after `thread/closed`; only a newer
        // processing lifecycle is evidence that the thread genuinely resumed.
        guard info.status == .processing else { return true }
        closedCodexAppThreads.removeValue(forKey: providerSessionId)
        return false
    }

    /// Apply runtime fields that filesystem/state-DB discovery can know more
    /// accurately than a stale restored snapshot. Interactive approval/question
    /// states remain authoritative until their owning channel resolves them.
    @discardableResult
    private func applyDiscoveredRuntimeState(_ info: DiscoveredSession, to sessionId: String) -> Bool {
        guard var session = sessions[sessionId] else { return false }
        var mutated = false
        let canApplyStatus = info.modifiedAt >= session.lastActivity

        if info.modifiedAt > session.lastActivity {
            session.lastActivity = info.modifiedAt
            mutated = true
        }
        if let bundleId = info.termBundleId,
           (canApplyStatus || session.termBundleId == nil),
           session.termBundleId != bundleId {
            session.termBundleId = bundleId
            mutated = true
        }
        if let discoveredStatus = info.status,
           canApplyStatus,
           session.status != .waitingApproval,
           session.status != .waitingQuestion,
           session.status != discoveredStatus {
            session.status = discoveredStatus
            if discoveredStatus == .idle {
                session.currentTool = nil
                session.toolDescription = nil
            }
            mutated = true
        }

        if mutated {
            sessions[sessionId] = session
        }
        return mutated
    }

    /// CWD and transcript path participate in tailer/process routing, so an old
    /// asynchronous scan must not rewind them after a newer DB result. Missing
    /// restored fields may still be filled regardless of timestamp.
    @discardableResult
    private func applyDiscoveredMetadata(_ info: DiscoveredSession, to sessionId: String) -> Bool {
        guard var session = sessions[sessionId] else { return false }
        let canReplace = info.modifiedAt >= session.lastActivity
        var mutated = false

        if (canReplace || session.cwd?.isEmpty != false), session.cwd != info.cwd {
            session.cwd = info.cwd
            mutated = true
        }
        if let path = info.transcriptPath,
           (canReplace || session.transcriptPath == nil),
           session.transcriptPath != path {
            session.transcriptPath = path
            mutated = true
        }
        if mutated {
            sessions[sessionId] = session
        }
        return mutated
    }

    /// Link the discovered thread's own card to its parent (see
    /// ``discoveredParentCardId(_:)``). Never a card the discovery was merged
    /// into as a duplicate: a Codex CLI discovery names no provider thread, so
    /// that can be another thread's card — a root, which a link would silence.
    @discardableResult
    private func linkDiscoveredChild(_ info: DiscoveredSession) -> Bool {
        guard sessions[info.sessionId]?.parentSessionId == nil,
              let parent = discoveredParentCardId(info) else {
            return false
        }
        sessions[info.sessionId]?.parentSessionId = parent
        return true
    }

    /// The card a discovered Codex subagent thread works for: its parent
    /// thread's card, or the card that thread's hooks would build. Agent
    /// Sub-Sessions shows it on a card of its own only in Show separately (or
    /// while Merge has no parent card to fold it into), where it stays quiet.
    private func discoveredParentCardId(_ info: DiscoveredSession) -> String? {
        guard info.source == "codex",
              let parentThreadId = info.parentSessionId,
              !parentThreadId.isEmpty else {
            return nil
        }
        let parent = findCodexParentSessionId(
            providerSessionId: parentThreadId,
            childTermBundleId: info.termBundleId
        ) ?? CodexDiscovery.codexDiscoveryIdentity(
            rawSessionId: parentThreadId,
            isDesktop: info.termBundleId == Self.codexAppBundleId
        ).sessionId
        return parent == info.sessionId ? nil : parent
    }

    private func routeDiscoveredSubsessionIfNeeded(_ info: DiscoveredSession) -> Bool {
        guard info.source == "codex",
              let parentSessionId = info.parentSessionId,
              !parentSessionId.isEmpty,
              // A thread whose request waits on its own card stays there
              // until it is answered; discovery just keeps the card current.
              !hasWaitingRequest(onCard: info.sessionId) else {
            return false
        }

        let mode = Self.currentPluginSessionMode()
        guard mode == .hide || mode == .merge else {
            return false
        }

        if mode == .hide {
            if sessions[info.sessionId] != nil {
                removeSession(info.sessionId)
            }
            return true
        }

        guard let parentKey = findCodexParentSessionId(
            providerSessionId: parentSessionId,
            childTermBundleId: info.termBundleId
        ) else {
            return false
        }

        if sessions[info.sessionId] != nil {
            removeSession(info.sessionId)
        }

        let providerSessionId = info.providerSessionId ?? info.sessionId

        if info.subagentStatus?.lowercased() == "closed" || info.status == .idle {
            if sessions[parentKey]?.subagents.removeValue(forKey: providerSessionId) != nil,
               sessions[parentKey]?.subagents.isEmpty == true {
                clearSubagentProjection(fromParentSession: parentKey)
            }
            return true
        }

        let agentType = info.agentType ?? info.agentNickname ?? "Agent"
        var subagent = sessions[parentKey]?.subagents[providerSessionId]
            ?? SubagentState(agentId: providerSessionId, agentType: agentType)
        subagent.status = .running
        subagent.toolDescription = info.agentNickname
        subagent.lastActivity = info.modifiedAt
        // The thread's hooks follow its row here.
        subagent.subsessionKind = .codexThread
        sessions[parentKey]?.subagents[providerSessionId] = subagent

        if sessions[parentKey]?.status != .waitingApproval && sessions[parentKey]?.status != .waitingQuestion {
            sessions[parentKey]?.status = .running
            sessions[parentKey]?.currentTool = "Agent"
            sessions[parentKey]?.toolDescription = info.agentNickname ?? agentType
        }
        // Read before the assignment: writing `sessions[...]` while the RHS also
        // reads it overlaps a modify with a read access and traps at runtime.
        let previousParentActivity = sessions[parentKey]?.lastActivity ?? .distantPast
        sessions[parentKey]?.lastActivity = max(previousParentActivity, info.modifiedAt)
        activeSessionId = parentKey
        return true
    }
}
