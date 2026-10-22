import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The shipped remote hook against a real HookServer on a throwaway socket:
/// the hook sends facts, HookServer interprets them (HookIntake) and answers
/// as the agent reads it.
@MainActor
final class HookServerEdgeFactsTests: XCTestCase {
    private var sandbox: URL!
    private var hookURL: URL!
    private var socketPath: String!
    private var server: HookServer!
    private var appState: AppState!
    private var savedSocketPath: String?
    private var savedAutoApproveTools: Any?

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-server-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let source = try XCTUnwrap(RemoteInstaller.remoteHookSource(), "remote hook resource missing")
        hookURL = sandbox.appendingPathComponent("codeisland-remote-hook.py")
        try Data(source.utf8).write(to: hookURL)

        // sun_path holds 104 bytes; the temporary directory's path is too long.
        socketPath = "/tmp/ci-hs-\(UUID().uuidString.prefix(8)).sock"
        savedSocketPath = ProcessInfo.processInfo.environment["CODEISLAND_SOCKET_PATH"]
        setenv("CODEISLAND_SOCKET_PATH", socketPath, 1)
        savedAutoApproveTools = UserDefaults.standard.object(forKey: SettingsKey.autoApproveTools)
        // An internal tool the island approves without a card, so a blocking
        // request is answered without anyone at the UI.
        UserDefaults.standard.set("TodoWrite", forKey: SettingsKey.autoApproveTools)

        appState = AppState()
        server = HookServer(appState: appState)
        server.start()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socketPath), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw XCTSkip("HookServer did not start listening")
        }
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        appState = nil
        if let savedSocketPath {
            setenv("CODEISLAND_SOCKET_PATH", savedSocketPath, 1)
        } else {
            unsetenv("CODEISLAND_SOCKET_PATH")
        }
        if let savedAutoApproveTools {
            UserDefaults.standard.set(savedAutoApproveTools, forKey: SettingsKey.autoApproveTools)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.autoApproveTools)
        }
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// Runs the remote hook on `stdin` as CODEISLAND_SOURCE=`source`, without
    /// blocking the main queue HookServer answers on. Returns what it printed.
    private func runHook(source: String, stdin: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [hookURL.path]
        // The hook's cwd is a fact the island reads; not the test runner's,
        // which may itself be an agent's worktree the island skips.
        process.currentDirectoryURL = sandbox
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = sandbox.path
        environment["CODEISLAND_SOCKET_PATH"] = socketPath
        environment["CODEISLAND_SOURCE"] = source
        environment["CODEISLAND_REMOTE_HOST_ID"] = "host-1"
        environment["CODEISLAND_REMOTE_HOST_NAME"] = "Build Box"
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = expectation(description: "the hook exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        wait(for: [exited], timeout: 15)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testGeminiApprovalComesBackAsGeminiReadsIt() throws {
        let printed = try runHook(
            source: "gemini",
            stdin: #"{"hook_event_name":"BeforeTool","session_id":"gem-1","cwd":"/work/proj","tool_name":"TodoWrite","tool_input":{}}"#
        )
        XCTAssertEqual(printed, #"{"decision":"allow"}"# + "\n")
    }

    func testClaudeApprovalComesBackVerbatim() throws {
        let printed = try runHook(
            source: "claude",
            stdin: #"{"hook_event_name":"PermissionRequest","session_id":"sess-1","cwd":"/work/proj","tool_name":"TodoWrite","tool_input":{}}"#
        )
        XCTAssertEqual(
            printed,
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"# + "\n"
        )
    }

    /// A hook HookIntake does not hold (one Cursor runs) is answered at once
    /// with nothing: no card, nothing printed, the agent is not kept waiting.
    func testCursorPermissionIsAnsweredWithNothingAtOnce() throws {
        let started = Date()
        let printed = try runHook(
            source: "claude",
            stdin: #"{"hook_event_name":"PermissionRequest","session_id":"conv-1","cursor_version":"3.25.9","tool_name":"Shell","question":"Run?"}"#
        )
        XCTAssertEqual(printed, "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertNil(appState.pendingPermission)
    }

    /// A remote event lands on its card as the island reads it: the source
    /// from the payload (#377), the host from the facts.
    func testRemoteEventReachesItsCard() throws {
        let printed = try runHook(
            source: "claude",
            stdin: #"{"hook_event_name":"beforeSubmitPrompt","session_id":"conv-2","conversation_id":"conv-2","cursor_version":"3.25.9","prompt":"Fix it","workspace_roots":["/work/proj"]}"#
        )
        XCTAssertEqual(printed, "")
        // A remote host's sessions have a namespace of their own.
        let card = "remote:host-1:conv-2"
        let deadline = Date().addingTimeInterval(5)
        while appState.sessions[card] == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let session = try XCTUnwrap(appState.sessions[card])
        XCTAssertEqual(session.source, "cursor")
        XCTAssertEqual(session.remoteHostId, "host-1")
        XCTAssertEqual(session.remoteHostName, "Build Box")
        XCTAssertEqual(session.lastUserPrompt, "Fix it")
    }
}
