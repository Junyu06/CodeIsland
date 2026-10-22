import Foundation
import CodeIslandCore

/// Push notifications, fed from the same places that drive the island:
/// the permission / question queues and the completion effect. Content is
/// built from what those queues hold, never re-guessed from raw hook JSON.
extension AppState {
    /// Who a session's pushes are about — the labels its card shows.
    func pushSubject(for sessionId: String) -> PushSubject {
        let session = sessions[sessionId]
        return PushSubject(
            sessionId: sessionId,
            agent: session?.sourceLabel ?? "Agent",
            project: session?.cwd == nil ? nil : session?.projectDisplayName,
            host: session?.remoteDisplayName
        )
    }

    /// A permission request was just queued. `smartSuppressed` is evaluated
    /// only when a push is actually on the table.
    func pushPermissionQueued(_ event: HookEvent, sessionId: String, smartSuppressed: @autoclosure () -> Bool) {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return }
        notifier.notify(
            Self.pushContent(forPermission: event, cwd: sessions[sessionId]?.cwd),
            subject: pushSubject(for: sessionId),
            smartSuppressed: smartSuppressed(),
            request: pushRequest(forPermission: event, sessionId: sessionId)
        )
    }

    /// A question (hook Notification, AskUserQuestion, Codex app-server) was just queued.
    func pushQuestionQueued(_ request: QuestionRequest, sessionId: String, smartSuppressed: @autoclosure () -> Bool) {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return }
        notifier.notify(
            Self.pushContent(forQuestion: request),
            subject: pushSubject(for: sessionId),
            smartSuppressed: smartSuppressed(),
            request: pushRequest(forQuestion: request, sessionId: sessionId)
        )
    }

    // MARK: Request identity

    /// Which approval / question a push is about: the tool call id when the
    /// agent sends one, else a fingerprint of what is asked — so a replayed
    /// hook is the same request and a new one in the same session is not.
    nonisolated static func pushRequestKey(toolUseId: String?, asking content: PushContent) -> String {
        if let id = toolUseId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return "id:\(id)"
        }
        return "ask:\(content.hashValue)"
    }

    /// Fingerprinted without the session's cwd, which can still arrive after
    /// the request did.
    nonisolated static func pushRequestKey(forPermission event: HookEvent) -> String {
        pushRequestKey(toolUseId: event.toolUseId, asking: pushContent(forPermission: event, cwd: nil))
    }

    static func pushRequestKey(forQuestion request: QuestionRequest) -> String {
        pushRequestKey(toolUseId: request.event.toolUseId, asking: pushContent(forQuestion: request))
    }

    /// A queued approval, found again by identity until it leaves the queue.
    func pushRequest(forPermission event: HookEvent, sessionId: String) -> PushPendingRequest {
        let key = Self.pushRequestKey(forPermission: event)
        return PushPendingRequest(key: key) { [weak self] in
            guard let self,
                  let queued = self.permissionQueue.first(where: {
                      ($0.event.sessionId ?? "default") == sessionId && Self.pushRequestKey(forPermission: $0.event) == key
                  }) else { return nil }
            return Self.pushContent(forPermission: queued.event, cwd: self.sessions[sessionId]?.cwd)
        }
    }

    /// A queued question, found again by identity until it leaves the queue.
    func pushRequest(forQuestion request: QuestionRequest, sessionId: String) -> PushPendingRequest {
        let key = Self.pushRequestKey(forQuestion: request)
        return PushPendingRequest(key: key) { [weak self] in
            guard let self,
                  let queued = self.questionQueue.first(where: {
                      ($0.event.sessionId ?? "default") == sessionId && Self.pushRequestKey(forQuestion: $0) == key
                  }) else { return nil }
            return Self.pushContent(forQuestion: queued)
        }
    }

    /// A display-only wait, identified by what it asks: the same wait asking
    /// something else (Claude Desktop's next card) is a new request.
    func pushRequest(forDisplayOnlyWait sessionId: String, asking content: PushContent) -> PushPendingRequest {
        let key = "wait:\(content.hashValue)"
        return PushPendingRequest(key: key) { [weak self] in
            guard let current = self?.displayOnlyWaitPushContent(forSession: sessionId),
                  "wait:\(current.hashValue)" == key else { return nil }
            return current
        }
    }

    /// Runs right after the reducer, before its side effects: a turn that
    /// ended on an API error pushes the error; any other turn end the
    /// reducer turned into a completion card pushes a completion.
    func pushAfterReduce(_ event: HookEvent, sessionId: String, effects: [SideEffect]) {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return }
        let session = sessions[sessionId]
        // A child reports to the agent that spawned it, and that agent to the
        // user: a child's turn ending or failing is not news on its own (#378).
        // (Its completion never reaches here: the reducer drops it.)
        guard session?.parentSessionId == nil else { return }
        if let failure = PushEventClassifier.sessionError(eventName: event.eventName, raw: event.rawJSON) {
            notifier.notify(
                .error(type: failure.type, detail: failure.detail),
                subject: pushSubject(for: sessionId),
                smartSuppressed: !self.shouldAutoOpenPendingSurface(for: sessionId)
            )
            return
        }
        guard effects.contains(.enqueueCompletion(sessionId: sessionId)) else { return }
        notifier.notify(
            .completion(summary: Self.pushCompletionSummary(session)),
            subject: pushSubject(for: sessionId),
            smartSuppressed: !self.shouldAutoOpenPendingSurface(for: sessionId),
            isSubagent: PushEventClassifier.isSubagentCompletion(
                agentId: event.agentId,
                raw: event.rawJSON,
                sessionId: sessionId,
                session: session
            ),
            interrupted: session?.interrupted == true
        )
    }

    /// AiWork daemon turn boundary (its streams bypass the hook reducer).
    func pushAiWorkTurnEnded(_ eventName: String, sessionId: String, data: [String: AnyCodableLike]? = nil) {
        switch eventName {
        case "stream.completed": pushTurnEnded(sessionId: sessionId, failed: false)
        case "stream.failed":
            pushTurnEnded(sessionId: sessionId, failed: true, errorDetail: Self.aiworkFailureText(data))
        default: return  // stream.aborted: the user stopped it
        }
    }

    /// What a `stream.failed` event itself says went wrong, if anything.
    nonisolated static func aiworkFailureText(_ data: [String: AnyCodableLike]?) -> String? {
        guard let data else { return nil }
        let candidates = [
            data["error"]?.asString,
            data["error"]?.asObject?["message"]?.asString,
            data["error_message"]?.asString,
            data["terminal_notice"]?.asObject?["summary"]?.asString,
            data["reason"]?.asString,
        ]
        return candidates.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// A turn ended in a source that bypasses the hook reducer (AiWork,
    /// Claude Desktop Cowork): its completion, or its error when it failed.
    ///
    /// - `errorDetail`: the failure's own text, from the event that reported
    ///   it. Never the session's last reply — that can be the previous
    ///   turn's; with nothing better the push says only that it failed.
    func pushTurnEnded(sessionId: String, failed: Bool, errorDetail: String? = nil) {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return }
        let session = sessions[sessionId]
        let content: PushContent = failed
            ? .error(type: nil, detail: errorDetail)
            : .completion(summary: Self.pushCompletionSummary(session))
        notifier.notify(
            content,
            subject: pushSubject(for: sessionId),
            smartSuppressed: !self.shouldAutoOpenPendingSurface(for: sessionId)
        )
    }

    /// Subscribes the push channels to follow-up reminders. Called once at launch.
    func connectPushToFollowUps() {
        followUps.addReminderHandler { [weak self] reminder in
            self?.pushFollowUpReminder(reminder)
        }
    }

    /// A follow-up reminder came due. It is rebuilt from the queue, so it
    /// carries the same command / question and options as the first push,
    /// plus how long it has been waiting.
    ///
    /// - `.deferred`: the Mac held its own reminder back (locked, screen
    ///   saver, quiet hours) — the moment a phone matters most.
    /// - `.onTime`: played on the Mac as well — unless `locallySuppressed`:
    ///   the island kept quiet because the user seemed to be in front of it
    ///   (the session's terminal tab in front, the card under the pointer).
    ///   That is Smart Suppress's call, and the gate honours it only while
    ///   someone is at the Mac. Away, the phone gets it; the controller then
    ///   counts it as an attempt (`remoteChannelDelivered`).
    /// - `.catchUp`: the local replay after the hold ended; the person is
    ///   back and the deferred one already went out.
    @discardableResult
    func pushFollowUpReminder(_ reminder: FollowUpReminder) -> PushDecision {
        let notifier = PushNotifier.shared
        guard notifier.isEnabled else { return .disabled }
        if reminder.delivery == .catchUp { return .skipped(.userPresent) }
        let sessionId = reminder.sessionId
        let pending: PushContent
        // Approvals and questions come from the queue, or — for a display-only
        // wait — from what the wait asked, with where to answer it.
        switch reminder.kind {
        case .approval:
            if let request = pendingPermission(forSession: sessionId) {
                pending = Self.pushContent(forPermission: request.event, cwd: sessions[sessionId]?.cwd)
            } else if let waiting = displayOnlyWaitPushContent(forSession: sessionId, kind: .approval) {
                pending = waiting
            } else {
                return .skipped(.nothingPending)
            }
        case .question:
            if let request = pendingQuestion(forSession: sessionId) {
                pending = Self.pushContent(forQuestion: request)
            } else if let waiting = displayOnlyWaitPushContent(forSession: sessionId, kind: .question) {
                pending = waiting
            } else {
                return .skipped(.nothingPending)
            }
        case .completion:
            // One nudge for a finished turn nobody looked at. If the turn's own
            // completion push reached the phone, the nudge would only repeat
            // it; if the turn failed, "finished" would be wrong. (Both are
            // decided just before the reminder's clock starts, hence the slack.)
            if notifier.shouldSkipCompletionReminder(sessionId: sessionId, since: reminder.waitingSince.addingTimeInterval(-5)) {
                return .skipped(.duplicate)
            }
            pending = .completion(summary: Self.pushCompletionSummary(sessions[sessionId]))
        }
        let decision = notifier.notify(
            .reminder(pending: pending, waitingSince: reminder.waitingSince),
            subject: pushSubject(for: sessionId),
            smartSuppressed: reminder.locallySuppressed
        )
        if case .sent = decision {
            followUps.remoteChannelDelivered(reminder)
        }
        return decision
    }

    // MARK: Content

    nonisolated static func pushContent(forPermission event: HookEvent, cwd: String?) -> PushContent {
        .permission(
            tool: event.toolName,
            detail: PushDetailSummarizer.permissionDetail(
                toolInput: event.toolInput,
                fallback: event.toolDescription,
                cwd: cwd
            )
        )
    }

    /// Every question of a wizard (AskUserQuestion, Codex requestUserInput),
    /// not just the one on screen, so the user can think them all over.
    static func pushContent(forQuestion request: QuestionRequest) -> PushContent {
        let payloads = request.askUserQuestionState?.items.map(\.payload) ?? [request.question]
        return .question(
            items: payloads.map {
                PushQuestionItem(question: $0.question, options: $0.options ?? [], header: $0.header)
            },
            isSecret: payloads.contains { $0.isSecret }
        )
    }

    /// The reply the completion card shows: this turn's last assistant
    /// message. `lastAssistantMessage` alone can still hold the previous
    /// turn's text when a Stop arrived without one, and the "Reply complete"
    /// placeholder says nothing a phone needs.
    static func pushCompletionSummary(_ session: SessionSnapshot?) -> String? {
        guard let session else { return nil }
        if let last = session.recentMessages.last {
            guard !last.isUser else { return nil }
            let placeholders = Set(L10n.strings.values.compactMap { $0["reply_complete_placeholder"] })
            return placeholders.contains(last.text) ? nil : last.text
        }
        return session.lastAssistantMessage
    }
}
