import AppKit
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "AppState")

/// How a card's life ends: the exit of its CLI process (watched by
/// `processMonitor`, with a grace period for a replacement to take over) and
/// the cleanup tick's sweeps — dead or orphaned processes, stuck waits,
/// silent turns, idle timeouts.
extension AppState {
    /// Agents whose tracked process is a long-lived daemon rather than a
    /// per-turn CLI. Process exit never marks the end of a reply, so when the
    /// turn-end hook is missing (not approved on the agent's side, or the turn
    /// died before it fired) a card that has gone quiet with no tool in flight
    /// is the only evidence the turn is over. (#303)
    nonisolated static let daemonBackedSources: Set<String> = ["hermes"]

    /// How long a daemon-backed session may sit on bare "thinking" with no tool
    /// and no new events before it settles. Only a safety net: Hermes's
    /// on_session_end ends every turn, interrupted ones included (#364). The
    /// card is on "thinking" from the prompt on (pre_llm_call), and a
    /// reasoning model easily thinks for longer than 20 s before its first or
    /// next tool call — the card must not read idle while it does.
    nonisolated static let daemonTurnSettleTimeout: TimeInterval = 120

    /// Minutes an idle card with no process to outlive waits before it goes.
    nonisolated static let defaultStaleIdleMinutes = 10

    /// Whether the idle sweep removes an idle card. The user's timeout applies
    /// to every card. Otherwise a card whose process is monitored lives as
    /// long as that process; one without (hook-only) goes after
    /// `defaultStaleIdleMinutes`. So does a Hermes gateway chat's card: its
    /// monitored process is the gateway daemon, which never exits (#364).
    nonisolated static func isStaleIdleSession(
        idleMinutes: Int,
        userTimeoutMinutes: Int,
        hasMonitor: Bool,
        hermesChatElsewhere: Bool
    ) -> Bool {
        if userTimeoutMinutes > 0 && idleMinutes >= userTimeoutMinutes { return true }
        let livesWithItsProcess = hasMonitor && !hermesChatElsewhere
        return !livesWithItsProcess && idleMinutes >= defaultStaleIdleMinutes
    }

    nonisolated static func isDaemonBackedSource(_ source: String?) -> Bool {
        guard let normalized = SessionSnapshot.normalizedSupportedSource(source) else { return false }
        return daemonBackedSources.contains(normalized)
    }

    func cleanupIdleSessions() {
        // 1. Verify monitored PIDs are still alive (DispatchSource can silently miss exits)
        //    Also kill orphaned processes (ppid <= 1, terminal closed but process survived).
        let sweep = processMonitor.sweep()
        let orphaned = sweep.reparented.filter {
            shouldTerminateOrphanedProcess(sessionId: $0.sessionId, pid: $0.pid)
        }
        for (sessionId, process) in sweep.exited {
            // PID gone but monitor didn't fire — treat as process exit so session is removed
            // promptly (after 5s grace) instead of lingering for 10 minutes.
            handleProcessExit(sessionId: sessionId, exitedProcess: process)
        }
        for (sessionId, pid) in orphaned {
            log.notice("⚠️ terminating reparented orphan pid=\(pid, privacy: .public) session=\(sessionId, privacy: .public)")
            kill(pid, SIGTERM)
            removeSession(sessionId)
        }

        // 2. Reset likely-stuck sessions only when we have no process monitor.
        //    If the process is still monitored/alive, trust explicit Stop/SessionEnd or
        //    process exit instead of synthesizing idle and risking false-idle mid-thought.
        //    - No tool + no monitor: 300s (agents can think for several minutes)
        //    - Has tool + no monitor: 180s (long build / deep thinking with missed exit)
        //    - waitingApproval/Question + no monitor: 300s (connection likely dropped)
        //
        //    Skip remote sessions: they NEVER have a local process monitor (the CLI runs
        //    on the remote host), and a long-running remote task that doesn't fire hook
        //    events for >180s shouldn't be force-flipped to idle here — it'll then be
        //    swept by Section 4. Remote session lifecycle is driven by remote-end hooks
        //    and SSH connection state in RemoteManager, not by local timeouts. (#121)
        //    Claude Desktop Cowork cards are skipped too and settled on their own
        //    clock right after: their session store stays silent through a long
        //    tool run and for as long as a permission card is left open.
        for (key, session) in sessions
            where !processMonitor.isWatching(key)
            && session.status != .idle
            && !session.isRemote
            && !key.hasPrefix(Self.coworkSessionPrefix) {
            let elapsed = -session.lastActivity.timeIntervalSinceNow
            let threshold: TimeInterval
            switch session.status {
            case .waitingApproval, .waitingQuestion: threshold = 300
            default: threshold = session.currentTool != nil ? 180 : 300
            }
            if elapsed > threshold {
                sessions[key]?.status = .idle
                sessions[key]?.currentTool = nil
                sessions[key]?.toolDescription = nil
            }
        }
        settleCoworkCards()

        // 2b. Some CLIs keep their parent process alive across requests, so a missed Stop hook
        // can leave the UI stuck in bare "thinking" forever after an interrupt. If we've had no
        // follow-up hook activity for a long time and there isn't even a live tool/description,
        // reset that silent processing state back to idle.
        let monitoredThinkingTimeout: TimeInterval = 300
        let nativeAppThinkingTimeout: TimeInterval = 30
        let codexTerminalTurnSettleTime: TimeInterval = 3
        for (key, session) in sessions
            where session.status == .processing
            && session.currentTool == nil
            && session.toolDescription == nil {
            let elapsed = -session.lastActivity.timeIntervalSinceNow
            // Daemon-backed agents settle on their own timeout whether or not we
            // hold a process monitor: their backend never exits, so a live PID
            // says nothing about whether the turn is over (#303).
            if Self.isDaemonBackedSource(session.source) {
                if elapsed > Self.daemonTurnSettleTimeout {
                    sessions[key]?.status = .idle
                }
                continue
            }
            guard processMonitor.isWatching(key) else { continue }
            // Native apps write transcripts synchronously — if the transcript check below
            // didn't find a stop marker after 30s, the session is almost certainly idle.
            if session.isNativeAppMode, elapsed > nativeAppThinkingTimeout {
                sessions[key]?.status = .idle
                continue
            }
            // Before that, the turn's end in its transcript settles it: read
            // off the main actor, applied when the read lands.
            if session.isNativeAppMode, elapsed >= codexTerminalTurnSettleTime {
                checkNativeAppTurnEnded(sessionId: key, session: session, settleTime: codexTerminalTurnSettleTime)
                continue
            }
            if elapsed > monitoredThinkingTimeout {
                sessions[key]?.status = .idle
            }
        }

        // 3. Verify PID liveness for sessions without monitors but with a known PID.
        //    If the process died: idle sessions are removed directly (no grace needed),
        //    non-idle sessions go through handleProcessExit for the 5s grace period.
        for (key, session) in sessions where !processMonitor.isWatching(key) {
            guard let process = resolvedSessionProcessIdentity(for: key) else { continue }
            if !ProcessTable.isLiveProcess(process) {
                if exitingSessions[key] == process { continue }
                if session.status == .idle {
                    removeSession(key)
                } else {
                    handleProcessExit(sessionId: key, exitedProcess: process)
                }
            }
        }

        // 3b. Native app sessions (OpenCode desktop, Codex app, etc.) whose app is no longer
        //     running should be cleaned up — these apps can't send SessionEnd when force-quit.
        //     Don't check PID liveness here: the dedup in integrateDiscovered may have
        //     reattached a CLI PID to the old native app session, keeping it alive incorrectly.
        // `NSWorkspace.runningApplications` is not a cheap array read: touching
        // `bundleIdentifier` on each entry goes out to LaunchServices over XPC,
        // and this timer fires every 3 seconds forever. Only two things below
        // need it, and on an idle Mac neither does — so build it lazily and, in
        // the common case, never at all (#299).
        var cachedRunningBundleIds: Set<String>?
        func runningBundleIds() -> Set<String> {
            if let cachedRunningBundleIds { return cachedRunningBundleIds }
            let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            cachedRunningBundleIds = ids
            return ids
        }

        if sessions.values.contains(where: { $0.isNativeAppMode }) {
            let running = runningBundleIds()
            for (key, session) in sessions {
                guard session.isNativeAppMode,
                      let bundleId = session.termBundleId,
                      !running.contains(bundleId) else { continue }
                removeSession(key)
            }
        }
        discovery.pollCodexDesktopIfDue(now: Date(), runningBundleIdentifiers: runningBundleIds)

        // 4. Remove idle sessions past timeout (user setting, or 10 min default for no-monitor sessions)
        let userTimeout = SettingsManager.shared.sessionTimeout
        for (key, session) in sessions where session.status == .idle {
            let idleMinutes = Int(-session.lastActivity.timeIntervalSinceNow / 60)
            if Self.isStaleIdleSession(
                idleMinutes: idleMinutes,
                userTimeoutMinutes: userTimeout,
                hasMonitor: processMonitor.isWatching(key),
                hermesChatElsewhere: session.hermesChatElsewhere
            ) {
                removeSession(key)
            }
        }

        // 4b. AiWork sessions come from the Agentix daemon's persistent session
        //     store, which keeps every conversation as status:"active" forever and
        //     never emits a close/delete event. A finished turn or an exited TUI/GUI
        //     conversation just goes idle, so without this it would sit here for the
        //     full 10-min no-monitor timeout (Section 4) — completed eval bursts pile
        //     up in the notch. Backfill already treats idle AiWork entries as
        //     historical and skips them, so mirror that: drop an idle AiWork session
        //     shortly after its last activity. Live turns bump lastActivity on every
        //     stream event, so an in-use conversation is never swept mid-thought and
        //     re-appears the moment the next turn starts.
        let aiworkIdleGrace: TimeInterval = 60
        for (key, session) in sessions
            where key.hasPrefix(AppState.aiworkSessionPrefix)
            && session.status == .idle {
            guard -session.lastActivity.timeIntervalSinceNow > aiworkIdleGrace else { continue }
            if let daemonId = session.providerSessionId {
                forgetAiWorkHydrateState(daemonId)
            }
            removeSession(key)
        }

        // 5. Reclaim memory for abandoned tool_use_id cache entries.
        prunePendingToolUses()

        refreshDerivedState()
    }

    /// Settle a native app's thinking card idle once its transcript shows
    /// the turn ended after the card's last activity. The cleanup tick asks
    /// every 3 s while the card thinks, and the read opens the state database
    /// and reads the transcript's tail, so it runs off the main actor; the
    /// card is settled when it lands if it is still the same quiet,
    /// monitored, thinking card.
    func checkNativeAppTurnEnded(sessionId: String, session: SessionSnapshot, settleTime: TimeInterval) {
        guard nativeAppTurnReadsInFlight.insert(sessionId).inserted else { return }
        let read = storeReaders.nativeAppFinishedTurn
        Task.detached(priority: .utility) {
            let finishedAt = read(sessionId, session)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.nativeAppTurnReadsInFlight.remove(sessionId)
                guard let finishedAt,
                      let current = self.sessions[sessionId],
                      current.status == .processing,
                      current.currentTool == nil,
                      current.toolDescription == nil,
                      current.isNativeAppMode,
                      !Self.isDaemonBackedSource(current.source),
                      self.processMonitor.isWatching(sessionId),
                      -current.lastActivity.timeIntervalSinceNow >= settleTime,
                      finishedAt >= current.lastActivity.addingTimeInterval(-1) else { return }
                self.sessions[sessionId]?.status = .idle
                self.refreshDerivedState()
            }
        }
    }

    private func currentSessionProcessIdentity(for sessionId: String) -> ProcessIdentity? {
        guard let pid = sessions[sessionId]?.cliPid, pid > 0 else { return nil }
        return ProcessIdentity(pid: pid, startTime: sessions[sessionId]?.cliStartTime)
    }

    func resolvedSessionProcessIdentity(for sessionId: String) -> ProcessIdentity? {
        guard let process = currentSessionProcessIdentity(for: sessionId) else { return nil }
        if let resolved = ProcessTable.trackedProcessIdentity(for: process.pid, source: sessions[sessionId]?.source) {
            if resolved != process {
                setSessionProcessIdentity(resolved, for: sessionId)
            }
            return resolved
        }
        if process.startTime != nil { return process }
        guard let refreshed = ProcessTable.liveProcessIdentity(for: process.pid) else { return process }
        setSessionProcessIdentity(refreshed, for: sessionId)
        return refreshed
    }

    func setSessionProcessIdentity(_ process: ProcessIdentity, for sessionId: String) {
        sessions[sessionId]?.cliPid = process.pid
        sessions[sessionId]?.cliStartTime = process.startTime
    }

    private func shouldTerminateOrphanedProcess(sessionId: String, pid: pid_t) -> Bool {
        guard let session = sessions[sessionId] else { return true }
        if session.isNativeAppMode { return false }
        guard let source = SessionSnapshot.normalizedSupportedSource(session.source) else { return true }
        return !AgentProcessFinder.isNativeAppProcess(pid, source: source)
    }

    /// Watch a Claude process for exit — waits a grace period before removing, in case the
    /// process restarts (e.g. auto-update) or a new hook event re-activates the session.
    private func monitorProcess(sessionId: String, pid: pid_t) {
        guard let process = ProcessTable.liveProcessIdentity(for: pid) else {
            handleProcessExit(sessionId: sessionId, exitedProcess: ProcessIdentity(pid: pid, startTime: nil))
            return
        }
        monitorProcess(sessionId: sessionId, process: process)
    }

    private func monitorProcess(sessionId: String, process: ProcessIdentity) {
        let attached = processMonitor.watch(sessionId: sessionId, process: process) { [weak self] in
            guard let self = self, self.sessions[sessionId] != nil else { return }
            self.handleProcessExit(sessionId: sessionId, exitedProcess: process)
        }
        guard attached else { return }
        exitingSessions.removeValue(forKey: sessionId)

        // Keep cliPid aligned with the monitored process unless we already have a different
        // live PID from a stronger source (hooks beat heuristic discovery).
        if let currentProcess = resolvedSessionProcessIdentity(for: sessionId) {
            if !ProcessTable.isLiveProcess(currentProcess) || currentProcess.pid == process.pid {
                setSessionProcessIdentity(process, for: sessionId)
            }
        } else {
            setSessionProcessIdentity(process, for: sessionId)
        }

        // Safety: if process already exited before monitor started
        if !ProcessTable.isLiveProcess(process) {
            handleProcessExit(sessionId: sessionId, exitedProcess: process)
        }
    }

    /// Grace period after process exit — gives 5s for a replacement process or fresh hook event
    /// to claim the session before removal. Prevents flicker during agent restarts.
    private func handleProcessExit(sessionId: String, exitedProcess: ProcessIdentity) {
        // Tear down the dead monitor immediately
        stopMonitor(sessionId)

        // If the session already moved to a replacement live PID, reattach immediately and
        // avoid flashing idle because a stale/wrong monitor exited.
        if let currentProcess = resolvedSessionProcessIdentity(for: sessionId),
           currentProcess != exitedProcess, ProcessTable.isLiveProcess(currentProcess) {
            monitorProcess(sessionId: sessionId, process: currentProcess)
            return
        }

        if exitingSessions[sessionId] == exitedProcess {
            return
        }
        exitingSessions[sessionId] = exitedProcess

        // If session was actively doing something, reset state right away so the UI
        // doesn't show a stale "running Edit" while we wait through the grace period.
        if let status = sessions[sessionId]?.status, status != .idle {
            sessions[sessionId]?.status = .idle
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
            // Drain any pending permissions/questions — the process is gone
            drainPermissions(forSession: sessionId, reason: "process-exited")
            drainQuestions(forSession: sessionId, reason: "process-exited")
            refreshDerivedState()
        }

        let exitTime = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self = self, self.sessions[sessionId] != nil else { return }
            guard self.exitingSessions[sessionId] == exitedProcess else { return }

            // A new monitor was attached during the grace period (new process took over)
            if self.processMonitor.isWatching(sessionId) { return }

            // Session was taken over by a different process (e.g. auto-update/restart):
            // cliPid changed to a new PID that's still alive → attach monitor, don't remove.
            if let currentProcess = self.resolvedSessionProcessIdentity(for: sessionId),
               currentProcess != exitedProcess, ProcessTable.isLiveProcess(currentProcess) {
                self.monitorProcess(sessionId: sessionId, process: currentProcess)
                return
            }

            // Original process confirmed dead — remove regardless of lastActivity.
            // This prevents a race where an in-flight hook event (e.g. "Stop") updates
            // lastActivity after exitTime, causing the session to linger for 10+ minutes.
            if !ProcessTable.isLiveProcess(exitedProcess) {
                self.removeSession(sessionId)
                return
            }

            // Session received fresh activity during the grace period and the original PID is
            // still alive — the exit signal was stale/spurious, so restore monitoring.
            if let lastActivity = self.sessions[sessionId]?.lastActivity,
               lastActivity > exitTime {
                self.monitorProcess(sessionId: sessionId, process: exitedProcess)
                return
            }

            self.removeSession(sessionId)
        }
    }

    func stopMonitor(_ sessionId: String) {
        processMonitor.stop(sessionId)
    }

    /// Start monitoring the CLI process for a session.
    /// Prefers the PID captured by the bridge (_ppid), falls back to source-aware process scans by CWD.
    func tryMonitorSession(_ sessionId: String) {
        guard sessions[sessionId]?.isRemote != true else { return }
        // Codex Desktop cards are owned by NSWorkspace/app-server lifecycle. A
        // CWD lookup can only find an unrelated Codex CLI process (or the
        // shared Desktop helper), and binding either PID would remove every
        // Desktop thread when that one process exits. Other native providers
        // keep their existing monitor behavior.
        if sessions[sessionId]?.source == "codex",
           sessions[sessionId]?.termBundleId == Self.codexAppBundleId {
            stopMonitor(sessionId)
            sessions[sessionId]?.cliPid = nil
            sessions[sessionId]?.cliStartTime = nil
            exitingSessions.removeValue(forKey: sessionId)
            return
        }
        let currentMonitor = processMonitor.watchedProcess(for: sessionId)

        // Primary: use PID from bridge (works for any CLI)
        if let sessionProcess = resolvedSessionProcessIdentity(for: sessionId),
           ProcessTable.isLiveProcess(sessionProcess) {
            if backfillClaudeTerminalMetadata(sessionId: sessionId, process: sessionProcess) {
                scheduleSave()
            }
            if currentMonitor == sessionProcess { return }
            if currentMonitor != nil {
                stopMonitor(sessionId)
            }
            monitorProcess(sessionId: sessionId, process: sessionProcess)
            return
        }

        if let currentMonitor, ProcessTable.isLiveProcess(currentMonitor) {
            setSessionProcessIdentity(currentMonitor, for: sessionId)
            if backfillClaudeTerminalMetadata(sessionId: sessionId, process: currentMonitor) {
                scheduleSave()
            }
            return
        }

        // Fallback: scan for matching processes by CWD (source-aware)
        guard let cwd = sessions[sessionId]?.cwd else { return }
        let source = sessions[sessionId]?.source
        Task.detached {
            let pid = AgentProcessFinder.findPidForCwd(cwd, source: source)
            await MainActor.run { [weak self] in
                guard let self = self, let pid = pid,
                      self.sessions[sessionId] != nil else { return }
                guard let discoveredProcess = ProcessTable.liveProcessIdentity(for: pid) else { return }

                let preferredProcess: ProcessIdentity
                if let currentProcess = self.resolvedSessionProcessIdentity(for: sessionId),
                   ProcessTable.isLiveProcess(currentProcess) {
                    preferredProcess = currentProcess
                } else {
                    preferredProcess = discoveredProcess
                    self.setSessionProcessIdentity(discoveredProcess, for: sessionId)
                }

                if self.backfillClaudeTerminalMetadata(sessionId: sessionId, process: preferredProcess) {
                    self.scheduleSave()
                }
                if let monitorProcess = self.processMonitor.watchedProcess(for: sessionId),
                   monitorProcess == preferredProcess, ProcessTable.isLiveProcess(monitorProcess) {
                    return
                }

                if self.processMonitor.isWatching(sessionId) {
                    self.stopMonitor(sessionId)
                }
                self.monitorProcess(sessionId: sessionId, process: preferredProcess)
            }
        }
    }
}
