import Foundation

/// What an edge that cannot run HookIntake sends instead of interpreting its
/// hook: the facts it observed, in its payload's `_edge` object, next to the
/// agent's stdin object (docs/hook-edge-protocol.md). HookServer runs
/// HookIntake on them as codeisland-bridge does on its own side, so the
/// remote hook gets the bridge's interpretation instead of a copy of it.
///
/// A payload without `_edge` is its edge's own interpretation — the bridge's,
/// a plugin's, a remote hook installed before this existed — and is taken as
/// it is.
public enum HookEdgeFacts {
    /// The payload key the facts travel under.
    public static let key = "_edge"

    /// The version of the facts this island reads. Fields are added without
    /// changing it; it changes only if a field changes meaning. Facts naming
    /// another version are read for the fields this one knows.
    public static let version = 1

    /// What an `_edge` payload delivers.
    public enum Delivery {
        /// Nothing to forward: the facts rule it out (CODEISLAND_SKIP, a hook
        /// Grok imported) or it names no session. The edge gets no answer.
        case dropped
        case interpreted(HookIntake)
    }

    /// What a local edge's facts are read against: this Mac's home and files.
    /// An edge on another machine gets neither.
    public struct LocalMachine {
        public var homeDirectory: () -> String?
        public var fileExists: (String) -> Bool

        public init(homeDirectory: @escaping () -> String?, fileExists: @escaping (String) -> Bool) {
            self.homeDirectory = homeDirectory
            self.fileExists = fileExists
        }

        public static var current: LocalMachine {
            LocalMachine(
                homeDirectory: { FileManager.default.homeDirectoryForCurrentUser.path },
                fileExists: { FileManager.default.fileExists(atPath: $0) }
            )
        }
    }

    private static let keyBytes = Data(#""_edge""#.utf8)

    /// Cheap probe on the raw bytes: a payload that cannot carry facts is
    /// never parsed for them.
    public static func mayCarryFacts(_ data: Data) -> Bool {
        data.range(of: keyBytes) != nil
    }

    /// What `payload` delivers, or nil when it carries no `_edge` facts.
    public static func delivery(
        in payload: [String: Any],
        localMachine: LocalMachine = .current
    ) -> Delivery? {
        guard let edge = payload[key] as? [String: Any] else { return nil }
        let facts = facts(from: edge, localMachine: localMachine)
        guard HookIntake.admits(sourceTag: facts.sourceTag, environment: facts.environment) else {
            return .dropped
        }
        guard var intake = HookIntake(stdin: payload, facts: facts) else { return .dropped }
        intake.addTerminalContext()
        return .interpreted(intake)
    }

    /// HookIntake's facts from an `_edge` object.
    public static func facts(from edge: [String: Any], localMachine: LocalMachine = .current) -> HookIntake.Facts {
        let source = string(edge["source"])
        // Claude Code's hook is the one other agents run too — Cursor imports it
        // (#377), omo fires it — so on this Mac it carries no `--source`, and the
        // payload or the process tree names the agent. An edge's `claude` is that
        // same hook: read as no tag, with Claude what is left when nothing else
        // names the agent.
        let isClaudesOwnHook = SessionSnapshot.normalizedSupportedSource(source) == "claude"
        let environment = (edge["env"] as? [String: Any] ?? [:])
            .compactMapValues { $0 as? String }
            .filter { HookIntake.environmentKeys.contains($0.key) }
        let tty = string(edge["tty"])
        let digest = string(edge["stdin_sha256"])
        let tmuxClientTTY = string(edge["tmux_client_tty"])

        var facts = HookIntake.Facts(
            sourceTag: isClaudesOwnHook ? nil : source,
            eventTag: string(edge["event"]),
            defaultSource: isClaudesOwnHook ? "claude" : nil,
            environment: environment,
            workingDirectory: string(edge["cwd"]),
            tty: { tty },
            stdinDigest: { digest },
            tmuxClientTTY: { _ in tmuxClientTTY }
        )
        if let host = edge["host"] as? [String: Any] {
            // Another machine: none of its processes, files or home are this
            // Mac's, so nothing is looked up for it here.
            facts.remoteHost = HookIntake.EdgeHost(
                id: host["id"] as? String ?? "",
                name: host["name"] as? String ?? ""
            )
        } else {
            facts.parentPID = pid(edge["ppid"])
            facts.homeDirectory = localMachine.homeDirectory
            facts.fileExists = localMachine.fileExists
        }
        return facts
    }

    /// A process id, or nil for anything else — `true`, a fraction, a number
    /// past pid_t's range.
    private static func pid(_ value: Any?) -> Int32? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int32(exactly: number.doubleValue)
    }

    private static func string(_ value: Any?) -> String? {
        guard let raw = value as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }
}
