import SwiftUI
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "AppState")

/// AppState's answers to the Agent Sub-Sessions resolvers, taken on the main
/// actor for one hook (``AppState/subsessionContext``).
struct AppSubsessionContext: SubsessionContext {
    let cards: [String: SessionSnapshot]
    let codexRollouts: CodexRolloutCache

    func codexRolloutInspection(transcriptPath: String) -> CodexTranscriptSubagentInspection {
        codexRollouts.inspection(transcriptPath: transcriptPath)
    }
}

/// The session store the island's views observe, and the coordinator around
/// it, on the main actor: hook events, approvals and questions, completions
/// and attention land here. The slow work it coordinates runs elsewhere —
/// session discovery in `SessionDiscoveryCoordinator` and the `Discovery/`
/// namespaces, a known card's store reads through `SessionStoreReaders`,
/// both off the main actor; exit watches in `SessionProcessMonitor`; the
/// compact bar's rotation in `CompactBarRotation` — and AppState integrates
/// what they find.
@MainActor
@Observable
final class AppState {
    /// Snapshot of a hook event accepted by HookServer, kept for diagnostics
    /// export (#103). Stored in a fixed-size ring so we can attach the recent
    /// hook stream to bug reports without pulling in full payloads.
    ///
    /// `payloadKeys` lists the top-level JSON field names the hook arrived
    /// with (sorted, no values), and `promptPreview` is a 80-char prefix of
    /// any extracted user prompt. Together those let us tell at a glance
    /// whether a hook fired with an empty / missing prompt vs. fired with a
    /// prompt that the UI then dropped.
    struct DiagnosticHookEvent: Sendable {
        let timestamp: Date
        let source: String?
        let sessionId: String?
        let eventName: String
        let toolName: String?
        let viaPlugin: Bool
        let payloadKeys: [String]
        let promptPreview: String?
    }

    var sessions: [String: SessionSnapshot] = [:]
    var activeSessionId: String?
    var permissionQueue: [PermissionRequest] = [] {
        didSet {
            followUps.waitingChanged()
            PushNotifier.shared.requestsChanged()
        }
    }
    var questionQueue: [QuestionRequest] = [] {
        didSet {
            // A close lasts as long as its request: once answered, skipped or
            // drained, its id is forgotten.
            if !dismissedQuestionIds.isEmpty {
                let queued = Set(questionQueue.map(\.id))
                if !dismissedQuestionIds.isSubset(of: queued) {
                    dismissedQuestionIds.formIntersection(queued)
                }
            }
            followUps.waitingChanged()
            PushNotifier.shared.requestsChanged()
        }
    }
    /// Follow-up reminders for waiting approvals / questions and unseen
    /// completions. Holds no entries and arms no timer while the setting is off.
    @ObservationIgnored
    private(set) lazy var followUps = FollowUpReminderController(appState: self)
    /// What each display-only wait asks, recorded by the source that opened
    /// it, for its pushes. See AppState+DisplayOnlyWaits.
    @ObservationIgnored
    var displayOnlyWaitAsks: [String: PushContent] = [:]

    @ObservationIgnored
    private(set) var recentHookEvents: [DiagnosticHookEvent] = []
    @ObservationIgnored
    private let maxRecentHookEvents = 100
    @ObservationIgnored
    var questionTerminalFrontmostDetector: (SessionSnapshot) -> Bool =
        TerminalVisibilityDetector.isTerminalFrontmostForSession

    func recordHookEvent(
        source: String?,
        sessionId: String?,
        eventName: String,
        toolName: String?,
        viaPlugin: Bool,
        payloadKeys: [String],
        promptPreview: String?
    ) {
        recentHookEvents.append(DiagnosticHookEvent(
            timestamp: Date(),
            source: source,
            sessionId: sessionId,
            eventName: eventName,
            toolName: toolName,
            viaPlugin: viaPlugin,
            payloadKeys: payloadKeys,
            promptPreview: promptPreview
        ))
        if recentHookEvents.count > maxRecentHookEvents {
            recentHookEvents.removeFirst(recentHookEvents.count - maxRecentHookEvents)
        }
    }
    /// Cache of in-flight PreToolUse records keyed by tool_use_id. Used to correlate
    /// permission requests back to their originating tool call. See AppState+ToolUseCache.
    @ObservationIgnored
    var pendingToolUses: [String: PreToolUseRecord] = [:]
    /// Records the transcript path currently watched for each session so we only
    /// reattach when the path actually changes. See AppState+TranscriptTailer.
    @ObservationIgnored
    var attachedTranscriptPaths: [String: String] = [:]
    /// Token for the exact JSONLTailer attachment currently owned by a session.
    /// A queued delta from an older attachment must not mutate a same-id session
    /// that was closed and subsequently re-created.
    @ObservationIgnored
    var attachedTranscriptTokens: [String: UUID] = [:]
    /// Attach-time checklist scans still running off the main actor, keyed by
    /// session. See AppState+AgentTasks.
    @ObservationIgnored
    var pendingAgentTaskBackfills: [String: PendingAgentTaskBackfill] = [:]
    /// Watches active session transcripts for appended assistant lines. Lazily
    /// constructed so the delta handler can safely capture `self`.
    @ObservationIgnored
    lazy var transcriptTailer: JSONLTailer = JSONLTailer { [weak self] delta in
        Task { @MainActor in
            self?.applyTranscriptDelta(delta)
        }
    }
    /// Active JSON-RPC client connected to `codex app-server`, or nil when
    /// Codex Desktop isn't running. See AppState+CodexAppServer.
    @ObservationIgnored
    var codexAppServerClient: CodexAppServerClient?
    /// NSWorkspace launch/terminate observers tracking Codex Desktop.
    @ObservationIgnored
    var codexAppServerObservers: [NSObjectProtocol]?
    /// Backoff loop used when the auxiliary app-server exits while the Desktop
    /// host remains open.
    @ObservationIgnored
    nonisolated(unsafe) var codexAppServerReconnectTask: Task<Void, Never>?
    /// Prevent an in-flight/stale state-DB scan from recreating a thread after
    /// app-server delivered `thread/closed`.
    @ObservationIgnored
    var closedCodexAppThreads: [String: Date] = [:]
    /// Grok sessions retired because their pager process started another
    /// session (#318), mapped to that process. While it lives, discovery and
    /// trailing passive hooks must not resurrect the card; a new prompt or
    /// SessionStart for the session means the user switched back to it.
    @ObservationIgnored
    var supersededGrokSessions: [String: ProcessIdentity] = [:]
    /// Cursor gives its own hooks and the Claude Code hooks it imports one
    /// payload per step, and CodeIsland is wired into both, so a `stop` or a
    /// `beforeSubmitPrompt` arrives twice (#377). See ``CursorHookPayload``.
    @ObservationIgnored
    var cursorHookDeliveries = CursorHookDeliveryFilter()

    /// Per-agent AiWork/Agentix daemon watch clients (`sessions.watch`).
    /// Keyed by agent id (e.g. `"coder"`). See AppState+AiWorkWatch.
    @ObservationIgnored
    var aiworkWatchClients: [String: AiWorkWatchClient] = [:]
    /// Periodic reconnect / rediscovery timer for Agentix daemons.
    @ObservationIgnored
    var aiworkWatchReconnectTimer: Timer?
    /// Daemon session ids that already received a `sessions.get` title/cwd hydrate.
    @ObservationIgnored
    var aiworkHydratedSessionIds: Set<String> = []
    /// When a `sessions.get` hydrate last failed, per daemon session id. The id
    /// stays in `aiworkHydratedSessionIds` until the cooldown elapses, so a
    /// failing daemon is not re-dialled on every streamed token.
    @ObservationIgnored
    var aiworkHydrateFailedAt: [String: Date] = [:]
    /// Agentix state dir to discover daemons under; nil = `$AGENTIX_STATE_DIR`
    /// or `~/.agentix`. Tests point this at a temp dir so they never reach a
    /// real daemon on the developer's machine.
    @ObservationIgnored
    var aiworkStateDirOverride: String?
    /// Guards overlapping `agent.stats` reconciles from the 3s rediscovery timer.
    @ObservationIgnored
    var aiworkReconcileInFlight = false

    /// Claude Desktop Cowork/Chat session-store watcher; nil while the setting
    /// is off. See AppState+CoworkWatch.
    @ObservationIgnored
    var coworkWatcher: CoworkSessionWatcher?
    /// The Claude Desktop process each in-flight Cowork turn runs in, and
    /// how to find the running one (a seam for tests).
    @ObservationIgnored
    var coworkTurnHosts: [String: ProcessIdentity] = [:]
    @ObservationIgnored
    var claudeDesktopProcessProvider: () -> ProcessIdentity? = { AppState.runningClaudeDesktopProcess() }
    @ObservationIgnored
    var claudeDesktopTerminationObserver: NSObjectProtocol?

    /// Computed: first item in permission queue (backward compat for UI reads)
    var pendingPermission: PermissionRequest? { permissionQueue.first }
    /// Computed: first item in question queue
    var pendingQuestion: QuestionRequest? { questionQueue.first }

    /// The queued request belonging to a specific session. A card is addressed
    /// by session, so it must render (and resolve) that session's request
    /// rather than whatever currently sits at the head of the queue. (#308)
    func pendingPermission(forSession sessionId: String) -> PermissionRequest? {
        permissionQueue.first { ($0.event.sessionId ?? "default") == sessionId }
    }

    func pendingQuestion(forSession sessionId: String) -> QuestionRequest? {
        questionQueue.first { ($0.event.sessionId ?? "default") == sessionId }
    }

    /// 1-based position for a card's "N of M" label. The card may be showing a
    /// request that is not the head, so the position has to be looked up. (#308)
    func permissionQueuePosition(forSession sessionId: String) -> Int {
        (permissionQueue.firstIndex { ($0.event.sessionId ?? "default") == sessionId } ?? 0) + 1
    }

    func questionQueuePosition(forSession sessionId: String) -> Int {
        (questionQueue.firstIndex { ($0.event.sessionId ?? "default") == sessionId } ?? 0) + 1
    }
    /// Preview-only: mock question payload for DebugHarness (no continuation needed)
    var previewQuestionPayload: QuestionPayload?
    var surface: IslandSurface = .collapsed {
        didSet {
            // Any expansion counts as "seen" for the glance completion dot.
            if surface.isExpanded, glanceCompletionActive {
                glanceDismissTask?.cancel()
                glanceCompletionActive = false
            }
            if surface.isExpanded {
                refreshClaudeUsageIfStale()
                claudeQuota.noteExpanded()
            } else {
                claudeQuota.noteCollapsed()
            }
            if surface != oldValue {
                followUps.surfaceChanged(surface)
            }
            switch surface {
            case .approvalCard(let sid): cardRequestId = pendingPermission(forSession: sid)?.id
            case .questionCard(let sid): cardRequestId = pendingQuestion(forSession: sid)?.id
            case .collapsed, .sessionList, .completionCard: cardRequestId = nil
            }
        }
    }

    /// The request the approval / question card on screen was opened for.
    /// While that very request still waits, re-evaluating the queue leaves
    /// the card alone — it may be one the user picked that is not the head.
    /// Once it is answered, the session's next request filling the same card
    /// is weighed like any other.
    @ObservationIgnored
    private var cardRequestId: UUID?

    /// Index of the approval the card on screen still shows, when it is
    /// still waiting and visible.
    private var shownApprovalIndex: Int? {
        guard let cardRequestId, case .approvalCard(let sid) = surface,
              !dismissedPermissionSessionIds.contains(sid),
              pendingPermission(forSession: sid)?.id == cardRequestId else { return nil }
        return permissionQueue.firstIndex { $0.id == cardRequestId }
    }

    /// The session of the question card on screen, when the question it was
    /// opened for still waits.
    private var shownQuestionSessionId: String? {
        guard let cardRequestId, case .questionCard(let sid) = surface,
              pendingQuestion(forSession: sid)?.id == cardRequestId else { return nil }
        return sid
    }

    /// Local-transcript token usage shown in the session-list footer.
    /// Refreshed lazily on panel expansion (no resident timer, no API calls).
    var claudeUsage: ClaudeUsageScanner.Snapshot?
    /// Subscription rate limits (5h / weekly) from Anthropic — opt-in, network.
    let claudeQuota = ClaudeQuotaMonitor()
    /// Process-wide, not per-instance: the scan reads one shared history
    /// (`~/.claude`), so two concurrent runs are always duplicate work. Production
    /// has a single AppState and never noticed, but anything constructing several —
    /// the test bundle does — otherwise starts N cold scans at once on the shared
    /// `.utility` cooperative pool and starves every other detached probe on it
    /// (git-branch resolution among them).
    private static var usageScanInFlight = false
    /// Incremental parse state — round-trips through each detached scan so
    /// growing transcripts are only read past their last consumed offset.
    private var usageFileCache = ClaudeUsageScanner.FileCache()

    /// Glance completion mode: an agent finished while the pill was collapsed —
    /// light the dot instead of expanding. Cleared when the user expands the
    /// panel, with a long failsafe so a missed dot never lingers forever.
    var glanceCompletionActive = false
    private var glanceDismissTask: Task<Void, Never>?

    var justCompletedSessionId: String? {
        if case .completionCard(let id) = surface { return id }
        return nil
    }

    private var maxHistory: Int { SettingsManager.shared.maxToolHistory }
    /// Torn down from `deinit`, which may run off the main actor (e.g. async
    /// XCTest ARC). Only mutated on the main actor while `self` is alive.
    @ObservationIgnored
    nonisolated(unsafe) private var cleanupTimer: Timer?
    private var autoCollapseTask: Task<Void, Never>?
    /// How long a completion card stays up on its own. Tests shorten it.
    @ObservationIgnored
    var completionAutoCollapseDelay: TimeInterval = 5
    private var completionQueue: [String] = []
    /// The queued completion whose card waits on Smart Suppress's look at
    /// its session's tab (off the main thread). It is the next card on its
    /// way: nothing else leaves the queue meanwhile.
    @ObservationIgnored
    private var queuedCompletionLookingAtTab: String?
    /// Mouse must enter the panel before auto-collapse is allowed (prevents instant dismiss)
    var completionHasBeenEntered = false {
        // The pointer on the completion card is the one proof the turn was seen.
        didSet {
            if completionHasBeenEntered, let sid = justCompletedSessionId {
                followUps.completionSeen(sessionId: sid)
            }
        }
    }
    /// Auto-collapse timer fired but mouse is inside panel — defer collapse until mouse leaves
    var deferCollapseOnMouseLeave = false
    /// Exit watches on the sessions' local CLI processes.
    let processMonitor = SessionProcessMonitor()
    /// Sessions in the grace period after their process exited, with that process.
    var exitingSessions: [String: ProcessIdentity] = [:]
    @ObservationIgnored
    nonisolated(unsafe) var saveTimer: Timer?
    /// Session discovery: the session-store watcher and the scans it runs off
    /// the main actor, whose sessions land in `integrateDiscovered`.
    @ObservationIgnored
    private(set) lazy var discovery: SessionDiscoveryCoordinator = {
        let discovery = SessionDiscoveryCoordinator()
        discovery.onDiscovered = { [weak self] in self?.integrateDiscovered($0) }
        return discovery
    }()
    /// Cursor Agent Task transcripts on disk, for rebranding default-Claude
    /// Task cards and folding Cursor-labelled ones. Built off the main actor;
    /// see `rebrandMisattributedCursorTaskCards`.
    @ObservationIgnored
    var cursorSubagentIndex: CursorSubagentTranscriptIndex?
    @ObservationIgnored
    nonisolated(unsafe) var cursorSubagentIndexTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) var cursorSubagentIndexRecheck: Task<Void, Never>?
    /// When `cursorSubagentIndexRecheck` fires.
    @ObservationIgnored
    var cursorSubagentIndexRecheckAt: Date?
    /// The lookup schedule of each card the index does not resolve.
    @ObservationIgnored
    var cursorSubagentLookups: [String: CursorSubagentLookupSchedule] = [:]
    /// When such a card is looked up after it first goes unresolved. Tests shorten it.
    @ObservationIgnored
    var cursorSubagentLookupDelays = CursorSubagentLookupSchedule.defaultDelays
    /// What each Codex thread's rollout says about its parent: Agent
    /// Sub-Sessions asks on every Codex hook, and reads a rollout once.
    @ObservationIgnored
    let codexRollouts = CodexRolloutCache(read: { CodexDiscovery.inspectCodexSubagentMetadata(inTranscriptPath: $0) })
    private var isShowingCompletion: Bool {
        if case .completionCard = surface { return true }
        return false
    }
    /// True when an interactive card (approval or question) is visible — completions must queue.
    private var isShowingInteractive: Bool {
        switch surface {
        case .approvalCard, .questionCard: return true
        default: return false
        }
    }
    private var modelReadRetryAt: [String: Date] = [:]
    /// Cards whose model (`maybeBackfillModel`), YOLO setting or native-app
    /// turn end is being read off the main actor.
    @ObservationIgnored
    private(set) var modelReadsInFlight: Set<String> = []
    @ObservationIgnored
    private(set) var cursorYoloReadsInFlight: Set<String> = []
    @ObservationIgnored
    var nativeAppTurnReadsInFlight: Set<String> = []
    /// The reads of the agents' own stores made for a known card, run off
    /// the main actor (see `SessionStoreReaders`). Tests install their own.
    @ObservationIgnored
    var storeReaders = SessionStoreReaders.live
    /// Per parent session → subagent id: the subagent's own model/effort once
    /// read from its transcript, and the reads still trying to find it.
    @ObservationIgnored
    var subagentModelObservations: [String: [String: ModelObservation]] = [:]
    @ObservationIgnored
    var subagentModelReads: [String: [String: SubagentModelRead]] = [:]
    /// Per local Hermes session: the read of Hermes's own store in progress.
    @ObservationIgnored
    var hermesStoreReads: [String: HermesStoreRead] = [:]

    private var dismissedPermissionSessionIds: Set<String> = [] {
        didSet { followUps.waitingChanged() }
    }
    private func nextVisiblePermissionIndex() -> Int? {
        permissionQueue.firstIndex { request in
            let sid = request.event.sessionId ?? "default"
            return !dismissedPermissionSessionIds.contains(sid)
        }
    }

    /// Sessions whose approval is still waiting on the user: queued and not
    /// dismissed. Dismissing hides a request without dequeuing it (#309), so
    /// the queue alone would keep reminding about a prompt the user hid.
    var visiblePermissionSessionIds: Set<String> {
        Set(permissionQueue.map { $0.event.sessionId ?? "default" })
            .subtracting(dismissedPermissionSessionIds)
    }

    /// The request each of those sessions' approval card shows — its first
    /// queued one — by session. Follow-up reminders belong to that request.
    var visiblePermissionRequestIds: [String: String] {
        var ids: [String: String] = [:]
        for request in permissionQueue {
            let sid = request.event.sessionId ?? "default"
            guard ids[sid] == nil, !dismissedPermissionSessionIds.contains(sid) else { continue }
            ids[sid] = request.id.uuidString
        }
        return ids
    }

    /// Question requests the user closed without answering. Unlike approvals
    /// these are keyed by request, not session: a new question from the same
    /// session is a new thing to see. Hidden, never resolved — the agent keeps
    /// waiting, and the collapsed bar's question badge reopens the card.
    private(set) var dismissedQuestionIds: Set<UUID> = [] {
        didSet { followUps.waitingChanged() }
    }

    /// The question each session's card shows — its first queued one — in
    /// queue order, for the sessions whose card the user has not closed. That
    /// first question decides: a later one from the same session (a
    /// subagent's) waits behind a closed card instead of reopening it on the
    /// question the user just put away.
    private var visibleQuestionCards: [QuestionRequest] {
        var seen = Set<String>()
        return questionQueue.filter { request in
            seen.insert(request.event.sessionId ?? "default").inserted
                && !dismissedQuestionIds.contains(request.id)
        }
    }

    /// The first question whose card the user has not closed — what may open
    /// by itself, and what a question shortcut acts on.
    var nextVisibleQuestion: QuestionRequest? {
        visibleQuestionCards.first
    }

    /// Question counterpart of `visiblePermissionRequestIds`: closed cards are
    /// left out, so follow-up reminders stop for a card the user put away.
    var pendingQuestionRequestIds: [String: String] {
        var ids: [String: String] = [:]
        for request in visibleQuestionCards {
            ids[request.event.sessionId ?? "default"] = request.id.uuidString
        }
        return ids
    }

    /// The compact bar's mascot rotation through the active sessions.
    let rotation = CompactBarRotation()
    var rotatingSessionId: String? { rotation.rotatingSessionId }
    var rotatingSession: SessionSnapshot? {
        guard let rid = rotatingSessionId else { return nil }
        return sessions[rid]
    }

    func startCleanupTimer() {
        guard cleanupTimer == nil else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupIdleSessions()
            }
        }
    }

    /// Agent Sub-Sessions as set now; an unknown setting reads as Show
    /// separately, the default (HookServer routes hooks by the same reading).
    nonisolated static func currentPluginSessionMode() -> SubsessionMode {
        SubsessionMode(
            setting: UserDefaults.standard.string(forKey: SettingsKey.pluginSessionMode)
                ?? SettingsDefaults.pluginSessionMode
        )
    }

    // MARK: - Removing a session

    /// Remove a session, clean up its monitor, and resume any pending continuations.
    /// Every removal path (cleanup timer, process exit, reducer effect) goes through here
    /// so leaked continuations / connections are impossible.
    func removeSession(_ sessionId: String) {
        let displayOnlyWaitBefore = displayOnlyWaitKind(forSession: sessionId)
        // Resume ALL pending continuations for this session
        drainPermissions(forSession: sessionId, reason: "removeSession")
        drainQuestions(forSession: sessionId, reason: "removeSession")

        completionQueue.removeAll { $0 == sessionId }
        if surface.sessionId == sessionId {
            autoCollapseTask?.cancel()
            if case .completionCard = surface {
                // The turn on this card belongs to a session that is going
                // away: nothing is left on it to read, pointer on it or not.
                completionHasBeenEntered = false
                deferCollapseOnMouseLeave = false
                showNextCompletionOrCollapse()
            } else {
                _ = showNextPending()
            }
        }
        sessions.removeValue(forKey: sessionId)
        noteDisplayOnlyWait(sessionId: sessionId, was: displayOnlyWaitBefore)
        stopMonitor(sessionId)
        detachTranscriptTailer(sessionId: sessionId)
        exitingSessions.removeValue(forKey: sessionId)
        modelReadRetryAt.removeValue(forKey: sessionId)
        subagentModelObservations.removeValue(forKey: sessionId)
        subagentModelReads.removeValue(forKey: sessionId)
        hermesStoreReads.removeValue(forKey: sessionId)
        hostHarnessProbes.removeValue(forKey: sessionId)
        hostHarnessProbeRetryAt.removeValue(forKey: sessionId)
        claudeTerminalProbes.removeValue(forKey: sessionId)
        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }
        startRotationIfNeeded()
        refreshDerivedState()
        scheduleSave()
    }

    // MARK: - Compact bar mascot rotation

    func startRotationIfNeeded() {
        // When rotation stops, ensure activeSessionId points to the remaining
        // active session (if any) so the collapsed bar doesn't stick on an idle one.
        if let active = rotation.update(sessions: sessions),
           activeSessionId != active {
            activeSessionId = active
        }
    }

    typealias CompletionStyle = CodeIslandCore.CompletionStyle

    /// Three-way completion notification style. Migration: the pre-glance
    /// boolean `autoExpandOnCompletion` (#146) maps false → .off; anything
    /// else (including "never set", which registers as true) → .expand.
    nonisolated static func completionStyle(defaults: UserDefaults = .standard) -> CompletionStyle {
        if let raw = defaults.string(forKey: SettingsKey.completionNotificationStyle),
           let style = CompletionStyle(rawValue: raw) {
            return style
        }
        if defaults.object(forKey: SettingsKey.autoExpandOnCompletion) != nil,
           defaults.bool(forKey: SettingsKey.autoExpandOnCompletion) == false {
            return .off
        }
        return .expand
    }

    /// Announce a finished turn the way `AttentionPolicy` decided: the card's
    /// ERROR mark (`turnFailed`: a StopFailure, a failed AiWork stream or
    /// Cowork turn), the follow-up, then the completion card or the glance dot.
    func announceCompletion(_ decision: AttentionDecision, sessionId: String) {
        guard let completion = decision.completion else { return }
        // The session card reads ERROR until the next prompt.
        sessions[sessionId]?.lastTurnFailed = completion.turnFailed
        if case .trackCompletion(let turnFailed)? = decision.followUp {
            followUps.trackCompletion(sessionId: sessionId, turnFailed: turnFailed)
        }
        switch completion.presentation {
        case .statusOnly:
            // Panel stays compact — status indicators still update, but no
            // completion card pops down (#146).
            return
        case .glance:
            flashGlanceCompletionIndicator()
            return
        case .card:
            // Don't queue duplicates
            if completionQueue.contains(sessionId) || justCompletedSessionId == sessionId { return }

            // Already showing one, or one is on its way out of the queue —
            // queue this for later
            if isShowingCompletion || isShowingInteractive || queuedCompletionLookingAtTab != nil {
                completionQueue.append(sessionId)
            } else {
                // Show immediately
                showCompletion(sessionId)
            }
        }
    }

    /// Prewarm at launch so the footer doesn't pop in (and shift panel height)
    /// on the first expansion.
    func refreshClaudeUsageIfStale() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.showUsageStats) else { return }
        guard !Self.usageScanInFlight else { return }
        if let scannedAt = claudeUsage?.scannedAt, Date().timeIntervalSince(scannedAt) < 120 { return }
        Self.usageScanInFlight = true
        let cacheCopy = usageFileCache
        Task.detached(priority: .utility) {
            var cache = cacheCopy
            let snapshot = ClaudeUsageScanner.scan(claudeHomes: ClaudeConfigPaths.allConfigDirs(), cache: &cache)
            // Bound to a `let` before the hop: capturing the `var` in the
            // concurrently-executing closure is an error under Swift 6.
            let scannedCache = cache
            await MainActor.run { [weak self] in
                self?.claudeUsage = snapshot
                self?.usageFileCache = scannedCache
                AppState.usageScanInFlight = false
            }
        }
    }

    /// Last unresolved-branch probe per session — keeps `gitBranch == nil`
    /// (non-repo cwds, SessionStart snapshot rebuilds) from probing on every event.
    private var gitBranchCheckedAt: [String: Date] = [:]

    /// Branch resolution runs detached: .git probing on a dead network mount
    /// must never beachball the main actor. Triggers on cwd changes, at Stop
    /// (the turn may have switched branches), and while unresolved (throttled).
    func maybeRefreshGitBranch(for sessionId: String, cwdBefore: String?, normalizedEventName: String) {
        guard let session = sessions[sessionId],
              session.remoteHostId == nil,
              let cwd = session.cwd else { return }
        let unresolvedDue = session.gitBranch == nil
            && Date().timeIntervalSince(gitBranchCheckedAt[sessionId] ?? .distantPast) > 60
        guard cwd != cwdBefore || normalizedEventName == "Stop" || unresolvedDue else { return }
        gitBranchCheckedAt[sessionId] = Date()
        Task.detached(priority: .utility) {
            let info = GitBranchReader.read(cwd: cwd)
            await MainActor.run { [weak self] in
                guard let self, var s = self.sessions[sessionId], s.cwd == cwd else { return }
                s.gitBranch = info?.branch
                s.gitIsWorktree = info?.isWorktree ?? false
                self.sessions[sessionId] = s
            }
        }
    }

    /// Last conclusive host-harness probe per session, keyed to the CLI pid it
    /// walked. A SessionStart rebuilds the snapshot; the cache lets the result
    /// be re-applied without walking the ancestry again. (#321)
    private var hostHarnessProbes: [String: (pid: pid_t, harness: HostHarness?)] = [:]
    private var hostHarnessProbesInFlight: Set<String> = []
    /// Throttle for probes that could not read the process (it had already
    /// exited, or the pid is a short-lived hook shell) — retried, not cached.
    private var hostHarnessProbeRetryAt: [String: Date] = [:]
    /// The Claude process whose environment `backfillClaudeTerminalMetadata`
    /// already read, per session. tryMonitorSession runs on every hook event
    /// and discovery scan, and an environment is fixed at exec, so one read
    /// per process is all there is to learn.
    @ObservationIgnored
    var claudeTerminalProbes: [String: ProcessIdentity] = [:]

    /// Detect a UI harness (T3 Code) in the CLI's ancestry, off the main actor.
    /// Runs once per CLI pid; remote sessions never probe the local process table.
    func maybeResolveHostHarness(for sessionId: String) {
        guard let session = sessions[sessionId],
              !session.isRemote,
              let pid = session.cliPid, pid > 1 else { return }
        if let cached = hostHarnessProbes[sessionId], cached.pid == pid {
            if session.hostHarness != cached.harness {
                sessions[sessionId]?.hostHarness = cached.harness
            }
            return
        }
        guard !hostHarnessProbesInFlight.contains(sessionId),
              Date() >= hostHarnessProbeRetryAt[sessionId] ?? .distantPast else { return }
        hostHarnessProbesInFlight.insert(sessionId)
        Task.detached(priority: .utility) {
            let result = HostHarnessSupport.probe(cliPid: pid)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.hostHarnessProbesInFlight.remove(sessionId)
                guard self.sessions[sessionId]?.cliPid == pid else { return }
                if result.conclusive {
                    self.hostHarnessProbes[sessionId] = (pid, result.harness)
                    self.hostHarnessProbeRetryAt.removeValue(forKey: sessionId)
                } else {
                    self.hostHarnessProbeRetryAt[sessionId] = Date().addingTimeInterval(10)
                }
                if self.sessions[sessionId]?.hostHarness != result.harness {
                    self.sessions[sessionId]?.hostHarness = result.harness
                }
            }
        }
    }

    private func flashGlanceCompletionIndicator() {
        guard !surface.isExpanded else { return }  // user is already looking
        glanceCompletionActive = true
        glanceDismissTask?.cancel()
        glanceDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard !Task.isCancelled else { return }
            glanceCompletionActive = false
        }
    }

    /// Notification kinds that describe the *account*, not the conversation.
    /// CodeBuddy's documented `notification_type` set is `permission_prompt`,
    /// `idle_prompt`, `auth_success`; only the last is boot-time auth chatter,
    /// and it arrives before `SessionStart` with its own session id. Matching by
    /// prefix so a future `auth_failed`/`auth_expired` behaves the same. (#288)
    nonisolated static func isAccountNotification(_ event: HookEvent) -> Bool {
        guard let kind = notificationKind(from: event) else { return false }
        return kind.hasPrefix("auth")
    }

    /// Whether a permission request may expand the island on its own. Smart
    /// Suppress only covers "the agent's own terminal is in front"; users who
    /// work in a *different* app still got the panel thrown in their face on
    /// every approval. With this off the sound and the session-list badge still
    /// fire and the card is one click away, but focus is never stolen. (#292)
    static func autoExpandOnPermission(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: SettingsKey.autoExpandOnPermission) != nil else {
            return SettingsDefaults.autoExpandOnPermission
        }
        return defaults.bool(forKey: SettingsKey.autoExpandOnPermission)
    }

    /// The question counterpart of `autoExpandOnPermission`. Questions never
    /// honoured that switch — an AskUserQuestion card opened even when the
    /// user had asked the island not to steal focus. With this off the sound
    /// still plays, the collapsed bar shows a question badge, and one click
    /// (on the bar, or "Answer" in the session list) opens the card.
    static func autoExpandOnQuestion(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: SettingsKey.autoExpandOnQuestion) != nil else {
            return SettingsDefaults.autoExpandOnQuestion
        }
        return defaults.bool(forKey: SettingsKey.autoExpandOnQuestion)
    }

    /// Session of a queued question the island is not showing — what the
    /// collapsed bar's question badge advertises and a click opens.
    var hiddenPendingQuestionSessionId: String? {
        // A question still waiting to be seen comes before one the user closed.
        guard let head = nextVisibleQuestion ?? questionQueue.first else { return nil }
        if case .questionCard = surface { return nil }
        return head.event.sessionId ?? "default"
    }

    /// Open the card for a pending question on an explicit user action (a click
    /// on the collapsed bar, "Answer" in the session list). Never gated by
    /// auto-expand or Smart Suppress: those only decide what opens *by itself*.
    func openPendingQuestionCard(sessionId: String? = nil) {
        guard let sid = sessionId ?? hiddenPendingQuestionSessionId,
              let request = pendingQuestion(forSession: sid) else { return }
        // Opening it again takes back a close: it is on screen, so it may
        // stay up and remind like any other waiting question.
        dismissedQuestionIds.remove(request.id)
        activeSessionId = sid
        withAnimation(NotchAnimation.open) {
            surface = .questionCard(sessionId: sid)
        }
    }

    func shouldAutoOpenPendingSurface(
        for sessionId: String,
        isTerminalFrontmost: (SessionSnapshot) -> Bool = TerminalVisibilityDetector.isTerminalFrontmostForSession
    ) -> Bool {
        guard UserDefaults.standard.bool(forKey: SettingsKey.smartSuppress) else { return true }
        guard let session = sessions[sessionId],
              (session.termApp != nil || session.termBundleId != nil) else { return true }
        return !isTerminalFrontmost(session)
    }

    /// Smart Suppress for a question: may its card open by itself, as far as
    /// "is the user already looking at the agent" goes? The "auto-expand on
    /// question" switch is a separate, UI-only choice checked where the card
    /// opens; folded in here, it read as "the user is looking" to anything
    /// else that asked (the AskUserQuestion push once did).
    private func shouldAutoOpenQuestionSurface(for event: HookEvent) -> Bool {
        let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
        let nativeAskIsRacing = event.rawJSON["_codeisland_native_ask_racing"] as? Bool == true
        // Marker-enabled OMP explicitly guarantees that its native ask dialog
        // races CodeIsland. Pi and legacy OMP block here, so hiding their card deadlocks.
        if event.toolName == "AskUserQuestion",
           (source != "pi" || !nativeAskIsRacing) {
            return true
        }
        return shouldAutoOpenPendingSurface(
            for: event.sessionId ?? "default",
            isTerminalFrontmost: questionTerminalFrontmostDetector
        )
    }

    /// Fast app-level suppress check (main-thread safe, no blocking): Smart
    /// Suppress is on and the session's own terminal is in front.
    private func shouldSuppressAppLevel(for sessionId: String) -> Bool {
        !shouldAutoOpenPendingSurface(for: sessionId)
    }

    private func showCompletion(_ sessionId: String) {
        // Fast path: terminal not even frontmost — show immediately
        guard shouldSuppressAppLevel(for: sessionId) else {
            doShowCompletion(sessionId)
            return
        }

        // Terminal IS frontmost — check tab-level on background thread
        guard let session = sessions[sessionId] else { return }
        let sessionCopy = session
        Task.detached {
            let tabVisible = TerminalVisibilityDetector.isSessionTabVisible(sessionCopy)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Verify state hasn't changed while we were checking
                // (e.g. approval/question card popped up, session was removed)
                guard self.sessions[sessionId] != nil else { return }
                switch self.surface {
                case .approvalCard, .questionCard: return  // don't overwrite higher-priority surfaces
                default: break
                }
                if !tabVisible {
                    withAnimation(NotchAnimation.pop) {
                        self.doShowCompletion(sessionId)
                    }
                }
            }
        }
    }

    private func doShowCompletion(_ sessionId: String) {
        activeSessionId = sessionId
        surface = .completionCard(sessionId: sessionId)
        completionHasBeenEntered = false
        deferCollapseOnMouseLeave = false

        autoCollapseTask?.cancel()
        let delay = completionAutoCollapseDelay
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            showNextCompletionOrCollapse()
        }
    }

    func cancelCompletionQueue() {
        autoCollapseTask?.cancel()
        completionQueue.removeAll()
        queuedCompletionLookingAtTab = nil
        deferCollapseOnMouseLeave = false
    }

    private func showNextCompletionOrCollapse() {
        // Once the mouse has entered the completion card, defer collapse until it leaves
        if completionHasBeenEntered {
            deferCollapseOnMouseLeave = true
            return
        }
        // Interactive items first, then the next finished turn, then collapse.
        if showNextPending() || showNextQueuedCompletion() { return }
        withAnimation(NotchAnimation.close) {
            surface = .collapsed
        }
    }

    // Cached derived state (refreshed by refreshDerivedState after session mutations)
    private(set) var status: AgentStatus = .idle
    private(set) var primarySource: String = "claude"
    private(set) var activeSessionCount: Int = 0
    private(set) var totalSessionCount: Int = 0

    var currentTool: String? {
        // When approvals/questions are pending, always reflect the *front of the queue*.
        // Otherwise a second incoming request can overwrite session.currentTool and make
        // the first pending item appear to “disappear” in compact UI.
        if let pending = pendingPermission {
            return pending.event.toolName
        }
        if pendingQuestion != nil {
            // AskUserQuestion arrives via PermissionRequest tool.
            return "AskUserQuestion"
        }
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.currentTool
    }

    var toolDescription: String? {
        if let pending = pendingPermission {
            let sessionId = pending.event.sessionId ?? activeSessionId ?? "default"
            return pending.event.toolDescription ?? sessions[sessionId]?.toolDescription
        }
        if let q = pendingQuestion {
            return q.question.question
        }
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.toolDescription
    }

    var activeDisplayName: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        let displaySessionId = s.displaySessionId(sessionId: id)
        return s.displayTitle(sessionId: displaySessionId)
    }

    var activeModel: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.model
    }

    /// Recompute cached status/source/counts from sessions in a single O(n) pass.
    /// Call after any mutation to `sessions` or session status.
    func refreshDerivedState() {
        let summary = deriveSessionSummary(from: sessions)
        // Whenever no session is actively working, honor the user-configured
        // default mascot. Covers both "no sessions at all" (#102) and "all
        // sessions idle" (#149) — without this, a user who sets the default
        // to Codex still sees Claude every time their last session goes idle
        // because deriveSessionSummary echoes the most recently active source.
        // Active work always wins (running / processing / waiting* status).
        let effectiveSource: String
        if summary.status == .idle {
            effectiveSource = SettingsManager.shared.defaultSource
        } else {
            effectiveSource = summary.primarySource
        }
        // Only assign when changed (avoids unnecessary @Observable notifications)
        if status != summary.status { status = summary.status }
        if primarySource != effectiveSource { primarySource = effectiveSource }
        if activeSessionCount != summary.activeSessionCount { activeSessionCount = summary.activeSessionCount }
        if totalSessionCount != summary.totalSessionCount { totalSessionCount = summary.totalSessionCount }
        ESP32StatePublisher.shared.notifyDirty()
        AppleCompanionPublisher.shared.notifyDirty()
    }

    func refreshProviderTitle(for trackedSessionId: String, providerSessionId: String? = nil) {
        guard let session = sessions[trackedSessionId] else { return }
        guard !session.isRemote else { return }

        let lookupSessionId = providerSessionId ?? session.providerSessionId ?? trackedSessionId
        if let providerSessionId {
            sessions[trackedSessionId]?.providerSessionId = providerSessionId
        } else if SessionTitleStore.supports(provider: session.source) {
            sessions[trackedSessionId]?.providerSessionId = lookupSessionId
        }

        guard SessionTitleStore.supports(provider: session.source) else { return }

        readProviderTitle(
            ProviderTitleLookup(sessionId: lookupSessionId, provider: session.source, cwd: session.cwd),
            for: trackedSessionId
        )
    }

    /// A card's title read in flight, and the newest lookup asked for while
    /// it ran.
    private struct ProviderTitleRead {
        var next: ProviderTitleLookup?
    }

    @ObservationIgnored
    private var providerTitleReads: [String: ProviderTitleRead] = [:]

    /// Look a card's title up in its provider's store, off the main actor:
    /// every Claude and Codex hook asks, and the lookup reads a file (Codex's
    /// whole thread index, the head and tail of a Claude transcript). One read
    /// per card at a time; a lookup asked for meanwhile runs once it lands,
    /// and only the newest lookup's title is applied.
    private func readProviderTitle(_ lookup: ProviderTitleLookup, for cardId: String) {
        if providerTitleReads[cardId] != nil {
            providerTitleReads[cardId] = ProviderTitleRead(next: lookup)
            return
        }
        providerTitleReads[cardId] = ProviderTitleRead()
        let read = storeReaders.title
        Task.detached(priority: .userInitiated) {
            let resolved = read(lookup)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let next = self.providerTitleReads.removeValue(forKey: cardId)?.next {
                    self.readProviderTitle(next, for: cardId)
                    return
                }
                guard let session = self.sessions[cardId],
                      session.sessionTitle != resolved?.title
                        || session.sessionTitleSource != resolved?.source else { return }
                self.sessions[cardId]?.sessionTitle = resolved?.title
                self.sessions[cardId]?.sessionTitleSource = resolved?.source
            }
        }
    }

    func handleEvent(_ event: HookEvent) {
        // Cursor ran both of CodeIsland's hooks for this step: the second copy
        // is the same prompt or finished turn, not another one to chime for.
        if let digest = event.rawJSON[CursorHookPayload.digestKey] as? String,
           cursorHookDeliveries.isRepeat(digest: digest, now: Date()) {
            return
        }

        // Skip events from subagent worktrees — tracked via parent's SubagentStart/Stop
        if let cwd = event.rawJSON["cwd"] as? String,
           cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
            return
        }

        let source = event.rawJSON["_source"] as? String
        let hasTranscriptPath = (event.rawJSON["transcript_path"] as? String)
            .map { !$0.isEmpty } ?? false
        if CodexDiscovery.isCodexPlaceholderHook(
            source: source,
            cwd: event.rawJSON["cwd"] as? String,
            hasTranscriptPath: hasTranscriptPath
        ) {
            return
        }

        let sessionId = event.sessionId ?? "default"
        let normalizedEventName = EventNormalizer.normalize(event.eventName)

        // Account chatter, not session activity. CodeBuddy fires
        // Notification(auth_success) as the CLI boots — before SessionStart and
        // under a different session id — which minted a second card that then
        // never updated (#288).
        if normalizedEventName == "Notification",
           Self.isAccountNotification(event) {
            return
        }

        if shouldDropEventForSupersededGrokSession(
            sessionId: sessionId,
            normalizedEventName: normalizedEventName
        ) {
            return
        }

        if source?.lowercased() == "codex",
           event.rawJSON["_term_bundle"] as? String == Self.codexAppBundleId,
           let rawProviderSessionId = event.rawJSON["session_id"] as? String {
            let providerSessionId = rawProviderSessionId.hasPrefix(Self.codexAppSessionPrefix)
                ? String(rawProviderSessionId.dropFirst(Self.codexAppSessionPrefix.count))
                : rawProviderSessionId
            if closedCodexAppThreads[providerSessionId] != nil {
                // Tool/notification/terminal hooks can trail app-server
                // `thread/closed`. Only explicit generation-start activity may
                // reopen; `thread/started` clears the same tombstone directly.
                if normalizedEventName == "SessionStart"
                    || normalizedEventName == "UserPromptSubmit" {
                    closedCodexAppThreads.removeValue(forKey: providerSessionId)
                } else {
                    return
                }
            }
        }

        // Skip Codex APP internal sessions (title generation, etc.) — they have no transcript
        if (event.rawJSON["_source"] as? String) == "codex"
            && sessions[sessionId] == nil
            && event.rawJSON["transcript_path"] is NSNull {
            return
        }

        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }

        let prevStatus = sessions[sessionId]?.status
        let wasWaiting = prevStatus == .waitingApproval || prevStatus == .waitingQuestion
        let displayOnlyWaitBefore = displayOnlyWaitKind(forSession: sessionId)
        let cwdBeforeReduce = sessions[sessionId]?.cwd

        // Cache PreToolUse payloads so downstream events sharing tool_use_id can be
        // correlated, and drain queue entries whose agent already moved on.
        cachePreToolUseIfApplicable(event)
        resolveToolUseIfCompleted(event)
        // #216: permission requests with no correlatable tool_use_id can't be drained by
        // resolveToolUseIfCompleted. A follow-up activity event means the user already
        // approved in the terminal — resume those (and only those) as approved.
        resolveOrphanPermissionsOnActivity(event)

        let reduction = reduceHookEvent(sessions: &sessions, event: event, maxHistory: maxHistory,
                                        replyCompletePlaceholder: L10n.shared["reply_complete_placeholder"])
        // Whose turn this was is read off the session as the event left it,
        // before the Cursor fold below can rebrand, fold or drop the card.
        let attentionSubject = AttentionSubject(sessions[sessionId])

        // Cursor Agent Tasks often fire Claude-format hooks without `--source`,
        // leaving ghost Claude cards. Rebrand + fold before the rest of the
        // pipeline treats them as standalone Claude sessions. A Task card the
        // bridge already labelled Cursor still needs its transcript found.
        if sessions.values.contains(where: Self.needsCursorTaskTranscriptLookup) {
            _ = applyCursorSubsessionModeToKnownSessions()
        }

        // After reduce: remoteHostId is authoritative (extractMetadata just ran),
        // so a remote session can never probe the local filesystem here.
        maybeRefreshGitBranch(for: sessionId, cwdBefore: cwdBeforeReduce, normalizedEventName: normalizedEventName)
        maybeResolveHostHarness(for: sessionId)

        // A finished local Claude turn is booked against the plan limits now —
        // the quota monitor coalesces these into at most one fetch a minute.
        if normalizedEventName == "Stop",
           let s = sessions[sessionId], s.isClaude, s.isRemote != true {
            claudeQuota.noteStop()
        }

        // Backfill model after metadata extraction. Hooks are inconsistent across providers,
        // so retry with a cooldown instead of giving up permanently on the first miss.
        if sessions[sessionId]?.isRemote != true {
            maybeBackfillModel(for: sessionId)
            if let agentId = event.agentId {
                maybeBackfillSubagentModel(sessionId: sessionId, agentId: agentId, event: event)
            }
            requestHermesStoreRead(for: sessionId, event: event)
        }

        // Session was waiting and got an activity event. Historically we'd
        // blanket-drain the whole queue here, assuming the user answered in the
        // terminal. That heuristic misfires for parallel MCP / plugin tool calls:
        // an unrelated PostToolUse / Stop / etc. would deny pending permissions
        // for *other* in-flight tools (#147).
        //
        // The right signal that a specific permission is moot is its tool_use_id
        // showing up in PostToolUse / PostToolUseFailure / PermissionDenied —
        // resolveToolUseIfCompleted already does that surgically above. We keep
        // the question-queue drain (questions don't carry tool_use_id reliably
        // and are rare enough that a blanket sweep is acceptable) and refresh
        // session status, but never drain unrelated permission requests.
        //
        // The sweep only covers questions asked by the same agent as the event.
        // Background subagents share the parent's session_id, so their tool
        // calls and SubagentStop kept arriving while the main thread's question
        // was on screen and denied it ("Permission denied by hook").
        if wasWaiting {
            let keepWaiting: Set<String> = ["Notification", "SessionStart", "SessionEnd", "PreCompact"]
            if !keepWaiting.contains(normalizedEventName) {
                drainQuestions(
                    forSession: sessionId,
                    reason: "wasWaiting-blanket-drain-event=\(normalizedEventName)",
                    where: { $0.agentId == event.agentId }
                )
                let stillHasPermission = permissionQueue.contains { $0.event.sessionId == sessionId }
                let stillHasQuestion = questionQueue.contains { $0.event.sessionId == sessionId }
                if !stillHasPermission && !stillHasQuestion,
                   sessions[sessionId]?.status == .waitingApproval
                    || sessions[sessionId]?.status == .waitingQuestion {
                    sessions[sessionId]?.status = (normalizedEventName == "Stop") ? .idle : .processing
                    sessions[sessionId]?.currentTool = nil
                    sessions[sessionId]?.toolDescription = nil
                }
                showNextPending()
            }
        }

        // Detect Cursor YOLO mode once per session (nil = unchecked)
        if let source = event.rawJSON["_source"] as? String,
           (source == "cursor" || source == "cursor-cli"),
           sessions[sessionId]?.isYoloMode == nil {
            readCursorYoloMode(for: sessionId)
        }

        // Now that the event has settled: does the user hear about it, and
        // how. One decision, carried out in the order the outlets always ran
        // in — the push, the completion, then the sound.
        //
        // A card the Cursor fold above just moved into its parent's (or
        // dropped) was a Task's: its turn is its parent's business, like a
        // child's — no chime, no completion card for a card that is gone, no
        // push as the user's own turn, nothing to follow up.
        var subject = attentionSubject
        if sessions[sessionId] == nil {
            subject.isChild = true
        }
        let attention = decideAttention(.hookEvent(reduction.facts), sessionId: sessionId, subject: subject)
        if let push = attention.push {
            pushTurnEnded(
                push,
                sessionId: sessionId,
                errorType: reduction.facts.turnError?.type,
                errorDetail: reduction.facts.turnError?.detail
            )
        }
        announceCompletion(attention, sessionId: sessionId)
        for effect in reduction.effects {
            executeEffect(effect, sessionId: sessionId)
        }
        playAttentionSound(attention, sessionId: sessionId)

        if normalizedEventName == "SessionStart" {
            retireGrokSessionsSuperseded(bySessionStartOf: sessionId)
        }

        if let provider = sessions[sessionId]?.source,
           sessions[sessionId]?.isRemote != true,
           SessionTitleStore.supports(provider: provider) {
            refreshProviderTitle(for: sessionId)
        }

        // If a hook just supplied (or changed) this session's transcript path, attach
        // the tailer so the next assistant append shows up in the panel immediately.
        if sessions[sessionId]?.isRemote != true {
            attachTranscriptTailerIfNeeded(sessionId: sessionId)
        }

        // Handle the "else if activeSessionId == sessionId → mostActive" edge case
        // (reducer can't check activeSessionId since it's AppState-local)
        if sessions[sessionId]?.status == .idle && activeSessionId == sessionId {
            // A Stop keeps its session up for the completion card it pops. A
            // turn end that pops none — a child's (#378), a gateway chat's
            // (#364), one the completion style keeps to the glance dot or to
            // nothing — hands the spot on like any event; so does a child's
            // Stop that ended no turn.
            let poppedCard: Bool
            if case .card? = attention.completion?.presentation { poppedCard = true } else { poppedCard = false }
            let keepsSpot = normalizedEventName == "Stop"
                && (reduction.facts.endedTurn ? poppedCard : !subject.isChild)
            if !keepsSpot {
                activeSessionId = mostActiveSessionId()
            }
        }

        // A terminal permission prompt announced by a Notification waits
        // display-only until the next activity event clears it.
        noteDisplayOnlyWait(
            sessionId: sessionId,
            was: displayOnlyWaitBefore,
            asking: Self.displayOnlyWaitAsk(forHookEvent: event, normalizedEventName: normalizedEventName)
        )

        scheduleSave()
        startRotationIfNeeded()
        refreshDerivedState()
    }

    /// Grok's TUI switches the session it hosts in place (`/resume`, `/new`, a
    /// welcome-screen pick) without any hook for the session it leaves, so
    /// that card stayed alive for as long as the process did (#318). One pager
    /// process can also run several top-level sessions at once (Agent
    /// Dashboard dispatch, `/fork`), so only an idle card — no turn, no
    /// working subagent — counts as superseded. Every other provider keeps its
    /// many-sessions-per-PID model (Codex app-server, IDEs, opencode server).
    nonisolated static func isGrokSessionSupersededBySessionStart(
        candidate: SessionSnapshot,
        candidateId: String,
        started: SessionSnapshot,
        startedId: String
    ) -> Bool {
        guard candidateId != startedId,
              started.source == "grok",
              candidate.source == "grok",
              !started.isRemote,
              !candidate.isRemote,
              let pid = started.cliPid,
              pid > 0,
              candidate.cliPid == pid,
              candidate.status == .idle else {
            return false
        }
        return !candidate.subagents.values.contains { $0.status != .idle }
    }

    private func retireGrokSessionsSuperseded(bySessionStartOf sessionId: String) {
        guard let started = sessions[sessionId],
              started.source == "grok",
              let pid = started.cliPid else { return }
        supersededGrokSessions = supersededGrokSessions.filter { ProcessTable.isLiveProcess($0.value) }

        let superseded = sessions.compactMap { key, candidate -> String? in
            guard Self.isGrokSessionSupersededBySessionStart(
                candidate: candidate,
                candidateId: key,
                started: started,
                startedId: sessionId
            ),
            !permissionQueue.contains(where: { ($0.event.sessionId ?? "default") == key }),
            !questionQueue.contains(where: { ($0.event.sessionId ?? "default") == key }) else {
                return nil
            }
            return key
        }
        guard !superseded.isEmpty else { return }

        let process = ProcessTable.liveProcessIdentity(for: pid) ?? ProcessIdentity(pid: pid, startTime: nil)
        for key in superseded {
            log.info("retiring superseded grok session=\(key, privacy: .public) pid=\(pid, privacy: .public) new=\(sessionId, privacy: .public)")
            supersededGrokSessions[key] = process
            removeSession(key)
        }
    }

    /// A retired Grok session can still emit passive hooks (the `idle_prompt`
    /// Notification about a minute after it settles, the session-end Stop and
    /// SessionEnd when Grok quits). Only generation-start activity revives it.
    private func shouldDropEventForSupersededGrokSession(
        sessionId: String,
        normalizedEventName: String
    ) -> Bool {
        guard let process = supersededGrokSessions[sessionId] else { return false }
        if normalizedEventName == "SessionStart"
            || normalizedEventName == "UserPromptSubmit"
            || !ProcessTable.isLiveProcess(process) {
            supersededGrokSessions.removeValue(forKey: sessionId)
            return false
        }
        return true
    }

    func isSupersededGrokDiscovery(_ info: DiscoveredSession) -> Bool {
        guard let process = supersededGrokSessions[info.sessionId] else { return false }
        if ProcessTable.isLiveProcess(process) { return true }
        supersededGrokSessions.removeValue(forKey: info.sessionId)
        return false
    }

    func removeRemoteSessions(hostId: String) {
        let ids = sessions.compactMap { key, session in
            session.remoteHostId == hostId ? key : nil
        }
        for id in ids {
            removeSession(id)
        }
        refreshDerivedState()
    }

    private func executeEffect(_ effect: SideEffect, sessionId: String) {
        switch effect {
        case .tryMonitorSession(let sid):
            tryMonitorSession(sid)
        case .stopMonitor(let sid):
            stopMonitor(sid)
        case .removeSession(let sid):
            removeSession(sid)
        case .setActiveSession(let sid):
            activeSessionId = sid
        case .playSound, .enqueueCompletion:
            // Attention is AttentionPolicy's to decide; `reduceHookEvent`
            // never emits these (only the `reduceEvent` composition does).
            assertionFailure("\(effect) reached executeEffect: attention goes through AttentionPolicy")
        }
    }

    /// The read walks the card's transcript or session store (a Codex
    /// rollout search, OpenCode's database), so it runs off the main actor,
    /// one at a time per card. A model a hook supplies meanwhile wins.
    private func maybeBackfillModel(for sessionId: String) {
        guard let session = sessions[sessionId], session.model == nil else { return }
        let now = Date()
        if let retryAt = modelReadRetryAt[sessionId], retryAt > now {
            return
        }
        guard modelReadsInFlight.insert(sessionId).inserted else { return }

        let read = storeReaders.model
        Task.detached(priority: .utility) {
            let model = read(sessionId, session)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.modelReadsInFlight.remove(sessionId)
                guard self.sessions[sessionId] != nil else { return }
                if let model {
                    if self.sessions[sessionId]?.model == nil {
                        self.sessions[sessionId]?.model = model
                    }
                    self.modelReadRetryAt.removeValue(forKey: sessionId)
                } else {
                    self.modelReadRetryAt[sessionId] = now.addingTimeInterval(5)
                }
            }
        }
    }

    /// Read Cursor's settings for the card's YOLO badge, off the main actor;
    /// once per card (nil = unchecked).
    private func readCursorYoloMode(for sessionId: String) {
        guard cursorYoloReadsInFlight.insert(sessionId).inserted else { return }
        let read = storeReaders.cursorYoloMode
        Task.detached(priority: .utility) {
            let yolo = read()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cursorYoloReadsInFlight.remove(sessionId)
                guard self.sessions[sessionId] != nil, self.sessions[sessionId]?.isYoloMode == nil else { return }
                self.sessions[sessionId]?.isYoloMode = yolo
            }
        }
    }

    func handlePermissionRequest(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        // Extract metadata so blocking-first parent sessions have cwd/source/PID.
        // Subagent events are routed through the parent session ID; their full metadata
        // can describe the child session and should not overwrite the parent — only fill gaps.
        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }
        tryMonitorSession(sessionId)

        // Closed Task/subagent ids must not surface new permission UI (parity with
        // ensureSubagent refusing late tool hooks after Stop).
        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            let denyResponse = Data(
                #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8
            )
            continuation.resume(returning: denyResponse)
            return
        }

        // Clear any pending questions from THIS agent (mutually exclusive within an agent;
        // a background subagent's request must not deny the main thread's question)
        drainQuestions(forSession: sessionId, reason: "newPermissionRequest", where: { $0.agentId == event.agentId })

        sessions[sessionId]?.status = .waitingApproval
        sessions[sessionId]?.currentTool = event.activityLabel
        sessions[sessionId]?.toolDescription = event.toolDescription
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, event: event, status: .waitingApproval)
        // Backfill tool name/description from cached PreToolUse when the payload is thin.
        enrichPermissionRequestFromCache(sessionId: sessionId, event: event)

        let request = PermissionRequest(event: event, continuation: continuation)

        // Replay deduplication: if the same tool_use_id is already queued, swap the
        // continuation in place and deny the previous waiter. Preserves card order.
        if mergeDuplicatePermissionRequest(request) {
            refreshDerivedState()
            return
        }

        // A genuinely new request means this session needs a user decision again,
        // so it stops being dismissed. This must come AFTER the replay-dedup
        // return above: a replay is the same decision arriving twice, not a new
        // one, and un-dismissing on a replay resurrects the request the user
        // hid — which then takes the card the arriving session should have got
        // and, counting as a burst already in progress, silences its sound too.
        // (A same-id request with different tool inputs is a distinct request,
        // not a replay — merge returns false for those, so they still land here.)
        dismissedPermissionSessionIds.remove(sessionId)

        // Dismissing hides a request but deliberately leaves it queued, so the
        // CLI stays blocked and the prompt stays recoverable. Gating on
        // `permissionQueue.count == 1` therefore swallowed every later request —
        // from any session — for as long as a dismissed one sat in the queue.
        //
        // The gate's real question is "is an approval card on screen", so ask
        // the surface. Queue-derived proxies do not survive the un-dismiss
        // above: a session's own next request clears its dismissal, which makes
        // its still-queued earlier request count as visible again while nothing
        // is displayed — silencing every later request all over again. (#309)
        //
        // ponytail: a card suppressed by Smart Suppress also leaves a visible
        // request undisplayed, so a second session's request still waits behind
        // it. That is pre-existing (`main` behaves the same) and needs
        // showNextPending to skip un-openable entries; tracked separately.
        //
        // The surface alone is not enough either: `drainPermissions` empties one
        // SESSION's requests without clearing `surface`, so a card can be left
        // pointing at a session that has nothing queued. Ask per session, not
        // per queue — a whole-queue test (`!permissionQueue.isEmpty`) reads as
        // "a card is up" whenever some other session is still waiting, which
        // leaves the panel showing a card for a session with no pending request
        // while later requests queue silently behind it.
        let approvalCardOnScreen: Bool
        if case .approvalCard(let shownSessionId) = surface,
           permissionQueue.contains(where: { ($0.event.sessionId ?? "default") == shownSessionId }) {
            approvalCardOnScreen = true
        } else {
            approvalCardOnScreen = false
        }

        // Card and sound answer different questions and must not share a gate.
        // The sound marks the start of a burst of approvals, which is what
        // `count == 1` used to approximate; within a burst it stays quiet, and
        // a dismissed request sitting in the queue must not count as a burst
        // already in progress.
        let burstAlreadyInProgress = nextVisiblePermissionIndex() != nil
        permissionQueue.append(request)
        let attention = decideAttention(.approvalQueued(firstOfBurst: !burstAlreadyInProgress), sessionId: sessionId)
        pushPermissionQueued(event, sessionId: sessionId, push: attention.push)

        // Show UI only when no approval card is already up to be stolen from.
        // showNextPending picks the first *visible* request, promotes it to the
        // head and applies the session-list / Smart Suppress rules — pointing
        // the card at this session by hand would show the dismissed request's
        // content whenever a dismissed entry still leads the queue.
        if !approvalCardOnScreen {
            showNextPending()
        }
        playAttentionSound(attention, sessionId: sessionId)
        refreshDerivedState()
    }

    /// Index of the queued request the user actually acted on.
    ///
    /// The card on screen is identified by its session, but the answer used to
    /// be applied to `queue.removeFirst()`. Anything that mutates the head
    /// while a card is open — a peer disconnect draining another session, a
    /// stale tool-use eviction, the reorder in `showNextPending()` — would then
    /// resolve whichever request happened to be first, delivering the answer to
    /// the wrong CLI. Callers that know which session the card belongs to pass
    /// it in; `nil` keeps the head-of-queue behaviour for surfaces that only
    /// ever mirror the head (the hardware Buddy, a companion command that names
    /// no session). (#308)
    private func permissionIndex(expecting expected: String?) -> Int? {
        guard let expected else { return permissionQueue.isEmpty ? nil : 0 }
        return permissionQueue.firstIndex { ($0.event.sessionId ?? "default") == expected }
    }

    /// Question-queue counterpart of `permissionIndex(expecting:)`. (#308)
    private func questionIndex(expecting expected: String?) -> Int? {
        guard let expected else { return questionQueue.isEmpty ? nil : 0 }
        return questionQueue.firstIndex { ($0.event.sessionId ?? "default") == expected }
    }

    /// The request the card was showing is no longer queued (answered in the
    /// terminal, drained on disconnect). `showNextPending()` drops the dead card
    /// and re-opens whatever is genuinely waiting. (#308)
    private func discardStalePanelAction(expected: String, kind: String) {
        log.notice("⚠️ ignored \(kind, privacy: .public) for session=\(expected, privacy: .public) — request no longer queued")
        showNextPending()
        refreshDerivedState()
    }

    func approvePermission(always: Bool = false, expectedSessionId: String? = nil) {
        guard let index = permissionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "approve")
            }
            return
        }
        let pending = permissionQueue.remove(at: index)
        let sessionId = pending.event.sessionId ?? "default"
        dismissedPermissionSessionIds.remove(sessionId)
        let responseData: Data
        if always, CodexPermissionRules.isCodexEvent(pending.event) {
            _ = CodexPermissionRules().persistAlwaysAllowRule(for: pending.event)
            let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            responseData = Data(response.utf8)
        } else if always, Self.isZcodeEvent(pending.event) {
            responseData = Self.zcodeAlwaysAllowResponse(toolName: pending.event.toolName)
        } else if always {
            let toolName = pending.event.toolName ?? ""
            // MCP tools (`mcp__server__tool`) don't accept a rule specifier — the
            // rule must be the bare tool name. Sending `ruleContent: "*"` makes
            // Claude Code assemble `mcp__server__tool(*)`, which never matches an
            // actual MCP call, so the "always allow" rule silently fails to
            // persist and the same approval keeps re-prompting. Non-MCP tools
            // (Bash/Read/Edit/…) keep the `*` specifier. (#224)
            var rule: [String: Any] = ["toolName": toolName]
            if !toolName.hasPrefix("mcp__") {
                rule["ruleContent"] = "*"
            }
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedPermissions": [[
                            "type": "addRules",
                            "rules": [rule],
                            "behavior": "allow",
                            "destination": "session"
                        ]]
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            responseData = Data(response.utf8)
        }
        pending.continuation.resume(returning: responseData)
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .running,
            keepSubagentTool: pending.event.toolName,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    nonisolated static func isZcodeEvent(_ event: HookEvent) -> Bool {
        SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) == "zcode"
    }

    nonisolated static func isQoderEvent(_ event: HookEvent) -> Bool {
        guard let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) else { return false }
        return source == "qoder" || source == "qoder-cli"
    }

    /// "Always allow" response for a ZCode PermissionRequest hook (#258).
    ///
    /// ZCode validates hook stdout with a STRICT schema (unknown keys void the
    /// whole decision, and ZCode falls back to its own dialog). Persistent
    /// rules therefore go in `permissionUpdates` — NOT Claude's
    /// `updatedPermissions` — and there is no `destination` key. A rule with a
    /// bare `toolName` (no `ruleContent`) matches every future call of that
    /// tool, which is exactly the "always allow this tool" semantic; a
    /// `ruleContent` of "*" would instead be compared against the call's
    /// command/path subject and never match. Events without a tool name can't
    /// form a valid rule (toolName must be non-empty), so they degrade to a
    /// plain one-time allow.
    nonisolated static func zcodeAlwaysAllowResponse(toolName: String?) -> Data {
        let plainAllow = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        guard let toolName, !toolName.isEmpty else { return plainAllow }
        let obj: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                    "permissionUpdates": [[
                        "type": "addRules",
                        "behavior": "allow",
                        "rules": [["toolName": toolName]],
                    ] as [String: Any]]
                ] as [String: Any]
            ] as [String: Any]
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? plainAllow
    }

    /// `expectedSessionId` is the session the remote surface was showing when
    /// the button was pressed. The hardware Buddy has no session identity to
    /// send and passes nil, keeping its head-of-queue behaviour; the iPhone
    /// does send one, so a tap resolves against the card the user actually saw
    /// — the #308 failure mode, which the panel fixed in #310 but this path
    /// never did. A round trip over Bluetooth makes the race wider here than
    /// it ever was on the panel.
    func handleBuddyControlCommand(_ command: BuddyControlCommand, expectedSessionId: String? = nil) {
        switch command {
        case .approveCurrentPermission:
            if !permissionQueue.isEmpty {
                approvePermission(expectedSessionId: expectedSessionId)
            } else {
                log.info("Ignored Buddy approve command because permission queue is empty")
            }
        case .denyCurrentPermission:
            if !permissionQueue.isEmpty {
                denyPermission(expectedSessionId: expectedSessionId)
            } else {
                log.info("Ignored Buddy deny command because permission queue is empty")
            }
        case .skipCurrentQuestion:
            if !questionQueue.isEmpty {
                skipQuestion(expectedSessionId: expectedSessionId)
            } else {
                log.info("Ignored Buddy skip command because question queue is empty")
            }
        }
    }

    /// See `handleBuddyControlCommand` for why `expectedSessionId` matters.
    func answerCompanionQuestion(_ answer: String, expectedSessionId: String? = nil) {
        guard !questionQueue.isEmpty else {
            log.info("Ignored companion question answer because question queue is empty")
            return
        }
        // Route by the card the phone was showing, which need not be the head:
        // never answer a question the user never read. Gone entirely (answered
        // in the terminal) → answerQuestion discards it and resyncs.
        guard let index = questionIndex(expecting: expectedSessionId) else {
            answerQuestion(answer, expectedSessionId: expectedSessionId)
            return
        }

        // AskUserQuestion is answered one question at a time from the phone.
        // This must run at the addressed index too: answerQuestion() ignores
        // wizard requests, so handing a non-head one to it dropped the answer.
        if questionQueue[index].isFromPermission,
           var askState = questionQueue[index].askUserQuestionState {
            guard let itemIndex = askState.items.firstIndex(where: { askState.answers[$0.answerKey] == nil }) else {
                answerQuestionMulti(askState.items.map {
                    (question: $0.payload.question, answer: askState.answers[$0.answerKey] ?? "")
                }, expectedSessionId: expectedSessionId)
                return
            }

            let item = askState.items[itemIndex]
            askState.answers[item.answerKey] = answer
            questionQueue[index].askUserQuestionState = askState

            if askState.canConfirm {
                answerQuestionMulti(askState.items.map {
                    (question: $0.payload.question, answer: askState.answers[$0.answerKey] ?? "")
                }, expectedSessionId: expectedSessionId)
            } else {
                refreshDerivedState()
            }
            return
        }

        answerQuestion(answer, expectedSessionId: expectedSessionId)
    }

    func findSessionId(providerSessionId: String) -> String? {
        SubsessionCards.cardId(forProviderSessionId: providerSessionId, in: sessions)
    }

    /// Resolve a Codex parent in the same Desktop/CLI namespace as its child.
    /// Raw and `codexapp:` cards may legitimately share a provider thread id
    /// when a user resumes the same thread in both surfaces.
    func findCodexParentSessionId(
        providerSessionId: String,
        childTermBundleId: String?
    ) -> String? {
        SubsessionCards.codexParentCard(
            threadId: providerSessionId,
            childTermBundleId: childTermBundleId,
            in: sessions
        )
    }

    /// What Agent Sub-Sessions needs from the island to route one hook.
    var subsessionContext: AppSubsessionContext {
        AppSubsessionContext(cards: sessions, codexRollouts: codexRollouts)
    }

    func denyPermission(expectedSessionId: String? = nil) {
        guard let index = permissionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "deny")
            }
            return
        }
        let pending = permissionQueue.remove(at: index)
        let sessionId = pending.event.sessionId ?? "default"
        dismissedPermissionSessionIds.remove(sessionId)
        let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        pending.continuation.resume(returning: Data(response.utf8))
        // Folded Task deny must not idle the whole parent chat card.
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .processing,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: true
        )

        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }

        showNextPending()
        refreshDerivedState()
    }

    func dismissPermissionPrompt(expectedSessionId: String? = nil) {
        guard let index = permissionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "dismiss")
            }
            return
        }
        let pending = permissionQueue[index]

        let sessionId = pending.event.sessionId ?? "default"
        dismissedPermissionSessionIds.insert(sessionId)

        if nextVisiblePermissionIndex() != nil {
            showNextPending()
        } else {
            if case .approvalCard = surface {
                withAnimation(NotchAnimation.close) {
                    surface = .collapsed
                }
            }
        }
        refreshDerivedState()
    }

    func handleQuestion(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }
        tryMonitorSession(sessionId)

        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            continuation.resume(returning: Data("{}".utf8))
            return
        }

        guard let question = QuestionPayload.from(event: event) else {
            continuation.resume(returning: Data("{}".utf8))
            return
        }
        drainPermissions(forSession: sessionId, reason: "handleQuestion(Notification)", where: { $0.agentId == event.agentId })

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, event: event, status: .waitingQuestion)

        let request = QuestionRequest(event: event, question: question, continuation: continuation)
        questionQueue.append(request)
        // First of a burst: nothing else visibly waiting. Not `count == 1` —
        // a closed question stays queued, and must not swallow every later
        // question's card and sound (the trap #309 fixed for approvals).
        let firstOfBurst = nextVisibleQuestion?.id == request.id
        let attention = decideAttention(.questionQueued(firstOfBurst: firstOfBurst), sessionId: sessionId)
        pushQuestionQueued(request, sessionId: sessionId, push: attention.push)

        if firstOfBurst {
            activeSessionId = sessionId
            if Self.autoExpandOnQuestion(), shouldAutoOpenPendingSurface(for: sessionId) {
                withAnimation(NotchAnimation.open) {
                    surface = .questionCard(sessionId: sessionId)
                }
            }
        }
        playAttentionSound(attention, sessionId: sessionId)
        refreshDerivedState()
    }

    func handleAskUserQuestion(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }
        tryMonitorSession(sessionId)

        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            let denyResponse = Data(
                #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8
            )
            continuation.resume(returning: denyResponse)
            return
        }

        let originalQuestions = event.toolInput?["questions"] as? [[String: Any]]
        var askItems: [AskUserQuestionItem] = []
        if let questions = originalQuestions {
            var usedAnswerKeys = Set<String>()
            askItems = questions.enumerated().compactMap { index, item in
                let questionText = item["question"] as? String ?? "Question"
                let header = item["header"] as? String
                let multiSelect = item["multiSelect"] as? Bool ?? false
                var optionLabels: [String]?
                var optionDescs: [String]?
                if let opts = item["options"] as? [[String: Any]] {
                    optionLabels = opts.compactMap { $0["label"] as? String }
                    optionDescs = opts.compactMap { $0["description"] as? String }
                }
                if optionLabels?.isEmpty == true { optionLabels = nil }
                if optionDescs?.isEmpty == true { optionDescs = nil }
                let payload = QuestionPayload(
                    question: questionText,
                    options: optionLabels,
                    descriptions: optionDescs,
                    header: header
                )
                // Claude Code's mapToolResultToToolResultBlockParam looks up answers by
                // question text: `answers[question.question]`. Using header as the key
                // causes a mismatch and all answers arrive as empty strings.
                let baseKey = questionText
                var answerKey = baseKey
                if usedAnswerKeys.contains(answerKey) {
                    var suffix = 2
                    while usedAnswerKeys.contains("\(baseKey)_\(suffix)") {
                        suffix += 1
                    }
                    answerKey = "\(baseKey)_\(suffix)"
                }
                usedAnswerKeys.insert(answerKey)
                return AskUserQuestionItem(payload: payload, answerKey: answerKey, multiSelect: multiSelect)
            }
        }

        if askItems.isEmpty {
            let questionText = event.toolInput?["question"] as? String ?? "Question"
            var options: [String]?
            if let stringOpts = event.toolInput?["options"] as? [String] {
                options = stringOpts
            } else if let dictOpts = event.toolInput?["options"] as? [[String: Any]] {
                options = dictOpts.compactMap { $0["label"] as? String }
            }
            if !questionText.isEmpty {
                let payload = QuestionPayload(question: questionText, options: options)
                askItems = [AskUserQuestionItem(payload: payload, answerKey: "answer", multiSelect: false)]
            }
        }

        guard !askItems.isEmpty else {
            let updatedInput = askUserQuestionUpdatedInput(
                event: event,
                answers: [:],
                answer: nil,
                originalQuestions: originalQuestions
            )
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput
                    ] as [String: Any]
                ] as [String: Any]
            ]
            let responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            continuation.resume(returning: responseData)
            sessions[sessionId]?.status = .processing
            refreshDerivedState()
            return
        }

        drainPermissions(forSession: sessionId, reason: "handleAskUserQuestion", where: { $0.agentId == event.agentId })
        drainQuestions(forSession: sessionId, reason: "handleAskUserQuestion", where: { $0.agentId == event.agentId })

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, event: event, status: .waitingQuestion)

        let askState = AskUserQuestionState(items: askItems, answers: [:])
        let request = QuestionRequest(
            event: event,
            question: askItems[0].payload,
            continuation: continuation,
            isFromPermission: true,
            askUserQuestionState: askState
        )
        questionQueue.append(request)
        // First of a burst, as in `handleQuestion`.
        let firstOfBurst = nextVisibleQuestion?.id == request.id
        // Smart Suppress alone: whether the island opens the card by itself
        // (the "auto-expand on question" switch) says nothing about whether
        // the person is looking at the question in their terminal.
        let attention = decideAttention(
            .questionQueued(firstOfBurst: firstOfBurst),
            sessionId: sessionId,
            terminalFrontmost: questionTerminalFrontmostDetector
        )
        pushQuestionQueued(request, sessionId: sessionId, push: attention.push)

        if firstOfBurst {
            activeSessionId = sessionId
            if Self.autoExpandOnQuestion(), shouldAutoOpenQuestionSurface(for: event) {
                withAnimation(NotchAnimation.open) {
                    surface = .questionCard(sessionId: sessionId)
                }
            }
        }
        playAttentionSound(attention, sessionId: sessionId)
        refreshDerivedState()
    }

    func answerQuestion(_ answer: String, expectedSessionId: String? = nil) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "answer")
            }
            return
        }
        // Multi-question wizards (AskUserQuestion, Codex app-server) use the batch
        // path — direct single answers are not processed.
        if questionQueue[index].askUserQuestionState != nil,
           (questionQueue[index].isFromPermission || questionQueue[index].isCodexAppServer) {
            return
        }
        // Codex app-server questions reply over the JSON-RPC client, not a hook.
        if questionQueue[index].isCodexAppServer {
            let pending = questionQueue.remove(at: index)
            let answerKey = pending.askUserQuestionState?.items.first?.answerKey
                ?? pending.question.header ?? "answer"
            pending.resolveCodexAppServer([answerKey: [answer]])
            let sessionId = pending.event.sessionId ?? "default"
            sessions[sessionId]?.status = .processing
            showNextPending()
            refreshDerivedState()
            return
        }
        let pending = questionQueue.remove(at: index)
        let responseData: Data
        if pending.isFromPermission {
            let answerKey = pending.question.header ?? "answer"
            let updatedInput = askUserQuestionUpdatedInput(
                event: pending.event,
                answers: [answerKey: answer],
                answer: answer,
                originalQuestions: pending.event.toolInput?["questions"] as? [[String: Any]]
            )
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "Notification",
                    "answer": answer
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
        pending.resolution.resumeHook(returning: responseData)
        let sessionId = pending.event.sessionId ?? "default"
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .running,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    func answerQuestionMulti(
        _ answers: [(question: String, answer: String)],
        expectedSessionId: String? = nil
    ) {
        answerQuestionMulti(
            answers.map {
                AskUserQuestionAnswer(
                    question: $0.question,
                    answer: $0.answer,
                    selectedOptions: [],
                    customInput: nil
                )
            },
            expectedSessionId: expectedSessionId
        )
    }

    func answerQuestionMulti(
        _ answers: [AskUserQuestionAnswer],
        expectedSessionId: String? = nil
    ) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "answer")
            }
            return
        }
        // Wizard answers are mapped onto items by position below. A set that
        // is not exactly one answer per this request's questions was collected
        // for some other request — delivering it would answer this CLI's
        // question with another session's answer — so it is refused and the
        // request stays waiting. (#333)
        if let askState = questionQueue[index].askUserQuestionState,
           !askState.accepts(answers) {
            let sessionId = questionQueue[index].event.sessionId ?? "default"
            log.notice("⚠️ refused answers for session=\(sessionId, privacy: .public) — \(answers.count, privacy: .public) answer(s) do not match its \(askState.items.count, privacy: .public) question(s)")
            refreshDerivedState()
            return
        }
        // Codex app-server questions reply over the JSON-RPC client, not a hook.
        if questionQueue[index].isCodexAppServer {
            let pending = questionQueue.remove(at: index)
            var answersByKey: [String: [String]] = [:]
            if let askState = pending.askUserQuestionState {
                // Match by position — the wizard collects answers in item order.
                for (index, item) in askState.items.enumerated() where index < answers.count {
                    answersByKey[item.answerKey] = [answers[index].answer]
                }
            } else {
                let answerKey = pending.question.header ?? "answer"
                answersByKey[answerKey] = [answers.first?.answer ?? ""]
            }
            pending.resolveCodexAppServer(answersByKey)
            let sessionId = pending.event.sessionId ?? "default"
            sessions[sessionId]?.status = .processing
            showNextPending()
            refreshDerivedState()
            return
        }
        let pending = questionQueue.remove(at: index)
        let responseData: Data
        if pending.isFromPermission {
            var answersDict: [String: String] = [:]
            var answerDetails: [String: [String: Any]] = [:]
            if let askState = pending.askUserQuestionState {
                // Match by position — wizard collects answers in the same order as items
                for (index, item) in askState.items.enumerated() {
                    if index < answers.count {
                        let submitted = answers[index]
                        answersDict[item.answerKey] = submitted.answer
                        var details: [String: Any] = [:]
                        if !submitted.selectedOptions.isEmpty {
                            details["selectedOptions"] = submitted.selectedOptions
                        }
                        if let customInput = submitted.customInput {
                            details["customInput"] = customInput
                        }
                        if !details.isEmpty {
                            answerDetails[item.answerKey] = details
                        }
                    }
                }
            } else {
                let answerKey = pending.question.header ?? "answer"
                answersDict[answerKey] = answers.first?.answer ?? ""
            }
            let updatedInput = askUserQuestionUpdatedInput(
                event: pending.event,
                answers: answersDict,
                answer: answers.first?.answer,
                originalQuestions: pending.event.toolInput?["questions"] as? [[String: Any]],
                answerDetails: answerDetails
            )
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "Notification",
                    "answer": answers.first?.answer ?? ""
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
        pending.resolution.resumeHook(returning: responseData)
        let sessionId = pending.event.sessionId ?? "default"
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .running,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    private func askUserQuestionUpdatedInput(
        event: HookEvent,
        answers: [String: String],
        answer: String?,
        originalQuestions: [[String: Any]]?,
        answerDetails: [String: [String: Any]] = [:]
    ) -> [String: Any] {
        var updatedInput = event.toolInput ?? [:]
        // `questions` must always be present in updatedInput. Claude Code's
        // mapToolResultToToolResultBlockParam calls H.map() on it directly;
        // if the key is absent H is undefined and the call crashes with
        // "undefined is not an object (evaluating 'H.map')".
        // Fall back to the raw toolInput value when the [[String:Any]] cast fails.
        updatedInput["questions"] = originalQuestions ?? (event.toolInput?["questions"] ?? [] as [[String: Any]])
        updatedInput["answers"] = answers
        // Qoder CLI validates updatedInput against the AskUserQuestion schema
        // (additionalProperties: false, only questions/answers/annotations/
        // metadata). The scalar `answer` key fails that validation with
        // "params must NOT have additional properties", so omit it there.
        if let answer, !Self.isQoderEvent(event) {
            updatedInput["answer"] = answer
        }
        // Structured picks for plugins that answer with label arrays: OMP/Pi,
        // and OpenCode, whose multi-select answers are `string[]` (v1) or a
        // multiselect form field (v2) — a ", "-joined display string can't be
        // split back when a label itself contains ", " (#332). MiMo Code runs
        // the same plugin against OpenCode 1.x's question API.
        let detailsSource = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
        if !answerDetails.isEmpty,
           (detailsSource == "pi" && event.toolUseId != nil)
            || detailsSource == "opencode" || detailsSource == "mimo" {
            updatedInput["_codeislandAnswerDetails"] = answerDetails
        }
        return updatedInput
    }

    /// Close a question card without answering it. The request stays queued
    /// and the agent keeps waiting: answer it in the terminal, or reopen the
    /// card from the collapsed bar's question badge. Skip, by contrast,
    /// answers — for AskUserQuestion it denies the tool call.
    func dismissQuestion(expectedSessionId: String? = nil) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "dismiss")
            }
            return
        }
        dismissedQuestionIds.insert(questionQueue[index].id)

        if case .questionCard = surface {
            withAnimation(NotchAnimation.close) {
                surface = .collapsed
            }
        }
        // Hand the panel to whatever is still visibly waiting, if it may open.
        showNextPending()
        refreshDerivedState()
    }

    func skipQuestion(expectedSessionId: String? = nil) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "skip")
            }
            return
        }
        let pending = questionQueue.remove(at: index)
        if pending.isCodexAppServer {
            // No "skip" verb in the Codex protocol — abandon the request so the
            // server stops waiting (it will re-prompt or fall back to its TUI).
            pending.resolveCodexAppServer(nil)
        } else {
            let responseData: Data
            if pending.isFromPermission {
                responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
            } else {
                responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"Notification"}}"#.utf8)
            }
            pending.resolution.resumeHook(returning: responseData)
        }
        let sessionId = pending.event.sessionId ?? "default"
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .processing,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    /// Drain queued permissions for a specific session, resuming their continuations with deny.
    /// `matches` narrows the drain by the request's event — background subagents share the
    /// parent's session_id, so callers reacting to one agent pass an agent_id filter.
    func drainPermissions(
        forSession sessionId: String,
        reason: String = "unknown",
        where matches: (HookEvent) -> Bool = { _ in true }
    ) {
        dismissedPermissionSessionIds.remove(sessionId)
        let denyResponse = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        permissionQueue.removeAll { item in
            guard item.event.sessionId == sessionId, matches(item.event) else { return false }
            log.notice("⚠️ permission deny reason=drainPermissions(\(reason, privacy: .public)) session=\(sessionId, privacy: .public) toolUseId=\(item.toolUseId ?? "nil", privacy: .public) tool=\(item.event.toolName ?? "nil", privacy: .public)")
            item.continuation.resume(returning: denyResponse)
            return true
        }
    }

    /// Called when the bridge socket disconnects — the question/permission was answered externally (e.g. user replied in terminal).
    /// Only the disconnecting agent's requests are drained: the socket belonged to one agent,
    /// and another agent's request in the same session is still waiting on the user.
    func handlePeerDisconnect(sessionId: String, agentId: String? = nil) {
        let sameAgent: (HookEvent) -> Bool = { $0.sessionId == sessionId && $0.agentId == agentId }
        let hadPending = questionQueue.contains(where: { sameAgent($0.event) })
            || permissionQueue.contains(where: { sameAgent($0.event) })
        guard hadPending else { return }

        drainQuestions(forSession: sessionId, reason: "peer-disconnect", where: sameAgent)
        drainPermissions(forSession: sessionId, reason: "peer-disconnect", where: sameAgent)
        let currentStatus = sessions[sessionId]?.status
        let wasWaiting = currentStatus == .waitingApproval || currentStatus == .waitingQuestion
        if wasWaiting, permissionQueue.contains(where: { $0.event.sessionId == sessionId }) {
            sessions[sessionId]?.status = .waitingApproval
        } else if wasWaiting, questionQueue.contains(where: { $0.event.sessionId == sessionId }) {
            sessions[sessionId]?.status = .waitingQuestion
        } else if wasWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
        showNextPending()
        refreshDerivedState()
    }

    /// Drain all queued questions for a specific session.
    /// AskUserQuestion-derived requests are denied; notification questions return empty.
    func drainQuestions(
        forSession sessionId: String,
        reason: String = "unknown",
        where matches: (HookEvent) -> Bool = { _ in true }
    ) {
        questionQueue.removeAll { item in
            guard item.event.sessionId == sessionId, matches(item.event) else { return false }
            if item.isCodexAppServer {
                // Abandon the Codex app-server request so the server stops waiting.
                item.resolveCodexAppServer(nil)
            } else if item.isFromPermission {
                log.notice("⚠️ permission deny reason=drainQuestions(\(reason, privacy: .public)) session=\(sessionId, privacy: .public) tool=AskUserQuestion")
                let denyData = Data(
                    #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
                item.resolution.resumeHook(returning: denyData)
            } else {
                item.resolution.resumeHook(returning: Data("{}".utf8))
            }
            return true
        }
    }

    /// A card the user can no longer act on must never stay on screen: the panel
    /// would sit expanded showing a request that is gone or dismissed, and any
    /// click landing on it can only be discarded. Auto-open suppression decides
    /// whether to open a *new* card, not whether to keep a dead one, so this
    /// runs unconditionally. (#308)
    ///
    /// "Dead" is the same predicate `nextVisiblePermissionIndex()` applies:
    /// dismissed counts as not visible. Testing queue membership alone would
    /// keep a dismissed card up, because dismissing hides without dequeuing.
    private func collapseStaleCardSurface() {
        switch surface {
        case .approvalCard(let sid)
            where pendingPermission(forSession: sid) == nil
                || dismissedPermissionSessionIds.contains(sid):
            surface = .collapsed
        case .questionCard(let sid) where pendingQuestion(forSession: sid) == nil:
            surface = .collapsed
        default:
            break
        }
    }

    /// After dequeuing, show the next pending item, else the next finished
    /// turn, else collapse.
    ///
    /// Returns whether something the user can act on is on screen afterwards:
    /// an approval / question card, or the session list (which answers them
    /// inline), or the next completion card. A request that stays hidden —
    /// its auto-expand switch is off, Smart Suppress holds it back — is not
    /// on screen: a completion card whose time is up then moves on to the
    /// next finished turn or folds, instead of staying up for nobody.
    @discardableResult
    func showNextPending() -> Bool {
        collapseStaleCardSurface()
        let hasPending: Bool
        if let idx = nextVisiblePermissionIndex() {
            hasPending = true
            // An approval card still showing the request it was opened for
            // stays — the user may have picked it (session list, reminder)
            // over the head. It becomes the head, so whatever mirrors the
            // head (Buddy) agrees with the screen.
            let shownIdx = shownApprovalIndex
            // One assignment: removing and re-inserting in place would show
            // the queue's observers (follow-up reminders) a moment where this
            // request is gone, and its reminder would start over.
            var queue = permissionQueue
            let next = queue.remove(at: shownIdx ?? idx)
            queue.insert(next, at: 0)
            permissionQueue = queue
            let sid = next.event.sessionId ?? "default"
            activeSessionId = sid
            if shownIdx != nil { return true }
            // When the session list is open, keep it open; approvals can be handled inline.
            if surface == .sessionList { return true }
            if Self.autoExpandOnPermission(), shouldAutoOpenPendingSurface(for: sid) {
                surface = .approvalCard(sessionId: sid)
                return true
            }
            // The approval stays hidden; a card already up stays with it.
            if surface.approvalSessionId != nil || surface.questionSessionId != nil { return true }
        } else if let next = nextVisibleQuestion {
            hasPending = true
            // A question card still showing the question it was opened for
            // stays, even when it is not the head (the user clicked "Answer"
            // on it, a reminder reopened it).
            if let shown = shownQuestionSessionId {
                activeSessionId = shown
                return true
            }
            let sid = next.event.sessionId ?? "default"
            activeSessionId = sid
            if !Self.autoExpandOnQuestion() {
                // Nothing opens by itself — and a card the user opened with a
                // click stays put. Stale cards were already folded above.
                if surface.questionSessionId != nil || surface == .sessionList { return true }
            } else if shouldAutoOpenQuestionSurface(for: next.event) {
                surface = .questionCard(sessionId: sid)
                return true
            } else if case .questionCard = surface {
                // Smart Suppress wants this card collapsed (e.g. an OMP ask
                // whose terminal dialog is racing). Fold an inherited
                // question-card surface so the promoted card does not render
                // expanded on top of the previous question's surface.
                surface = .collapsed
            } else if surface == .sessionList {
                return true
            }
        } else {
            hasPending = false
        }
        // Nothing interactive on screen. A completion card that is up keeps
        // its own time (`showNextCompletionOrCollapse` moves on when it is
        // over); a request arriving hidden must not cut it short.
        if !hasPending || !isShowingCompletion, showNextQueuedCompletion() {
            return true
        }
        if surface.approvalSessionId != nil || surface.questionSessionId != nil {
            surface = .collapsed
        }
        return false
    }

    /// Show the oldest queued completion whose session still exists, held to
    /// Smart Suppress as a card shown at once is: with its terminal in front,
    /// its tab is looked at off the main thread first, and a card whose own
    /// tab is showing stays down while the queue moves on.
    ///
    /// Returns whether a card is on screen or on its way there, so callers
    /// neither fold the island nor take another card out of the queue.
    private func showNextQueuedCompletion() -> Bool {
        if queuedCompletionLookingAtTab != nil { return true }
        while let next = completionQueue.first {
            completionQueue.removeFirst()
            guard let session = sessions[next] else { continue }
            guard shouldSuppressAppLevel(for: next) else {
                withAnimation(NotchAnimation.pop) { doShowCompletion(next) }
                return true
            }
            queuedCompletionLookingAtTab = next
            let sessionCopy = session
            Task.detached {
                let tabVisible = TerminalVisibilityDetector.isSessionTabVisible(sessionCopy)
                await MainActor.run { [weak self] in
                    self?.finishLookingAtQueuedCompletionTab(next, tabVisible: tabVisible)
                }
            }
            return true
        }
        return false
    }

    /// The tab of the queued completion on its way came back: pop its card,
    /// or move on with the queue.
    private func finishLookingAtQueuedCompletionTab(_ sessionId: String, tabVisible: Bool) {
        // The queue was cancelled meanwhile.
        guard queuedCompletionLookingAtTab == sessionId else { return }
        queuedCompletionLookingAtTab = nil
        switch surface {
        case .approvalCard, .questionCard:
            // An approval or question took the island meanwhile: the card
            // waits behind it again, first in line.
            if sessions[sessionId] != nil { completionQueue.insert(sessionId, at: 0) }
        case .sessionList:
            // The user opened the session list, which shows this finished
            // turn as well: no card over it.
            break
        case .collapsed, .completionCard:
            if sessions[sessionId] != nil, !tabVisible {
                withAnimation(NotchAnimation.pop) { doShowCompletion(sessionId) }
            } else if case .completionCard = surface {
                // Its own tab is in front (or it is gone): the card whose time
                // ran out moves on to the next one, or folds.
                showNextCompletionOrCollapse()
            } else {
                _ = showNextQueuedCompletion()
            }
        }
    }

    /// Find the most recently active non-idle session
    private func mostActiveSessionId() -> String? {
        // Pick the most urgent session: highest status priority, then most recent activity
        sessions.max { a, b in
            let pa = CompactBarRotation.statusPriority(a.value.status)
            let pb = CompactBarRotation.statusPriority(b.value.status)
            if pa != pb { return pa < pb }
            return a.value.lastActivity < b.value.lastActivity
        }?.key
    }

    // MARK: - Teardown

    func stopSessionDiscovery() {
        discovery.stop()
        rotation.stopTimer()
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        saveTimer?.invalidate()
        saveTimer = nil
        cursorSubagentIndexTask?.cancel()
        cursorSubagentIndexTask = nil
        cancelCursorSubagentIndexRecheck()
        processMonitor.stopAll()
    }

    deinit {
        // Must not use MainActor.assumeIsolated: async callers (notably XCTest)
        // can release AppState off the main actor via ARC. Main-synced Timer
        // teardown keeps it crash-free. The discovery coordinator (FSEvents,
        // scans) and the process monitor (exit sources) tear down their own
        // when they are released.
        tearDownMainThreadResources()
        cursorSubagentIndexTask?.cancel()
        cursorSubagentIndexRecheck?.cancel()
        codexAppServerReconnectTask?.cancel()
    }

    /// Invalidates main-run-loop Timers in one main-queue hop. Safe from any
    /// thread so `deinit` stays uniformly main-safe.
    nonisolated private func tearDownMainThreadResources() {
        let teardown = { [self] in
            rotation.tearDownAssumingMain()
            cleanupTimer?.invalidate()
            cleanupTimer = nil
            saveTimer?.invalidate()
            saveTimer = nil
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.sync(execute: teardown)
        }
    }
}
