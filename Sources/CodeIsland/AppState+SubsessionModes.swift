import Foundation
import CodeIslandCore

/// Agent Sub-Sessions applied to the cards AppState already holds: folding
/// Codex threads and Cursor Tasks into their parents' cards (Merge), dropping
/// them (Hide), splitting them back out (Show separately), and finding the
/// Cursor Task transcripts that tell a misattributed card what it is.
extension AppState {
    @discardableResult
    func applyCodexSubsessionModeToKnownSessions(statePath: String? = nil) -> Bool {
        let mode = Self.currentPluginSessionMode()
        guard mode == .hide || mode == .merge else {
            return false
        }

        let candidates = sessions.map { (sessionId: $0.key, session: $0.value) }
        var transcriptMetadata: [String: CodexSubagentMetadata] = [:]
        var databaseLookupIds: Set<String> = []

        for candidate in candidates where candidate.session.source == "codex" {
            let providerSessionId = candidate.session.providerSessionId ?? candidate.sessionId
            if let transcriptPath = candidate.session.transcriptPath {
                switch codexRollouts.inspection(transcriptPath: transcriptPath) {
                case .subagent(let metadata):
                    transcriptMetadata[candidate.sessionId] = metadata
                    databaseLookupIds.insert(providerSessionId)
                case .root:
                    // A readable root session_meta is definitive. Falling back
                    // to SQLite here turns every root card into a separate DB
                    // open and can also resurrect stale spawn-edge relations.
                    continue
                case .unavailable:
                    databaseLookupIds.insert(providerSessionId)
                }
            } else {
                databaseLookupIds.insert(providerSessionId)
            }
        }
        // One read-only DB connection for all candidates that genuinely need
        // relation/status fallback. Root transcripts never enter this query.
        let databaseRecords = CodexDiscovery.codexSpawnEdgeRecords(
            threadIds: databaseLookupIds,
            statePath: statePath
        )
        var didMutate = false

        for candidate in candidates where candidate.session.source == "codex" {
            let providerSessionId = candidate.session.providerSessionId ?? candidate.sessionId
            guard let metadata = transcriptMetadata[candidate.sessionId]
                    ?? databaseRecords[providerSessionId]?.metadata,
                  metadata.parentThreadId != providerSessionId,
                  !hasWaitingRequest(onCard: candidate.sessionId) else {
                continue
            }

            if mode == .hide {
                if sessions[candidate.sessionId] != nil {
                    removeSession(candidate.sessionId)
                    didMutate = true
                }
                continue
            }

            guard let parentKey = findCodexParentSessionId(
                providerSessionId: metadata.parentThreadId,
                childTermBundleId: candidate.session.termBundleId
            ),
                  parentKey != candidate.sessionId else {
                continue
            }

            // Preserve the terminal snapshot before removeSession tears down the
            // child card. Transcript lifecycle is authoritative even when the
            // spawn edge is missing or remains "open".
            let completedByTranscript = candidate.session.status == .idle
            if sessions[candidate.sessionId] != nil {
                removeSession(candidate.sessionId)
                didMutate = true
            }

            if completedByTranscript
                || databaseRecords[providerSessionId]?.status?.lowercased() == "closed" {
                if sessions[parentKey]?.subagents.removeValue(forKey: providerSessionId) != nil {
                    if sessions[parentKey]?.subagents.isEmpty == true {
                        clearSubagentProjection(fromParentSession: parentKey)
                    }
                    didMutate = true
                }
                continue
            }

            let agentType = metadata.agentType ?? metadata.agentNickname ?? "Agent"
            var subagent = sessions[parentKey]?.subagents[providerSessionId]
                ?? SubagentState(agentId: providerSessionId, agentType: agentType)
            subagent.status = candidate.session.status
            subagent.currentTool = candidate.session.currentTool
            subagent.toolDescription = candidate.session.toolDescription ?? metadata.agentNickname
            if candidate.session.lastActivity > subagent.lastActivity {
                subagent.lastActivity = candidate.session.lastActivity
            }
            // The thread's later hooks follow its row here.
            subagent.subsessionKind = .codexThread
            sessions[parentKey]?.subagents[providerSessionId] = subagent

            if sessions[parentKey]?.status != .waitingApproval && sessions[parentKey]?.status != .waitingQuestion {
                sessions[parentKey]?.status = .running
                sessions[parentKey]?.currentTool = "Agent"
                sessions[parentKey]?.toolDescription = metadata.agentNickname ?? agentType
            }
            if candidate.session.lastActivity > (sessions[parentKey]?.lastActivity ?? .distantPast) {
                sessions[parentKey]?.lastActivity = candidate.session.lastActivity
            }
            activeSessionId = parentKey
            didMutate = true
        }

        return didMutate
    }

    /// Whether an approval or question on this card still waits for the user.
    /// The passes over known cards leave such a card alone: removing or
    /// folding it would deny the request unseen. The next pass after it is
    /// answered moves the card as usual.
    func hasWaitingRequest(onCard sessionId: String) -> Bool {
        permissionQueue.contains(where: { ($0.event.sessionId ?? "default") == sessionId })
            || questionQueue.contains(where: { ($0.event.sessionId ?? "default") == sessionId })
    }

    /// Apply Agent Sub-Sessions to known Cursor Task/subagent cards
    /// (`transcriptPath` is the parent chat; `session_id` is the child).
    /// `merge` / `hide` only; `separate` is handled by `separateMergedCursorSubagents()`.
    @discardableResult
    func applyCursorSubsessionModeToKnownSessions() -> Bool {
        let mode = Self.currentPluginSessionMode()
        guard mode == .hide || mode == .merge else {
            return false
        }

        // Cursor Agent Tasks that fired Claude-format hooks keep default
        // source=claude and never enter the fold loop — rebrand first.
        var didMutate = rebrandMisattributedCursorTaskCards()

        // Refresh after rebrand so newly tagged cursor cards are included.
        let candidates = sessions.map { (sessionId: $0.key, session: $0.value) }

        if mode == .hide {
            for candidate in candidates {
                let source = candidate.session.source
                guard source == "cursor" || source == "cursor-cli" else { continue }
                guard cursorFoldIdentity(for: candidate) != nil,
                      !hasWaitingRequest(onCard: candidate.sessionId) else { continue }
                if sessions[candidate.sessionId] != nil {
                    removeSession(candidate.sessionId)
                    didMutate = true
                }
            }
            return hideMergedCursorSubagents() || didMutate
        }

        for candidate in candidates {
            let source = candidate.session.source
            guard source == "cursor" || source == "cursor-cli" else { continue }
            guard let fold = cursorFoldIdentity(for: candidate),
                  !hasWaitingRequest(onCard: candidate.sessionId) else { continue }
            let parentId = fold.parentId
            let childId = fold.childId

            // If fold identity collides with this card, prefer the real parent id
            // (child wrongly reused the parent's providerSessionId).
            var parentKey = findSessionId(providerSessionId: parentId) ?? parentId
            if parentKey == candidate.sessionId {
                parentKey = parentId
            }
            if parentKey == candidate.sessionId { continue }

            // Closed ids may sit on the parent (merge Stop) or the child card
            // (separate Stop). Parent tombstone always wins over a late-running
            // orphan card — relaunch clears via UserPromptSubmit on the hook path.
            let candidateCarriesClosed = candidate.session.hasClosedSubagentId(childId)
                || candidate.session.hasClosedSubagentId(candidate.sessionId)
            let parentHoldsTombstone = sessions[parentKey]?.hasClosedSubagentId(childId) == true

            if candidateCarriesClosed || parentHoldsTombstone {
                if sessions[parentKey] == nil {
                    var parent = SessionSnapshot(startTime: candidate.session.startTime)
                    parent.source = source
                    parent.cwd = candidate.session.cwd
                    parent.model = candidate.session.model
                    parent.termApp = candidate.session.termApp
                    parent.termBundleId = candidate.session.termBundleId
                    parent.transcriptPath = candidate.session.transcriptPath
                    parent.providerSessionId = parentId
                    // Closed ids only — parent is not actively working.
                    parent.status = .idle
                    parent.lastActivity = candidate.session.lastActivity
                    sessions[parentKey] = parent
                }
                promoteCursorClosedIds(
                    onto: parentKey,
                    childId: childId,
                    candidateSessionId: candidate.sessionId,
                    childClosed: candidate.session.closedSubagentIds
                )
                if sessions[candidate.sessionId] != nil {
                    removeSession(candidate.sessionId)
                    didMutate = true
                }
                continue
            }

            // Idle orphan: always drop — never overwrite a live merged Task slot
            // with an AfterAgentResponse→idle discovery card. Tombstones were
            // already handled above; plain idle must not invent parents either.
            if candidate.session.status == .idle {
                if sessions[candidate.sessionId] != nil {
                    removeSession(candidate.sessionId)
                    didMutate = true
                }
                continue
            }

            if sessions[parentKey] == nil {
                var parent = SessionSnapshot(startTime: candidate.session.startTime)
                parent.source = source
                parent.cwd = candidate.session.cwd
                parent.model = candidate.session.model
                parent.termApp = candidate.session.termApp
                parent.termBundleId = candidate.session.termBundleId
                parent.transcriptPath = candidate.session.transcriptPath
                // Do not copy the Task/subagent process identity onto the parent chat.
                parent.providerSessionId = parentId
                parent.status = candidate.session.status == .idle ? .processing : candidate.session.status
                parent.lastActivity = candidate.session.lastActivity
                sessions[parentKey] = parent
            } else if sessions[parentKey]?.transcriptPath == nil,
                      let path = candidate.session.transcriptPath {
                sessions[parentKey]?.transcriptPath = path
            }

            if sessions[candidate.sessionId] != nil {
                removeSession(candidate.sessionId)
                didMutate = true
            }

            // Prefer an existing parent monitor; skip if we only synthesized metadata.
            if sessions[parentKey]?.cliPid != nil || sessions[parentKey]?.transcriptPath != nil {
                if sessions[parentKey]?.transcriptPath != nil {
                    attachTranscriptTailerIfNeeded(sessionId: parentKey)
                }
                if sessions[parentKey]?.cliPid != nil {
                    tryMonitorSession(parentKey)
                }
            }

            var subagent = sessions[parentKey]?.subagents[childId]
                ?? SubagentState(agentId: childId, agentType: "cursor-subagent")
            subagent.status = candidate.session.status
            subagent.currentTool = candidate.session.currentTool
            subagent.toolDescription = candidate.session.toolDescription
            if candidate.session.lastActivity > subagent.lastActivity {
                subagent.lastActivity = candidate.session.lastActivity
            }
            // The Task's later hooks follow its row here.
            subagent.subsessionKind = .cursorTask
            sessions[parentKey]?.subagents[childId] = subagent

            if sessions[parentKey]?.status != .waitingApproval
                && sessions[parentKey]?.status != .waitingQuestion {
                sessions[parentKey]?.status = .running
                if sessions[parentKey]?.currentTool == nil {
                    sessions[parentKey]?.currentTool = "Agent"
                    sessions[parentKey]?.toolDescription = "cursor-subagent"
                }
            }
            if candidate.session.lastActivity > (sessions[parentKey]?.lastActivity ?? .distantPast) {
                sessions[parentKey]?.lastActivity = candidate.session.lastActivity
            }
            activeSessionId = parentKey
            didMutate = true
        }

        return didMutate
    }

    /// Record the foldable child id(s) on the parent — not an arbitrary union of
    /// whatever closed set the orphan card carried.
    private func promoteCursorClosedIds(
        onto parentKey: String,
        childId: String,
        candidateSessionId: String,
        childClosed: [String]
    ) {
        sessions[parentKey]?.recordClosedSubagentId(childId)
        if candidateSessionId != childId {
            sessions[parentKey]?.recordClosedSubagentId(candidateSessionId)
        }
        for id in childClosed where id == childId || id == candidateSessionId {
            sessions[parentKey]?.recordClosedSubagentId(id)
        }
    }

    func markMergedSubagentWaiting(
        sessionId: String,
        event: HookEvent,
        status: AgentStatus
    ) {
        guard let agentId = event.agentId else { return }
        guard var session = sessions[sessionId] else { return }
        // A row the request creates goes by the hook's own `agent_type` (a
        // Codex thread's role, a pi child's agent). A child session Agent
        // Sub-Sessions folded here is marked as one, so its later hooks
        // follow this row.
        let foldedKind = SubsessionRouter.foldedKind(of: event)
        let agentType = (event.rawJSON["agent_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var subagent = session.subagents[agentId]
            ?? SubagentState(
                agentId: agentId,
                agentType: agentType.flatMap { $0.isEmpty ? nil : $0 }
                    ?? foldedKind?.defaultAgentType
                    ?? "cursor-subagent"
            )
        subagent.status = status
        subagent.lastActivity = Date()
        if let foldedKind {
            subagent.subsessionKind = foldedKind
        }
        session.subagents[agentId] = subagent
        sessions[sessionId] = session
    }

    /// After Permission/Question UI resolves for a possibly folded Task.
    /// With `agent_id`, never idle the parent — even if the subagent slot was
    /// already removed (Stop race). Uses local copies to avoid exclusivity traps
    /// when mutating nested `sessions[id].subagents[id]` fields.
    func resolveMergedSubagentAfterUI(
        sessionId: String,
        agentId: String?,
        subagentStatus: AgentStatus,
        keepSubagentTool: String?,
        idleParentWhenNoAgent: Bool
    ) {
        if let agentId {
            guard var session = sessions[sessionId] else { return }
            if var subagent = session.subagents[agentId] {
                subagent.status = subagentStatus
                if subagentStatus == .processing {
                    subagent.currentTool = nil
                    subagent.toolDescription = nil
                } else if let keepSubagentTool {
                    subagent.currentTool = keepSubagentTool
                }
                session.subagents[agentId] = subagent
            }
            let hasNonIdleSubagents = session.subagents.values.contains { $0.status != .idle }
            if hasNonIdleSubagents {
                let agentType = session.subagents[agentId]?.agentType ?? "cursor-subagent"
                session.status = .running
                session.currentTool = "Agent"
                if session.toolDescription == nil {
                    session.toolDescription = agentType
                }
            } else {
                session.status = .processing
                session.currentTool = nil
                session.toolDescription = nil
            }
            sessions[sessionId] = session
            return
        }

        if idleParentWhenNoAgent {
            sessions[sessionId]?.status = .idle
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        } else {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    }

    /// Suppress Permission/Question UI for Stop'd Tasks: merged `agent_id` tombstones
    /// or separate-mode self-tombstones (card id recorded in ``closedSubagentIds``).
    func shouldSuppressClosedSubagentUI(sessionId: String, agentId: String?) -> Bool {
        if let agentId, sessions[sessionId]?.hasClosedSubagentId(agentId) == true { return true }
        if agentId == nil, sessions[sessionId]?.hasClosedSubagentId(sessionId) == true { return true }
        return false
    }

    /// Parent/child ids when this card's transcript belongs to another Cursor chat.
    private func cursorFoldIdentity(
        for candidate: (sessionId: String, session: SessionSnapshot)
    ) -> (parentId: String, childId: String)? {
        // Prefer providerSessionId if it folds; else the card key (used as agent_id).
        let primaryId = candidate.session.providerSessionId ?? candidate.sessionId
        let parentFromPrimary = CursorSessionFolding.foldTarget(
            childSessionId: primaryId,
            transcriptPath: candidate.session.transcriptPath
        )
        let parentFromCard = candidate.sessionId == primaryId
            ? nil
            : CursorSessionFolding.foldTarget(
                childSessionId: candidate.sessionId,
                transcriptPath: candidate.session.transcriptPath
            )
        if let parentFromPrimary {
            return (parentFromPrimary, primaryId)
        }
        if let parentFromCard {
            return (parentFromCard, candidate.sessionId)
        }
        return nil
    }

    /// Rebrand default-Claude cards that are actually Cursor Agent Tasks
    /// (`~/.cursor/.../agent-transcripts/.../subagents/<id>.jsonl`), and give
    /// Cursor-labelled Task cards that transcript, which folds them.
    ///
    /// Runs on every hook event and discovery scan, so it never touches the
    /// disk: cards without a Cursor transcript path are looked up in
    /// `cursorSubagentIndex`, and a card the index does not resolve is looked
    /// up again by fresh walks off the main actor, on a bounded schedule
    /// (`scheduleCursorSubagentLookups`). When a walk finds it, the card is
    /// rebranded then (`installCursorSubagentIndex`).
    @discardableResult
    func rebrandMisattributedCursorTaskCards() -> Bool {
        var didMutate = false
        for (sessionId, snap) in sessions {
            guard Self.needsCursorTaskTranscriptLookup(snap) else { continue }

            if let path = snap.transcriptPath,
               CursorSessionFolding.isCursorAgentTranscriptPath(path) {
                sessions[sessionId]?.source = "cursor"
                didMutate = true
                continue
            }
            // A remote card's transcripts live on its own host, never in the local index.
            guard !snap.isRemote else { continue }

            guard let found = cursorSubagentIndex?.transcriptPath(
                sessionId: sessionId,
                preferredBase: Self.cursorProjectTranscriptBase(cwd: snap.cwd)
            ) else {
                continue
            }
            if !CursorSubsessionRouter.isCursorFamilySource(snap.source) {
                sessions[sessionId]?.source = "cursor"
            }
            if sessions[sessionId]?.transcriptPath == nil {
                sessions[sessionId]?.transcriptPath = found
            }
            didMutate = true
        }
        scheduleCursorSubagentLookups()
        return didMutate
    }

    /// Cards the Task transcript index is consulted for: default-Claude cards,
    /// and local Cursor cards with no transcript at all. A Task's own hooks
    /// never carry one (Cursor resolves `transcript_path` only for a top-level
    /// conversation), and since the bridge reads Cursor's payload (#377) the
    /// Task hooks Cursor runs from Claude Code's config arrive labelled Cursor
    /// rather than as the default Claude.
    nonisolated static func needsCursorTaskTranscriptLookup(_ snap: SessionSnapshot) -> Bool {
        switch SessionSnapshot.normalizedSupportedSource(snap.source) {
        case nil, "claude":
            return true
        case "cursor", "cursor-cli":
            return snap.transcriptPath == nil && !snap.isRemote
        default:
            return false
        }
    }

    /// Give each card the index does not resolve a lookup schedule (kept
    /// across calls, dropped once the card is gone or rebranded), then start
    /// the walk its earliest due lookup needs, or arm the re-check timer for
    /// it. At most one walk and one timer are ever pending.
    private func scheduleCursorSubagentLookups(now: Date = Date()) {
        // `separate` folds nothing, so nothing is looked up; leaving it starts
        // every card's schedule afresh (`applyCurrentPluginSessionMode`).
        let mode = Self.currentPluginSessionMode()
        guard mode == .merge || mode == .hide else {
            resetCursorSubagentLookups()
            return
        }
        var lookups: [String: CursorSubagentLookupSchedule] = [:]
        for sessionId in cursorRebrandCandidateIds()
        where cursorSubagentIndex?.contains(sessionId: sessionId) != true {
            lookups[sessionId] = cursorSubagentLookups[sessionId]
                ?? CursorSubagentLookupSchedule(since: now, delays: cursorSubagentLookupDelays)
        }
        cursorSubagentLookups = lookups
        guard cursorSubagentIndexTask == nil else { return }  // its completion reschedules
        guard let due = lookups.values.compactMap(\.nextLookup).min() else {
            cancelCursorSubagentIndexRecheck()
            return
        }
        if due <= now {
            startCursorSubagentIndexRebuild()
        } else {
            armCursorSubagentIndexRecheck(at: due)
        }
    }

    /// The timer, not hook traffic, drives a card's later lookups.
    private func armCursorSubagentIndexRecheck(at due: Date) {
        if cursorSubagentIndexRecheck != nil, let armed = cursorSubagentIndexRecheckAt, armed <= due { return }
        cursorSubagentIndexRecheck?.cancel()
        cursorSubagentIndexRecheckAt = due
        let delay = max(0, due.timeIntervalSinceNow)
        cursorSubagentIndexRecheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).rounded(.up)))
            guard let self, !Task.isCancelled else { return }
            self.cursorSubagentIndexRecheck = nil
            self.cursorSubagentIndexRecheckAt = nil
            self.scheduleCursorSubagentLookups()
        }
    }

    func cancelCursorSubagentIndexRecheck() {
        cursorSubagentIndexRecheck?.cancel()
        cursorSubagentIndexRecheck = nil
        cursorSubagentIndexRecheckAt = nil
    }

    /// Drop every card's lookup schedule and the timer driving them.
    private func resetCursorSubagentLookups() {
        cursorSubagentLookups = [:]
        cancelCursorSubagentIndexRecheck()
    }

    private func startCursorSubagentIndexRebuild() {
        guard cursorSubagentIndexTask == nil else { return }
        cancelCursorSubagentIndexRecheck()
        let scan = discovery.scanners.cursorSubagentIndex
        cursorSubagentIndexTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            let index = scan()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                // Cancelled by teardown, which already dropped the handle.
                guard let self, !Task.isCancelled else { return }
                self.cursorSubagentIndexTask = nil
                self.installCursorSubagentIndex(index)
            }
        }
    }

    /// Adopt a freshly walked index: count it against the schedule of every
    /// card it does not resolve, and rebrand (and fold) the cards it does.
    private func installCursorSubagentIndex(_ index: CursorSubagentTranscriptIndex) {
        cursorSubagentIndex = index
        for sessionId in Array(cursorSubagentLookups.keys) where !index.contains(sessionId: sessionId) {
            cursorSubagentLookups[sessionId]?.recordMiss(walkStartedAt: index.builtAt)
        }

        let resolvedAny = cursorRebrandCandidateIds().contains { index.contains(sessionId: $0) }
        if resolvedAny, applyCursorSubsessionModeToKnownSessions() {
            scheduleSave()
            startRotationIfNeeded()
            refreshDerivedState()
        } else {
            scheduleCursorSubagentLookups()
        }
    }

    /// Local cards the index may resolve (``needsCursorTaskTranscriptLookup``)
    /// whose transcript path does not already say Cursor.
    private func cursorRebrandCandidateIds() -> [String] {
        sessions.compactMap { sessionId, snap in
            guard Self.needsCursorTaskTranscriptLookup(snap), !snap.isRemote,
                  !CursorSessionFolding.isCursorAgentTranscriptPath(snap.transcriptPath) else { return nil }
            return sessionId
        }
    }

    /// `~/.cursor/projects/<cwd-encoded>/agent-transcripts` — where a Task run
    /// from `cwd` keeps its transcripts.
    nonisolated static func cursorProjectTranscriptBase(
        cwd: String?,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return "\(home)/.cursor/projects/\(cwd.appProjectDirEncoded())/agent-transcripts"
    }

    func applyCurrentPluginSessionMode(persist: Bool = true) {
        let mode = Self.currentPluginSessionMode()
        var didMutate = false

        switch mode {
        case .separate:
            // Back in merge or hide, every candidate card is looked up afresh.
            resetCursorSubagentLookups()
            didMutate = separateMergedCodexSubagents()
            didMutate = separateMergedCursorSubagents() || didMutate
        case .merge:
            didMutate = applyCodexSubsessionModeToKnownSessions()
            didMutate = applyCursorSubsessionModeToKnownSessions() || didMutate
        case .hide:
            didMutate = applyCodexSubsessionModeToKnownSessions()
            didMutate = hideMergedCodexSubagents() || didMutate
            didMutate = applyCursorSubsessionModeToKnownSessions() || didMutate
        }

        if didMutate {
            if persist {
                scheduleSave()
                startRotationIfNeeded()
            }
            refreshDerivedState()
        }
    }

    @discardableResult
    private func separateMergedCodexSubagents() -> Bool {
        let parentCandidates = sessions.map { (sessionId: $0.key, session: $0.value) }
        let childIds = Set(parentCandidates.flatMap { $0.session.subagents.keys })
        // One DB connection for the whole mode transition; never open SQLite
        // once per child (each open carries a busy timeout).
        let databaseRecords = CodexDiscovery.codexSpawnEdgeRecords(threadIds: childIds)
        var didMutate = false

        for parent in parentCandidates where parent.session.source == "codex" && !parent.session.subagents.isEmpty {
            for (agentId, subagent) in parent.session.subagents {
                let childIsDesktop = parent.session.termBundleId == Self.codexAppBundleId
                let childKey = findCodexParentSessionId(
                    providerSessionId: agentId,
                    childTermBundleId: parent.session.termBundleId
                ) ?? CodexDiscovery.codexDiscoveryIdentity(
                    rawSessionId: agentId,
                    isDesktop: childIsDesktop
                ).sessionId
                guard childKey != parent.sessionId else { continue }

                var child = sessions[childKey] ?? SessionSnapshot(startTime: subagent.startTime)
                child.source = "codex"
                child.providerSessionId = agentId
                child.cwd = child.cwd ?? parent.session.cwd
                // The child's own model (its hooks, then its rollout below) —
                // never the parent's: children routinely run on another model.
                child.model = child.model ?? subagent.model
                child.reasoningEffort = child.reasoningEffort ?? subagent.reasoningEffort
                child.permissionMode = child.permissionMode ?? parent.session.permissionMode
                child.termApp = child.termApp ?? parent.session.termApp
                child.itermSessionId = child.itermSessionId ?? parent.session.itermSessionId
                child.ttyPath = child.ttyPath ?? parent.session.ttyPath
                child.kittyWindowId = child.kittyWindowId ?? parent.session.kittyWindowId
                child.tmuxPane = child.tmuxPane ?? parent.session.tmuxPane
                child.tmuxClientTty = child.tmuxClientTty ?? parent.session.tmuxClientTty
                child.tmuxEnv = child.tmuxEnv ?? parent.session.tmuxEnv
                child.termBundleId = child.termBundleId ?? parent.session.termBundleId
                child.remoteHostId = child.remoteHostId ?? parent.session.remoteHostId
                child.remoteHostName = child.remoteHostName ?? parent.session.remoteHostName
                child.cliPid = child.cliPid ?? parent.session.cliPid
                child.cliStartTime = child.cliStartTime ?? parent.session.cliStartTime
                child.status = subagent.status
                child.currentTool = subagent.currentTool
                child.toolDescription = subagent.toolDescription ?? subagent.agentType
                child.lastActivity = subagent.lastActivity
                // Still the parent's child, on a card of its own: quiet.
                child.parentSessionId = child.parentSessionId ?? parent.sessionId

                let transcriptMetadata = child.transcriptPath.flatMap {
                    CodexDiscovery.codexSubagentMetadata(inTranscriptPath: $0)
                }
                let metadata = transcriptMetadata ?? databaseRecords[agentId]?.metadata
                if child.sessionTitle == nil {
                    child.sessionTitle = metadata?.agentNickname ?? subagent.toolDescription ?? subagent.agentType
                }
                if child.transcriptPath == nil {
                    if let statePath = databaseRecords[agentId]?.transcriptPath,
                       FileManager.default.fileExists(atPath: statePath) {
                        child.transcriptPath = statePath
                    } else if let cwd = parent.session.cwd {
                        let base = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".codex/sessions").path
                        child.transcriptPath = CodexDiscovery.findRecentCodexSession(
                            base: base,
                            cwd: cwd,
                            after: parent.session.cliStartTime,
                            fm: .default
                        )
                    }
                }
                if let transcriptPath = child.transcriptPath {
                    let (model, messages) = CodexDiscovery.readRecentFromCodexTranscript(path: transcriptPath)
                    child.model = child.model ?? model
                    if !messages.isEmpty {
                        child.recentMessages = messages
                        child.lastUserPrompt = messages.last(where: \.isUser)?.text
                        child.lastAssistantMessage = messages.last(where: { !$0.isUser })?.text
                    }
                }

                sessions[childKey] = child
                refreshProviderTitle(for: childKey, providerSessionId: agentId)
                attachTranscriptTailerIfNeeded(sessionId: childKey)
                tryMonitorSession(childKey)
                sessions[parent.sessionId]?.subagents.removeValue(forKey: agentId)
                if subagent.status != .idle {
                    activeSessionId = childKey
                }
                didMutate = true
            }
            if sessions[parent.sessionId]?.subagents.isEmpty == true {
                clearSubagentProjection(fromParentSession: parent.sessionId)
            }
        }

        return didMutate
    }

    @discardableResult
    private func hideMergedCodexSubagents() -> Bool {
        var didMutate = false
        for (sessionId, session) in sessions where session.source == "codex" && !session.subagents.isEmpty {
            sessions[sessionId]?.subagents.removeAll()
            clearSubagentProjection(fromParentSession: sessionId)
            didMutate = true
        }
        return didMutate
    }

    /// Split Cursor parent.subagents into standalone cards (Agent Sub-Sessions: separate).
    @discardableResult
    private func separateMergedCursorSubagents() -> Bool {
        let parentCandidates = sessions.map { (sessionId: $0.key, session: $0.value) }
        var didMutate = false

        for parent in parentCandidates
        where (parent.session.source == "cursor" || parent.session.source == "cursor-cli")
            && !parent.session.subagents.isEmpty {
            for (agentId, subagent) in parent.session.subagents {
                let childKey = findSessionId(providerSessionId: agentId) ?? agentId
                guard childKey != parent.sessionId else { continue }

                var child = sessions[childKey] ?? SessionSnapshot(startTime: subagent.startTime)
                child.source = parent.session.source
                child.providerSessionId = agentId
                child.cwd = child.cwd ?? parent.session.cwd
                // Own model only, never the parent chat's (see the Codex split).
                child.model = child.model ?? subagent.model
                child.reasoningEffort = child.reasoningEffort ?? subagent.reasoningEffort
                child.permissionMode = child.permissionMode ?? parent.session.permissionMode
                child.termApp = child.termApp ?? parent.session.termApp
                child.itermSessionId = child.itermSessionId ?? parent.session.itermSessionId
                child.ttyPath = child.ttyPath ?? parent.session.ttyPath
                child.kittyWindowId = child.kittyWindowId ?? parent.session.kittyWindowId
                child.tmuxPane = child.tmuxPane ?? parent.session.tmuxPane
                child.tmuxClientTty = child.tmuxClientTty ?? parent.session.tmuxClientTty
                child.tmuxEnv = child.tmuxEnv ?? parent.session.tmuxEnv
                child.termBundleId = child.termBundleId ?? parent.session.termBundleId
                child.cmuxSurfaceId = child.cmuxSurfaceId ?? parent.session.cmuxSurfaceId
                child.cmuxWorkspaceId = child.cmuxWorkspaceId ?? parent.session.cmuxWorkspaceId
                child.zellijPaneId = child.zellijPaneId ?? parent.session.zellijPaneId
                child.zellijSessionName = child.zellijSessionName ?? parent.session.zellijSessionName
                child.weztermPaneId = child.weztermPaneId ?? parent.session.weztermPaneId
                child.herdrPaneId = child.herdrPaneId ?? parent.session.herdrPaneId
                child.herdrSocketPath = child.herdrSocketPath ?? parent.session.herdrSocketPath
                child.herdrBinaryPath = child.herdrBinaryPath ?? parent.session.herdrBinaryPath
                child.claudeDesktopSessionId = child.claudeDesktopSessionId ?? parent.session.claudeDesktopSessionId
                child.remoteHostId = child.remoteHostId ?? parent.session.remoteHostId
                child.remoteHostName = child.remoteHostName ?? parent.session.remoteHostName
                // Keep the child's own process identity only — the parent Cursor chat
                // often shares the IDE process, which must not be attributed to Tasks.
                child.status = subagent.status
                child.currentTool = subagent.currentTool
                child.toolDescription = subagent.toolDescription ?? subagent.agentType
                child.lastActivity = subagent.lastActivity
                // Still the chat's Task, on a card of its own: quiet.
                child.parentSessionId = child.parentSessionId ?? parent.sessionId
                if child.sessionTitle == nil {
                    child.sessionTitle = subagent.toolDescription ?? subagent.agentType
                }
                // Keep parent transcriptPath for later fold identity, but do not
                // attach a second JSONLTailer on the same parent file (steals the
                // parent's live tail). Prefer a child-specific path when present.
                let parentTranscript = parent.session.transcriptPath
                if child.transcriptPath == nil {
                    child.transcriptPath = parentTranscript
                }
                let shouldTailChildTranscript =
                    child.transcriptPath != nil && child.transcriptPath != parentTranscript

                sessions[childKey] = child
                refreshProviderTitle(for: childKey, providerSessionId: agentId)
                if shouldTailChildTranscript {
                    attachTranscriptTailerIfNeeded(sessionId: childKey)
                }
                if child.cliPid != nil {
                    tryMonitorSession(childKey)
                }
                sessions[parent.sessionId]?.subagents.removeValue(forKey: agentId)
                if subagent.status != .idle {
                    activeSessionId = childKey
                }
                didMutate = true
            }
            if sessions[parent.sessionId]?.subagents.isEmpty == true {
                clearSubagentProjection(fromParentSession: parent.sessionId)
            }
        }

        return didMutate
    }

    /// Clear Cursor parent.subagents (Agent Sub-Sessions: hide).
    @discardableResult
    private func hideMergedCursorSubagents() -> Bool {
        var didMutate = false
        for (sessionId, session) in sessions
        where (session.source == "cursor" || session.source == "cursor-cli") && !session.subagents.isEmpty {
            sessions[sessionId]?.subagents.removeAll()
            clearSubagentProjection(fromParentSession: sessionId)
            didMutate = true
        }
        return didMutate
    }

    func clearSubagentProjection(fromParentSession sessionId: String) {
        guard sessions[sessionId]?.currentTool == "Agent" else { return }
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        if sessions[sessionId]?.status == .running {
            sessions[sessionId]?.status = .processing
        }
    }
}
