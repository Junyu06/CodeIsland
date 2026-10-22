import Foundation
import CodeIslandCore

/// Saving the cards across launches (`SessionPersistence`), and restoring
/// the ones still worth showing.
extension AppState {
    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveSessions()
            }
        }
    }

    func saveSessions() {
        SessionPersistence.save(sessions)
    }

    func restoreSessions() {
        let persisted = SessionPersistence.load()
        let cutoff = Date().addingTimeInterval(-30 * 60) // 30 minutes
        for p in persisted where p.lastActivity > cutoff {
            guard let source = SessionSnapshot.normalizedSupportedSource(p.source) else { continue }
            let restoredSessionId = CodexDiscovery.canonicalRestoredCodexSessionId(
                sessionId: p.sessionId,
                source: source,
                providerSessionId: p.providerSessionId,
                termBundleId: p.termBundleId
            )
            guard sessions[restoredSessionId] == nil else { continue }
            var snapshot = SessionSnapshot(startTime: p.startTime)
            snapshot.cwd = p.cwd
            snapshot.source = source
            snapshot.model = p.model
            snapshot.sessionTitle = p.sessionTitle
            snapshot.sessionTitleSource = p.sessionTitleSource
            snapshot.providerSessionId = p.providerSessionId
            snapshot.lastUserPrompt = p.lastUserPrompt
            snapshot.lastAssistantMessage = p.lastAssistantMessage
            if let prompt = p.lastUserPrompt {
                snapshot.addRecentMessage(ChatMessage(isUser: true, text: prompt))
            }
            if let reply = p.lastAssistantMessage {
                snapshot.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
            snapshot.termApp = p.termApp
            snapshot.itermSessionId = p.itermSessionId
            snapshot.ttyPath = p.ttyPath
            snapshot.kittyWindowId = p.kittyWindowId
            snapshot.tmuxPane = p.tmuxPane
            snapshot.tmuxClientTty = p.tmuxClientTty
            snapshot.tmuxEnv = p.tmuxEnv
            snapshot.termBundleId = p.termBundleId
            snapshot.cmuxSurfaceId = p.cmuxSurfaceId
            snapshot.cmuxWorkspaceId = p.cmuxWorkspaceId
            snapshot.zellijPaneId = p.zellijPaneId
            snapshot.zellijSessionName = p.zellijSessionName
            snapshot.weztermPaneId = p.weztermPaneId
            snapshot.herdrPaneId = p.herdrPaneId
            snapshot.herdrSocketPath = p.herdrSocketPath
            snapshot.herdrBinaryPath = p.herdrBinaryPath
            snapshot.claudeDesktopSessionId = p.claudeDesktopSessionId
            snapshot.hermesChatElsewhere = p.hermesChatElsewhere ?? false
            snapshot.parentSessionId = p.parentSessionId
            snapshot.lastActivity = p.lastActivity
            snapshot.transcriptPath = p.transcriptPath
            snapshot.recap = p.recap
            snapshot.reasoningEffort = p.reasoningEffort
            // A prompt typed while CodeIsland wasn't running supersedes the
            // saved recap; the transcript tail is the judge. Restored cards
            // don't always get a tailer, so check now rather than on attach.
            if snapshot.recap != nil, let path = snapshot.transcriptPath,
               let scan = JSONLTailer.scanFileTail(path: path) {
                _ = snapshot.applyTranscriptBackfill(scan)
            }
            if let closed = p.closedSubagentIds, !closed.isEmpty {
                snapshot.restoreClosedSubagentIds(closed)
            }
            if let agentTasks = p.agentTasks {
                snapshot.agentTasks = agentTasks
            }
            // Restore persisted cliPid only if the process is still alive — avoids
            // stale sessions reappearing briefly after the app or IDE restarts (#46).
            if let pid = p.cliPid, pid > 0 {
                let identity = ProcessIdentity(pid: pid, startTime: p.cliStartTime)
                if ProcessTable.isLiveProcess(identity) {
                    snapshot.cliPid = pid
                    snapshot.cliStartTime = p.cliStartTime
                }
            }
            // Skip sessions whose process is dead and status was idle — nothing to show.
            // Keep Cursor Task tombstones / foldable orphans so applyCursor… can still
            // honor closedSubagentIds after relaunch (otherwise merge can revive them).
            if snapshot.cliPid == nil && snapshot.status == .idle && snapshot.lastUserPrompt == nil,
               !Self.shouldKeepRestoredIdleCursorSession(
                source: source,
                sessionId: restoredSessionId,
                providerSessionId: snapshot.providerSessionId,
                transcriptPath: snapshot.transcriptPath,
                closedSubagentIds: snapshot.closedSubagentIds
               ) {
                continue
            }
            sessions[restoredSessionId] = snapshot
            refreshProviderTitle(for: restoredSessionId)
            // Branch is re-read, not persisted — it may have changed between runs.
            maybeRefreshGitBranch(
                for: restoredSessionId,
                cwdBefore: nil,
                normalizedEventName: "SessionStart"
            )
            // Reattach exit monitoring without changing the restored idle/running snapshot.
            tryMonitorSession(restoredSessionId)
            // Harness is re-probed, not persisted — it may have restarted between runs.
            maybeResolveHostHarness(for: restoredSessionId)
        }
        SessionPersistence.clear()
        _ = applyCodexSubsessionModeToKnownSessions()
        _ = applyCursorSubsessionModeToKnownSessions()
        if activeSessionId == nil {
            activeSessionId = sessions.first(where: { $0.value.status != .idle })?.key
                ?? sessions.keys.sorted().first
        }
        refreshDerivedState()
    }

    /// Idle snapshots with no live process are usually discarded on restore.
    /// Keep Cursor Task cards that carry a Stop tombstone so merge can still
    /// honor `closedSubagentIds` after relaunch. A foldable transcript alone is
    /// not enough — that would rehydrate finished Tasks when Stop was missed.
    nonisolated static func shouldKeepRestoredIdleCursorSession(
        source: String,
        sessionId: String,
        providerSessionId: String?,
        transcriptPath: String?,
        closedSubagentIds: [String]
    ) -> Bool {
        guard source == "cursor" || source == "cursor-cli" else { return false }
        return !closedSubagentIds.isEmpty
    }
}
