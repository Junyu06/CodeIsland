import Darwin
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The hook socket's default path is a predictable name in /tmp, which
/// another user can take first: a socket of theirs would be sent every hook's
/// payload and could answer a permission request. So every hook sends only to
/// a socket this user owns (and the island says so when the path is taken:
/// HookSocketHealthTests). The real bridge, hook script and remote hook run
/// here against stand-in sockets, never the user's live one.
@MainActor
final class HookSocketOwnershipTests: XCTestCase {
    private var scratch: String!

    override func setUpWithError() throws {
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        scratch = "/tmp/ci-sown-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    /// A symlink to `target`: connect() follows it, lstat does not.
    private func link(to target: String) throws -> String {
        let path = scratch + "/link.sock"
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        return path
    }

    /// Lets a stand-in island that nothing reached go: its accept() returns,
    /// so it closes and removes its socket instead of waiting forever. Read
    /// to its close: it answers in this process, and an answer to a closed
    /// peer would SIGPIPE it.
    private func release(_ server: OneShotUnixServer) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(server.path.utf8)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return }
        shutdown(fd, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 256)
        while read(fd, &buffer, buffer.count) > 0 {}
        _ = server.waitUntilServed(timeout: 5)
    }

    // MARK: - The bridge

    private func bridgeBinary() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("codeisland-bridge")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("codeisland-bridge not built next to the test bundle")
        }
        return url
    }

    /// Runs the real bridge on a prompt event, with its socket at `socketPath`;
    /// returns its exit status, what it printed and what it logged.
    private func runBridge(socketPath: String) throws -> (status: Int32, stdout: String, log: String) {
        let log = scratch + "/bridge.log"
        let process = Process()
        process.executableURL = try bridgeBinary()
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "CODEISLAND_SOCKET_PATH": socketPath,
            "CODEISLAND_BRIDGE_LOG": log,
        ]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let payload = #"{"hook_event_name":"UserPromptSubmit","session_id":"sown-1","cwd":"/tmp","prompt":"SECRET-PROMPT"}"#
        // The bridge may be gone before it reads: a broken pipe is fine.
        try? stdin.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let logged = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), logged)
    }

    func testBridgeSendsToASocketThisUserOwns() throws {
        let server = try XCTUnwrap(OneShotUnixServer(reply: Data("{}".utf8)))
        let run = try runBridge(socketPath: server.path)

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(server.waitUntilServed(timeout: 5))
        XCTAssertTrue(String(decoding: server.received, as: UTF8.self).contains("SECRET-PROMPT"))
    }

    func testBridgeSendsNothingThroughASymlink() throws {
        let server = try XCTUnwrap(OneShotUnixServer(reply: Data("{}".utf8)))
        let run = try runBridge(socketPath: try link(to: server.path))

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertFalse(server.waitUntilServed(timeout: 1), "the bridge connected through a symlink")
        release(server)
        XCTAssertFalse(run.log.contains("SECRET-PROMPT"), "the bridge read the event before checking the socket")
    }

    /// A real socket another user owns (syslogd's, root's). Were the check
    /// gone, the bridge would read and log the event before its connect
    /// failed; it stops before reading anything.
    func testBridgeSendsNothingToAnotherUsersSocket() throws {
        let path = "/var/run/syslog"
        guard case .otherUser = SocketPath.holder(of: path) else {
            throw XCTSkip("no socket of another user's at \(path)")
        }
        let run = try runBridge(socketPath: path)

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout, "")
        XCTAssertEqual(run.log, "", "the bridge went past the ownership check")
    }

    // MARK: - The hook script's fallback (no bridge installed)

    /// Runs the hook script with no bridge in HOME, so its nc fallback sends
    /// the event, to `socketPath` instead of the user's live socket.
    private func runHookScriptFallback(socketPath: String) throws {
        let live = #"SOCK="/tmp/codeisland-$(id -u).sock""#
        let script = ConfigInstaller.hookScript
        let redirected = script.replacingOccurrences(of: live, with: "SOCK=\"\(socketPath)\"")
        guard redirected != script, !redirected.contains("/tmp/codeisland-$(id -u)") else {
            return XCTFail("the hook script no longer names its socket as \(live)")
        }
        let scriptPath = scratch + "/codeisland-hook.sh"
        try Data(redirected.utf8).write(to: URL(fileURLWithPath: scriptPath))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": scratch]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? stdin.fileHandleForWriting.write(contentsOf: Data(#"{"hook_event_name":"Stop","session_id":"sown-2"}"#.utf8))
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testHookScriptFallbackSendsToASocketThisUserOwns() throws {
        let server = try XCTUnwrap(OneShotUnixServer(reply: Data()))
        try runHookScriptFallback(socketPath: server.path)

        XCTAssertTrue(server.waitUntilServed(timeout: 5))
        XCTAssertTrue(String(decoding: server.received, as: UTF8.self).contains("sown-2"))
    }

    func testHookScriptFallbackSendsNothingThroughASymlink() throws {
        let server = try XCTUnwrap(OneShotUnixServer(reply: Data()))
        try runHookScriptFallback(socketPath: try link(to: server.path))

        XCTAssertFalse(server.waitUntilServed(timeout: 1), "the fallback connected through a symlink")
        release(server)
    }

    // MARK: - The remote hook

    /// Runs the shipped remote hook's `main()` against a stand-in island at a
    /// path of the driver's; `mode` is how the hook finds it: "direct", through
    /// a "link", or "foreign" (its lstat reporting another owner). Returns what
    /// the island received, nil for nothing.
    private func runRemoteHook(_ mode: String, socketOwnerUID: String? = nil) throws -> String? {
        // The stand-in island of an earlier run in this test left its socket.
        unlink(scratch + "/island.sock")
        unlink(scratch + "/link.sock")
        let hookURL = URL(fileURLWithPath: scratch + "/codeisland-remote-hook.py")
        try Data(XCTUnwrap(RemoteInstaller.remoteHookSource()).utf8).write(to: hookURL)
        let driver = """
        import importlib.util, io, json, os, socket, sys, threading
        hook_path, scratch, mode = sys.argv[1], sys.argv[2], sys.argv[3]
        island = os.path.join(scratch, "island.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(island)
        server.listen(1)
        server.settimeout(1.5)
        received = {}
        def serve():
            try:
                conn, _ = server.accept()
            except OSError:
                return
            data = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            received["payload"] = data.decode("utf-8")
            conn.close()
        thread = threading.Thread(target=serve)
        thread.start()
        path = island
        if mode == "link":
            path = os.path.join(scratch, "link.sock")
            os.symlink(island, path)
        os.environ["CODEISLAND_SOCKET_PATH"] = path
        spec = importlib.util.spec_from_file_location("hook", hook_path)
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        if mode == "foreign":
            real_lstat = os.lstat
            def foreign_lstat(target, *args, **kwargs):
                info = real_lstat(target, *args, **kwargs)
                return os.stat_result((info.st_mode, info.st_ino, info.st_dev, info.st_nlink,
                                       info.st_uid + 1, info.st_gid, info.st_size,
                                       int(info.st_atime), int(info.st_mtime), int(info.st_ctime)))
            hook.os.lstat = foreign_lstat
        hook._get_tty = lambda: "/dev/pts/7"
        sys.stdin = io.TextIOWrapper(io.BytesIO(b'{"hook_event_name":"Stop","session_id":"sown-3"}'), encoding="utf-8")
        printed = io.StringIO()
        real_stdout, sys.stdout = sys.stdout, printed
        try:
            hook.main()
        finally:
            sys.stdout = real_stdout
        thread.join(3)
        print(json.dumps({"received": received.get("payload")}))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path, scratch, mode]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = scratch
        environment["CODEISLAND_SOURCE"] = "claude"
        environment["CODEISLAND_REMOTE_HOST_ID"] = "host-1"
        environment["CODEISLAND_REMOTE_HOST_NAME"] = "Build Box"
        environment["CODEISLAND_SOCKET_OWNER_UID"] = socketOwnerUID
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "hook driver failed: \(err)")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        return result["received"] as? String
    }

    func testRemoteHookSendsToASocketThisUserOwns() throws {
        XCTAssertTrue(try XCTUnwrap(runRemoteHook("direct")).contains("sown-3"))
    }

    func testRemoteHookSendsNothingThroughASymlink() throws {
        XCTAssertNil(try runRemoteHook("link"))
    }

    func testRemoteHookSendsNothingToAnotherUsersSocket() throws {
        XCTAssertNil(try runRemoteHook("foreign"))
    }

    /// A host whose agents run as other users: each hook is told the SSH user
    /// owns the island's socket (sshd made it as that user), and a hook run as
    /// another user sends to it. "foreign" is a socket uid + 1 owns.
    func testRemoteHookSendsToTheSocketOwnerItIsTold() throws {
        let sshUser = String(getuid() + 1)
        XCTAssertTrue(try XCTUnwrap(runRemoteHook("foreign", socketOwnerUID: sshUser)).contains("sown-3"))
    }

    /// And to no other socket: not its own user's, not through a symlink.
    func testRemoteHookSendsNothingToASocketTheNamedOwnerDoesNotOwn() throws {
        XCTAssertNil(try runRemoteHook("direct", socketOwnerUID: String(getuid() + 1)))
        XCTAssertNil(try runRemoteHook("link", socketOwnerUID: String(getuid())))
    }

    /// A malformed owner names nobody: the hook's own user it is.
    func testRemoteHookTakesAMalformedOwnerForItsOwnUser() throws {
        XCTAssertTrue(try XCTUnwrap(runRemoteHook("direct", socketOwnerUID: "1x")).contains("sown-3"))
        XCTAssertNil(try runRemoteHook("foreign", socketOwnerUID: "1x"))
    }
}
