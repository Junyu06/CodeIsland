import Foundation
import Network
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "HookServer")

@MainActor
class HookServer {
    enum RouteKind: Equatable {
        case permission
        case question
        case event
    }

    private let appState: AppState
    nonisolated static var socketPath: String { SocketPath.path }
    private var listener: NWListener?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        // Clean up stale socket
        unlink(HookServer.socketPath)

        // Set umask to 0o077 BEFORE the listener creates the socket file,
        // ensuring it is never world-readable even briefly (closes TOCTOU window).
        let previousUmask = umask(0o077)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: HookServer.socketPath)

        do {
            listener = try NWListener(using: params)
        } catch {
            umask(previousUmask)
            log.error("Failed to create NWListener: \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { [previousUmask] state in
            switch state {
            case .ready:
                // Restore previous umask now that the socket file exists with safe permissions
                umask(previousUmask)
                // Belt-and-suspenders: explicitly set 0o700 in case umask didn't take effect
                chmod(HookServer.socketPath, 0o700)
                log.info("HookServer listening on \(HookServer.socketPath)")
            case .failed(let error):
                umask(previousUmask)
                log.error("HookServer failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        // Delay socket removal so in-flight hooks can finish sending their payload
        // before the file disappears — prevents intermittent errors on session end (#45).
        let path = HookServer.socketPath
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            unlink(path)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveAll(connection: connection, accumulated: Data())
    }

    private static let maxPayloadSize = 10_485_760  // 10MB safety limit

    /// Recursively receive all data until EOF, then process
    private func receiveAll(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }

                // On error with no data, just drop the connection
                if error != nil && accumulated.isEmpty && content == nil {
                    connection.cancel()
                    return
                }

                var data = accumulated
                if let content { data.append(content) }

                // Safety: reject oversized payloads
                if data.count > Self.maxPayloadSize {
                    log.warning("Payload too large (\(data.count) bytes), dropping connection")
                    let denyResponse = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
                    self.sendResponse(connection: connection, data: denyResponse)
                    return
                }

                if isComplete || error != nil {
                    self.processRequest(data: data, connection: connection)
                } else {
                    self.receiveAll(connection: connection, accumulated: data)
                }
            }
        }
    }

    /// Internal tools that are safe to auto-approve without user confirmation.
    /// Read from user settings; defaults to all known internal tools.
    private static var autoApproveTools: Set<String> {
        SettingsManager.shared.autoApproveTools
    }

    /// Whether this event's agent is on the user's always-proceed list (#283).
    /// Matched on both the raw `_source` and its normalized form so "agy",
    /// "google-antigravity" and "antigravity-cli" all resolve to one entry.
    static func isAutoApprovedSource(_ event: HookEvent) -> Bool {
        isAutoApprovedSource(event, approved: SettingsManager.shared.autoApproveSources)
    }

    nonisolated static func isAutoApprovedSource(
        _ event: HookEvent,
        approved: Set<String>
    ) -> Bool {
        guard !approved.isEmpty,
              let raw = event.rawJSON["_source"] as? String else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if approved.contains(trimmed) { return true }
        guard let normalized = SessionSnapshot.normalizedSupportedSource(trimmed) else { return false }
        return approved.contains(normalized)
    }

    /// User-configured cwd substring blocklist for plugin/background hooks (e.g. claude-mem).
    /// Empty default = no filtering. Trimmed, blank entries skipped.
    private static func eventMatchesExcludedCwd(_ cwd: String) -> Bool {
        cwdMatchesAnyPattern(cwd, patternsCSV: SettingsManager.shared.excludedHookCwdSubstrings)
    }

    /// Pure substring blocklist match — returns true if `cwd` contains any
    /// non-empty trimmed entry of `patternsCSV`. Extracted for testability;
    /// `nonisolated` because it touches no actor state.
    nonisolated static func cwdMatchesAnyPattern(_ cwd: String, patternsCSV: String) -> Bool {
        guard !patternsCSV.isEmpty else { return false }
        for entry in patternsCSV.split(separator: ",", omittingEmptySubsequences: false) {
            let pattern = entry.trimmingCharacters(in: .whitespaces)
            if !pattern.isEmpty, cwd.contains(pattern) { return true }
        }
        return false
    }

    /// Per-host cwd ALLOW-list for remote sessions (#240) — on shared remote
    /// accounts, users can scope the panel to their own project directories.
    /// Empty filter = allow everything (previous behavior). With a filter set,
    /// events must carry a cwd containing one of the entries; events without a
    /// cwd are dropped too — on a shared account they can't be attributed.
    nonisolated static func remoteEventPassesCwdFilter(
        cwd: String?,
        workspaceRoots: [String]? = nil,
        filterCSV: String
    ) -> Bool {
        let hasPattern = filterCSV
            .split(separator: ",", omittingEmptySubsequences: false)
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard hasPattern else { return true }
        if let cwd, !cwd.isEmpty, cwdMatchesAnyPattern(cwd, patternsCSV: filterCSV) {
            return true
        }
        if let roots = workspaceRoots {
            for root in roots where !root.isEmpty {
                if cwdMatchesAnyPattern(root, patternsCSV: filterCSV) {
                    return true
                }
            }
        }
        // No cwd or workspace root matched — on a shared account they can't be attributed.
        return false
    }

    /// Remote cwd allow-lists drop hooks from other users' directories on shared
    /// SSH accounts (#240). Lifecycle and blocking hooks for sessions we already
    /// track must still flow through — otherwise SessionEnd/Stop never tears
    /// sessions down and PermissionRequest/Notification stall the remote agent.
    nonisolated static func remoteEventBypassesCwdFilter(
        eventName: String,
        sessionId: String?,
        trackedSessionIds: Set<String>
    ) -> Bool {
        guard let sessionId, trackedSessionIds.contains(sessionId) else { return false }
        switch EventNormalizer.normalize(eventName) {
        case "SessionEnd", "Stop", "SubagentStop", "PermissionRequest", "Notification", "AfterAgentResponse":
            return true
        default:
            return false
        }
    }

    /// Looks up the configured cwd filter for a remote host id. Nil when the
    /// event is not remote or the host is no longer configured.
    private static func remoteCwdFilter(for event: HookEvent) -> String? {
        guard let hostId = event.rawJSON["_remote_host_id"] as? String,
              !hostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return RemoteManager.shared.hosts.first(where: { $0.id == hostId })?.cwdFilter
    }

    /// Fire-and-forget POST of the hook event to a user-configured webhook URL.
    /// Wraps the raw event in a small envelope (event/source/session/cwd/tool/raw)
    /// so users on the receiving side don't need to dig through bridge-internal
    /// fields. Optional event-name allow-list filters noisy event types. (#115)
    private static func forwardEventToWebhook(_ event: HookEvent) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.webhookEnabled) else { return }
        // Trim whitespace — users routinely paste URLs with leading/trailing space
        // and URL(string:) silently rejects those (RFC 3986 forbids whitespace).
        let urlString = (defaults.string(forKey: SettingsKey.webhookURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty,
              let endpoint = URL(string: urlString) else { return }

        let normalizedName = EventNormalizer.normalize(event.eventName)

        // Event filter: comma-separated allow-list. Empty = forward all.
        // Match on either the normalized name (PreToolUse) or raw name (pre_tool_use).
        if let filter = defaults.string(forKey: SettingsKey.webhookEventFilter),
           !filter.trimmingCharacters(in: .whitespaces).isEmpty {
            let allowed = filter.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard allowed.contains(normalizedName) || allowed.contains(event.eventName) else { return }
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let envelope: [String: Any] = [
            "event": normalizedName,
            "raw_event": event.eventName,
            "session_id": event.sessionId ?? "",
            "source": event.rawJSON["_source"] as? String ?? "",
            "cwd": event.rawJSON["cwd"] as? String ?? "",
            "tool_name": event.toolName ?? "",
            "timestamp": isoFormatter.string(from: Date()),
            "raw": event.rawJSON,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return }

        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("CodeIsland-Webhook/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { _, _, _ in
            // Fire-and-forget. Failures are intentionally swallowed: a flaky
            // webhook should never break the hook event pipeline.
        }.resume()
    }

    static func routeKind(for event: HookEvent) -> RouteKind {
        let normalizedEventName = EventNormalizer.normalize(event.eventName)
        // Google Antigravity's PreToolUse stays a plain activity event. Its hook
        // cannot approve a call (an `allow` is ignored and Antigravity prompts
        // anyway), so an island card in front of it only doubled every approval
        // and left a card behind when the user answered in Antigravity. The
        // bridge has already told Antigravity to decide for itself (#339).
        if normalizedEventName == "PermissionRequest" {
            return .permission
        }
        if normalizedEventName == "Notification", QuestionPayload.from(event: event) != nil {
            return .question
        }
        return .event
    }

    nonisolated static func shouldDeferPermissionRequestToProvider(_ event: HookEvent) -> Bool {
        guard EventNormalizer.normalize(event.eventName) == "PermissionRequest",
              event.toolName != "AskUserQuestion" else {
            return false
        }
        return CodexPermissionRules.shouldDeferToCodexAutoReview(for: event)
    }

    private static let pluginMarkerBytes = Data("_via_plugin".utf8)
    private static let declaredParentMarkerBytes = Data(DeclaredSubsession.parentKey.utf8)
    private static let sourceMarkerBytes = Data(#""_source""#.utf8)
    private static let codexMarkerBytes = Data("codex".utf8)
    private static let cursorTranscriptMarkerBytes = Data("agent-transcripts".utf8)
    private static let cursorSourceExactBytes = Data(#""_source":"cursor""#.utf8)
    private static let cursorCliSourceExactBytes = Data(#""_source":"cursor-cli""#.utf8)
    private static let ppidKeyBytes = Data(#""_ppid""#.utf8)
    /// JSON `\uXXXX` escape — only then do we fall back to a full parse.
    private static let jsonUnicodeEscapeBytes = Data(#"\u"#.utf8)
    private static let cursorSourceFlexibleRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #""_source"\s*:\s*"(cursor-cli|cursor)""#,
            options: []
        )
    }()

    /// Whether Cursor Task routing may need a JSON parse (transcript fold path).
    ///
    /// Requires `agent-transcripts` plus either a Cursor `_source` or a path under
    /// `/.cursor/` (misbranded Claude-default Task hooks still fold).
    internal static func mayNeedCursorSubsessionRouting(data: Data) -> Bool {
        guard data.range(of: cursorTranscriptMarkerBytes) != nil else { return false }
        if mayBeCursorHookSource(data: data) { return true }
        return data.range(of: Data("/.cursor/".utf8)) != nil
    }

    /// `_source` is `cursor` / `cursor-cli` (compact, spaced, or `\u`-escaped).
    /// Used for merge/hide `_ppid` fallback when `agent-transcripts` is absent.
    internal static func mayBeCursorHookSource(data: Data) -> Bool {
        // Compact forms first — bridge JSONSerialization emits no spaces after `:`.
        if data.range(of: cursorCliSourceExactBytes) != nil
            || data.range(of: cursorSourceExactBytes) != nil {
            return true
        }
        guard data.range(of: sourceMarkerBytes) != nil else { return false }
        if let text = String(data: data, encoding: .utf8) {
            let range = NSRange(text.startIndex..., in: text)
            if cursorSourceFlexibleRegex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        guard data.range(of: jsonUnicodeEscapeBytes) != nil,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = obj["_source"] as? String else {
            return false
        }
        return CursorSubsessionRouter.isCursorFamilySource(source)
    }

    /// Whether a hook may be a child session's, worth a JSON parse for Agent
    /// Sub-Sessions. Cheap byte probes first; avoid JSONSerialization on every
    /// PostToolUse.
    internal static func mayNeedSubsessionRouting(data: Data, mode: SubsessionMode) -> Bool {
        // A child that names its parent (#378), a plugin proxy (#123) or a
        // Codex thread: in every mode. Show separately keeps such a child on a
        // quiet card of its own, and a child folded before Agent Sub-Sessions
        // changed must still end where it started.
        if data.range(of: declaredParentMarkerBytes) != nil
            || data.range(of: pluginMarkerBytes) != nil
            || (data.range(of: sourceMarkerBytes) != nil && data.range(of: codexMarkerBytes) != nil) {
            return true
        }
        // A Cursor Task whose transcript path names its chat, in every mode.
        if mayNeedCursorSubsessionRouting(data: data) { return true }
        // One without: Merge and Hide fall back to its IDE process (`_ppid`).
        // Show separately does not act on that guess, so it needs no parse.
        return mode != .separate
            && mayBeCursorHookSource(data: data)
            && data.range(of: ppidKeyBytes) != nil
    }

    /// A hook after Agent Sub-Sessions: `json` is its parsed payload when
    /// routing had to parse it (HookEvent is built from that, not reparsed).
    private struct RoutedHook {
        var data: Data
        var json: [String: Any]?
        var rewritten = false
        var response: Data?
    }

    /// Test seam for Agent Sub-Sessions pre-routing.
    internal func routeSubsessionPayloadIfNeededForTesting(
        data: Data
    ) -> (processedData: Data, responseData: Data?) {
        let routed = routeSubsessionPayloadIfNeeded(data: data)
        guard routed.rewritten,
              let json = routed.json,
              let rewritten = try? JSONSerialization.data(withJSONObject: json) else {
            return (routed.data, routed.response)
        }
        return (rewritten, routed.response)
    }

    /// Agent Sub-Sessions (#123, #151, #262, #378): find whose child the hook
    /// is (``SubsessionRouter/link(in:context:now:)``) and place it — on the
    /// child's own card, linked to its parent; folded into the parent's card;
    /// or hidden.
    private func routeSubsessionPayloadIfNeeded(data: Data) -> RoutedHook {
        let mode = AppState.currentPluginSessionMode()
        guard Self.mayNeedSubsessionRouting(data: data, mode: mode),
              var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RoutedHook(data: data)
        }
        let context = appState.subsessionContext
        guard let link = SubsessionRouter.link(in: raw, context: context) else {
            return RoutedHook(data: data, json: raw)
        }
        let original = raw
        let outcome = SubsessionRouter.route(
            &raw,
            link: link,
            mode: mode,
            cards: context.cards,
            isBlockingRequest: {
                HookEvent(json: original).map { Self.routeKind(for: $0) != .event } ?? false
            }
        )
        switch outcome {
        case .unchanged:
            return RoutedHook(data: data, json: raw)
        case .rewritten:
            return RoutedHook(data: data, json: raw, rewritten: true)
        case .hidden:
            return RoutedHook(data: data, json: raw, response: Data("{}".utf8))
        }
    }

    private func processRequest(data: Data, connection: NWConnection) {
        // Sub-session pre-filter: a child session's hook (a Codex thread, a
        // Cursor Task, a declared child, a plugin proxy) follows Agent
        // Sub-Sessions — its own linked card, its parent's card, or hidden.
        let routed = routeSubsessionPayloadIfNeeded(data: data)
        if let responseData = routed.response {
            sendResponse(connection: connection, data: responseData)
            return
        }

        guard let event = routed.json.flatMap(HookEvent.init(json:)) ?? HookEvent(from: routed.data) else {
            sendResponse(connection: connection, data: Data("{\"error\":\"parse_failed\"}".utf8))
            return
        }

        // Diagnostics ring buffer (#103): record the post-merge view of the
        // event so the export reflects what was actually dispatched. Also
        // capture the field names the hook arrived with and a prompt preview
        // so future "prompt not showing" reports can be diagnosed without
        // round-tripping for more data.
        let payloadKeys = event.rawJSON.keys
            .filter { !$0.hasPrefix("_") }  // drop bridge-injected metadata fields
            .sorted()
        let promptPreview: String? = {
            let candidates = ["prompt", "user_prompt", "userPrompt", "message", "input", "content", "text"]
            for key in candidates {
                if let s = event.rawJSON[key] as? String {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return String(trimmed.prefix(80))
                    }
                }
            }
            return nil
        }()
        appState.recordHookEvent(
            source: event.rawJSON["_source"] as? String,
            sessionId: event.sessionId,
            eventName: event.eventName,
            toolName: event.toolName,
            viaPlugin: (event.rawJSON["_via_plugin"] as? Bool) == true,
            payloadKeys: payloadKeys,
            promptPreview: promptPreview
        )

        if let rawSource = event.rawJSON["_source"] as? String,
           SessionSnapshot.normalizedSupportedSource(rawSource) == nil {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // User-configured cwd exclusion: drop hooks fired by background plugins
        // (e.g. claude-mem, agent loops) whose cwd matches any user-provided
        // substring. Default empty list = no filtering, matches existing behavior. (#125)
        if let cwd = event.rawJSON["cwd"] as? String,
           !cwd.isEmpty,
           Self.eventMatchesExcludedCwd(cwd) {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // Per-host cwd allow-list for remote sessions (#240): on a shared remote
        // account every user's hooks reach every connected client — scope this
        // panel to the configured working directories and drop the rest.
        if let filterCSV = Self.remoteCwdFilter(for: event),
           !Self.remoteEventPassesCwdFilter(
               cwd: event.rawJSON["cwd"] as? String,
               workspaceRoots: event.rawJSON["workspace_roots"] as? [String],
               filterCSV: filterCSV
           ),
           !Self.remoteEventBypassesCwdFilter(
               eventName: event.eventName,
               sessionId: event.sessionId,
               trackedSessionIds: Set(appState.sessions.keys)
           ) {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        // User-configured webhook forwarding: fire-and-forget POST to an external URL.
        // Runs *before* the route handlers so it doesn't add latency to user-facing
        // permission/question UI. Disabled by default. (#115)
        Self.forwardEventToWebhook(event)

        switch Self.routeKind(for: event) {
        case .permission:
            let sessionId = event.sessionId ?? "default"

            // Auto-approve safe internal tools without showing UI
            if let toolName = event.toolName, Self.autoApproveTools.contains(toolName) {
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            // Agents the user has already put in an always-proceed mode
            // (Antigravity Turbo, Cursor YOLO, …). Re-asking on the island is the
            // exact interruption that mode exists to remove (#283). Questions are
            // not permissions, so AskUserQuestion is deliberately excluded below.
            if event.toolName != "AskUserQuestion",
               Self.isAutoApprovedSource(event) {
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            // AskUserQuestion is a question, not a permission — route to QuestionBar
            if event.toolName == "AskUserQuestion" {
                monitorPeerDisconnect(connection: connection, sessionId: sessionId, agentId: event.agentId)
                Task {
                    let responseBody = await withCheckedContinuation { continuation in
                        appState.handleAskUserQuestion(event, continuation: continuation)
                    }
                    self.sendResponse(connection: connection, data: responseBody)
                }
                return
            }

            if Self.shouldDeferPermissionRequestToProvider(event) {
                sendResponse(connection: connection, data: Data("{}".utf8))
                return
            }

            monitorPeerDisconnect(connection: connection, sessionId: sessionId, agentId: event.agentId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handlePermissionRequest(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }

        case .question:
            let questionSessionId = event.sessionId ?? "default"
            monitorPeerDisconnect(connection: connection, sessionId: questionSessionId, agentId: event.agentId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handleQuestion(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }

        case .event:
            appState.handleEvent(event)
            sendResponse(connection: connection, data: Data("{}".utf8))
        }
    }

    /// Per-connection state used by the disconnect monitor.
    /// `responded` flips to true once we've sent the response, so our own
    /// `connection.cancel()` inside `sendResponse` does not masquerade as a
    /// peer disconnect.
    private final class ConnectionContext {
        var responded: Bool = false
    }

    private var connectionContexts: [ObjectIdentifier: ConnectionContext] = [:]

    /// Watch for bridge process disconnect — indicates the bridge process actually died
    /// (e.g. user Ctrl-C'd Claude Code), NOT a normal half-close.
    ///
    /// Previously this used `connection.receive(min:1, max:1)` which triggered on EOF.
    /// But the bridge always does `shutdown(SHUT_WR)` after sending the request (see
    /// CodeIslandBridge/main.swift), which produces an immediate EOF on the read side.
    /// That caused every PermissionRequest to be auto-drained as `deny` before the UI
    /// card was even visible. We now rely on `stateUpdateHandler` transitioning to
    /// `cancelled`/`failed` — which only happens on real socket teardown, not half-close.
    private func monitorPeerDisconnect(connection: NWConnection, sessionId: String, agentId: String?) {
        let context = ConnectionContext()
        let connId = ObjectIdentifier(connection)
        connectionContexts[connId] = context

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .cancelled, .failed:
                    if !context.responded {
                        self.appState.handlePeerDisconnect(sessionId: sessionId, agentId: agentId)
                    }
                    self.connectionContexts.removeValue(forKey: connId)
                default:
                    break
                }
            }
        }

        // Safety net: if the connection context is still around after 5 minutes
        // (e.g. stuck continuation, NWConnection never transitions), clean it up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)  // 5 minutes
            guard let self = self else { return }
            if self.connectionContexts.removeValue(forKey: connId) != nil {
                log.warning("Connection context for session \(sessionId) timed out — cleaning up")
                if !context.responded {
                    connection.cancel()
                }
            }
        }
    }

    private func sendResponse(connection: NWConnection, data: Data) {
        // Mark as responded BEFORE cancel() so the disconnect monitor ignores our own teardown.
        if let context = connectionContexts[ObjectIdentifier(connection)] {
            context.responded = true
        }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
