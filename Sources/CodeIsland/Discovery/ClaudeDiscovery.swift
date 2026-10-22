import Foundation
import CodeIslandCore

/// Claude Code sessions: running `claude` processes matched to their
/// transcripts under each config dir's `projects/<encoded cwd>/`, and the
/// Claude-format JSONL reader that the tailer, model backfill and the
/// agents sharing the format use.
enum ClaudeDiscovery {
    /// Read Claude model from a session transcript file.
    static func readModelFromTranscript(sessionId: String, cwd: String?) -> String? {
        guard let cwd = cwd else { return nil }
        let projectDir = cwd.claudeProjectDirEncoded()
        // The transcript sits under whichever config dir (account) ran it.
        guard let path = ClaudeConfigPaths.transcriptPath(projectDir: projectDir, sessionId: sessionId),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        let chunk = handle.readData(ofLength: 32768)
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty
            else { continue }
            return model
        }
        return nil
    }

    /// Find running `claude` processes, match to transcript files, extract recent messages
    static func findActiveClaudeSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        // Step 1: find running claude processes using native APIs
        let claudePids = AgentProcessFinder.findClaudePids(candidatePids: candidatePids)
        guard !claudePids.isEmpty else { return [] }

        let fm = FileManager.default
        let processes = claudePids.compactMap { pid -> ClaudeDiscoveryProcess? in
            guard let cwd = ProcessTable.getCwd(for: pid), !cwd.isEmpty else { return nil }
            // Skip subagent worktrees — they are child tasks, not independent sessions
            if cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
                return nil
            }
            // Process start time filters stale transcript files
            return ClaudeDiscoveryProcess(pid: pid, cwd: cwd, startTime: ProcessTable.getProcessStartTime(pid))
        }

        // Each process is matched in the config dir it writes to (its
        // CLAUDE_CONFIG_DIR); ConfigRootDiscovery places the ones whose
        // environment cannot be read and skips paused dirs.
        let scan = SessionDiscovery.configRootScan(for: .claude)
        // Processes in the same cwd share a project dir (a dozen terminals in ~
        // is common): list each dir once per scan, not once per process.
        var listings: [String: [ClaudeTranscriptFile]] = [:]
        func transcripts(in projectPath: String) -> [ClaudeTranscriptFile]? {
            if let cached = listings[projectPath] { return cached }
            guard let files = claudeTranscriptFiles(in: projectPath, fm: fm) else { return nil }
            listings[projectPath] = files
            return files
        }
        return ConfigRootDiscovery.run(
            processes: processes,
            lookup: { scan.lookup(pid: $0.pid) },
            fallbackRoots: scan.fallbackRoots,
            discover: { root, group, claimed in
                var taken = claimed
                return group.compactMap { process in
                    guard let session = claudeSession(
                        for: process, root: root, excluding: taken, transcripts: transcripts(in:)
                    ) else {
                        return nil
                    }
                    taken.insert(session.sessionId)
                    return session
                }
            },
            sessionId: \.sessionId,
            belongsTo: { $0.pid == $1.pid }
        )
    }

    struct ClaudeDiscoveryProcess {
        let pid: pid_t
        let cwd: String
        let startTime: Date?
    }

    struct ClaudeTranscriptFile {
        let name: String
        let modified: Date
    }

    /// The `.jsonl` transcripts in one Claude project dir with their mtimes,
    /// read in one bulk directory listing instead of a stat per file.
    ///
    /// Unlike `contentsOfDirectory(atPath:)`, the URL listing fails on a
    /// project dir that is itself a symlink, so resolve the dir first. Entries
    /// are not resolved: a symlinked transcript still reports its own mtime,
    /// as the per-file stat did.
    static func claudeTranscriptFiles(in projectPath: String, fm: FileManager) -> [ClaudeTranscriptFile]? {
        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: projectPath, isDirectory: true).resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".jsonl"),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return ClaudeTranscriptFile(name: name, modified: modified)
        }
    }

    /// One claude process → its CWD → the single most recent .jsonl under `root`.
    private static func claudeSession(
        for process: ClaudeDiscoveryProcess,
        root: String,
        excluding claimed: Set<String>,
        transcripts: (_ projectPath: String) -> [ClaudeTranscriptFile]?
    ) -> DiscoveredSession? {
        let projectPath = "\(root)/projects/\(process.cwd.claudeProjectDirEncoded())"
        guard let files = transcripts(projectPath) else { return nil }

        // Find the most recently modified .jsonl that was written AFTER this process started
        var bestFile: String?
        var bestDate = Date.distantPast
        for file in files where file.modified > bestDate {
            // Skip files from old sessions: must be modified after process started
            if let start = process.startTime, file.modified < start.addingTimeInterval(-10) {
                continue
            }
            bestDate = file.modified
            bestFile = file.name
        }

        guard let file = bestFile else { return nil }

        // Skip stale transcripts: only show sessions active within last 5 minutes.
        // When processStart is unknown (proc_pidinfo failed), use a tighter 30s window
        // to avoid resurrecting zombie sessions from stale transcript files.
        let freshnessLimit: TimeInterval = process.startTime != nil ? -300 : -30
        if bestDate.timeIntervalSinceNow < freshnessLimit { return nil }

        let sessionId = String(file.dropLast(6))
        guard !claimed.contains(sessionId) else { return nil }

        let fullPath = "\(projectPath)/\(file)"
        let (model, messages) = readRecentFromTranscript(path: fullPath)

        return DiscoveredSession(
            sessionId: sessionId,
            cwd: process.cwd,
            tty: nil,
            model: model,
            pid: process.pid,
            modifiedAt: bestDate,
            recentMessages: messages,
            transcriptPath: fullPath
        )
    }

    /// Read model and last 3 user/assistant messages from a transcript file's tail
    /// First text block of a transcript row worth showing, cleaned the way the
    /// live tail cleans it (`JSONLTailer.extractText`): mcode's reasoning blobs
    /// are skipped and leading injected wrappers removed, so a card rebuilt on
    /// attach reads the same as one fed by the tailer.
    static func firstDisplayText(in blocks: [[String: Any]]) -> String? {
        for block in blocks {
            guard block["type"] as? String == "text",
                  let raw = block["text"] as? String,
                  !JSONLTailer.isThinkingBlob(raw) else { continue }
            let text = JSONLTailer.stripDisplayWrappers(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    static func readRecentFromTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        // Read last 64KB
        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let type = json["type"] as? String
            let message = (json["message"] as? [String: Any]) ?? json
            let role = (message["role"] as? String) ?? type

            guard let role else { continue }
            let normalizedRole = role.lowercased()

            if model == nil, let m = message["model"] as? String, !m.isEmpty {
                model = m
            }

            // Extract text content
            var textContent: String?
            if normalizedRole == "user" || normalizedRole == "user_input" {
                if let content = message["content"] as? String {
                    textContent = JSONLTailer.stripDisplayWrappers(content)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let contentArray = message["content"] as? [[String: Any]] {
                    textContent = firstDisplayText(in: contentArray)
                }
            } else if normalizedRole == "assistant" || normalizedRole == "planner_response" {
                if let content = message["content"] as? String {
                    textContent = JSONLTailer.isThinkingBlob(content)
                        ? nil
                        : content.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let contentArray = message["content"] as? [[String: Any]] {
                    textContent = firstDisplayText(in: contentArray)
                } else if let thinking = message["thinking"] as? String {
                    textContent = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if let text = textContent, !text.isEmpty {
                if normalizedRole == "user" || normalizedRole == "user_input" {
                    // Same rules as the live tail: injected (isMeta) rows and
                    // local slash commands (/model) are not prompts; a prompt
                    // command reads as typed ("/review foo").
                    if json["isMeta"] as? Bool != true {
                        switch JSONLTailer.claudeCommandEcho(text) {
                        case .local?: break
                        case .prompt(let command)?: userMessages.append((index, command))
                        case nil: userMessages.append((index, text))
                        }
                    }
                } else if normalizedRole == "assistant" || normalizedRole == "planner_response" {
                    assistantMessages.append((index, text))
                }
            }
            index += 1
        }

        // Build recent messages: take last few user+assistant, sorted by order, keep 3
        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        let recent = Array(combined.suffix(3).map { $0.1 })

        return (model, recent)
    }
}
