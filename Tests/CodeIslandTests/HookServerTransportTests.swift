import Darwin
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// HookServer's socket against real clients on a throwaway path: what a
/// hook writes reaches the island however early the hook closes and however
/// busy the main thread is, a held request waits for its answer, and one
/// whose hook is gone is dropped.
@MainActor
final class HookServerTransportTests: XCTestCase {
    private var socketPath: String!
    private var appState: AppState!
    private var server: HookServer!

    override func setUpWithError() throws {
        // sun_path holds 104 bytes; the temporary directory's path is too long.
        socketPath = "/tmp/ci-ht-\(UUID().uuidString.prefix(8)).sock"
        appState = AppState()
        server = HookServer(appState: appState, socketPath: socketPath)
        XCTAssertTrue(server.start(), "HookServer did not listen on \(socketPath!)")
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        appState = nil
        unlink(socketPath)
    }

    /// A payload a remote hook installed before `_edge` sends: its own
    /// interpretation, filed under its host.
    private func remotePayload(_ event: String, session: String, extra: String = "") -> String {
        #"{"hook_event_name":"\#(event)","session_id":"\#(session)","cwd":"/work/proj","_source":"claude","_remote_host_id":"host-1","_remote_host_name":"Build Box"\#(extra)}"#
    }

    /// A PermissionRequest for one tool call, as a remote hook sends it.
    private func permissionPayload(session: String, toolUseId: String, command: String = "make") -> String {
        remotePayload(
            "PermissionRequest",
            session: session,
            extra: #","tool_name":"Bash","tool_use_id":"\#(toolUseId)","tool_input":{"command":"\#(command)"}"#
        )
    }

    /// Runs the main run loop until `condition` holds; false (and a failure) after `timeout`.
    @discardableResult
    private func pump(
        until condition: () -> Bool,
        timeout: TimeInterval = 5,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail(message, file: file, line: line)
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    private func pump(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Replaces the server with one on a socket of its own, checking held
    /// requests' hooks every `heldRequestCheckInterval`.
    private func restartServer(heldRequestCheckInterval: TimeInterval) {
        server.stop()
        socketPath = "/tmp/ci-ht-\(UUID().uuidString.prefix(8)).sock"
        server = HookServer(appState: appState, socketPath: socketPath, heldRequestCheckInterval: heldRequestCheckInterval)
        XCTAssertTrue(server.start(), "HookServer did not listen on \(socketPath!)")
    }

    /// A hook that does not wait for an answer writes its event and closes at
    /// once — while the island's main thread is busy (rendering, a
    /// synchronous read). NWListener dropped such a connection whenever its
    /// peer had closed before it was set up, and the event was lost.
    func testEventsFromHooksThatCloseAtOnceSurviveABusyMainThread() throws {
        let path = socketPath!
        let count = 10
        for index in 0..<count {
            let payload = remotePayload("UserPromptSubmit", session: "early-\(index)", extra: #","prompt":"p\#(index)""#)
            let sent = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                RawHook.sendAndClose(payload, to: path)
                sent.signal()
            }
            // The main thread is busy while the hook connects, writes and
            // closes, and for a while after.
            XCTAssertEqual(sent.wait(timeout: .now() + 5), .success)
            usleep(150_000)
        }
        let delivered = { self.appState.sessions.keys.filter { $0.hasPrefix("remote:host-1:early-") }.count }
        pump(until: { delivered() == count }, "\(delivered()) of \(count) events reached the island")
    }

    /// The shipped remote hook, with the island's main thread busy after
    /// each hook starts.
    func testFireAndForgetRemoteEventsSurviveABusyMainThread() throws {
        let sandbox = URL(fileURLWithPath: "/tmp/ci-ht-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent("home"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let hookURL = sandbox.appendingPathComponent("codeisland-remote-hook.py")
        try Data(XCTUnwrap(RemoteInstaller.remoteHookSource()).utf8).write(to: hookURL)

        for index in 0..<5 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [hookURL.path]
            process.currentDirectoryURL = sandbox
            process.environment = [
                "PATH": "/usr/bin:/bin",
                "HOME": sandbox.appendingPathComponent("home").path,
                "CODEISLAND_SOCKET_PATH": socketPath,
                "CODEISLAND_SOURCE": "opencode",
                "CODEISLAND_REMOTE_HOST_ID": "host-1",
                "CODEISLAND_REMOTE_HOST_NAME": "Build Box",
            ]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            // The remote OpenCode plugin's payload shape (it names its tty).
            input.fileHandleForWriting.write(Data(#"{"session_id":"busy-\#(index)","hook_event_name":"UserPromptSubmit","cwd":"/work/proj","prompt":"p\#(index)","_tty":"/dev/pts/7"}"#.utf8))
            try input.fileHandleForWriting.close()
            usleep(300_000)  // the island's main thread is busy
            pump(until: { !process.isRunning }, timeout: 10, "the hook did not exit")
        }
        let delivered = { (0..<5).filter { self.appState.sessions["remote:host-1:busy-\($0)"] != nil }.count }
        pump(until: { delivered() == 5 }, "\(delivered()) of 5 remote events reached the island")
    }

    /// A blocking request: the hook half-closes once it has written, which is
    /// not a disconnect — the card stays, and the answer reaches the hook.
    func testAHeldRequestWaitsForItsAnswer() throws {
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        hook.write(remotePayload("PermissionRequest", session: "held-1", extra: #","tool_name":"Bash","tool_input":{"command":"make"}"#))
        let answer = hook.readAnswerInBackground()

        pump(until: { self.appState.pendingPermission != nil }, "no card for the request")
        pump(for: 0.5)
        XCTAssertNotNil(appState.pendingPermission, "the hook's half-close was taken for a disconnect")

        appState.approvePermission()
        pump(until: { answer.value != nil }, "the answer did not reach the hook")
        let text = String(decoding: answer.value ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""behavior":"allow""#), text)
        hook.close()
    }

    /// A held request stays answerable for as long as its hook waits — the
    /// bridge waits up to a day for someone who stepped away (#306). The
    /// safety net that checks held requests now and then never cuts off a
    /// hook that is still there.
    func testAHeldRequestOutlivesTheSafetyNet() throws {
        restartServer(heldRequestCheckInterval: 0.1)
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        hook.write(permissionPayload(session: "away", toolUseId: "tu-away"))
        let answer = hook.readAnswerInBackground()

        pump(until: { self.appState.pendingPermission != nil }, "no card for the request")
        pump(for: 1)  // ten rounds of the safety net
        XCTAssertNotNil(appState.pendingPermission, "the safety net dropped a request whose hook still waits")
        XCTAssertNil(answer.value, "the safety net cut off a waiting hook")

        appState.approvePermission()
        pump(until: { answer.value != nil }, "the answer did not reach the hook")
        XCTAssertTrue(String(decoding: answer.value ?? Data(), as: UTF8.self).contains(#""behavior":"allow""#))
        hook.close()
    }

    /// A blocking request whose hook is gone (killed, or its agent answered
    /// in the terminal) drops its card at once.
    func testAHeldRequestEndsWithItsHook() throws {
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        hook.write(remotePayload("PermissionRequest", session: "held-2", extra: #","tool_name":"Bash","tool_input":{"command":"make"}"#))

        pump(until: { self.appState.pendingPermission != nil }, "no card for the request")
        hook.close()
        pump(until: { self.appState.pendingPermission == nil }, timeout: 2, "the card outlived its hook")
    }

    /// Two held requests of one session and agent — parallel tool calls —
    /// and one hook goes: its card goes, and only its. The other hook still
    /// waits on the user, and gets the user's answer.
    func testAHookThatGoesTakesOnlyItsOwnRequest() throws {
        let gone = try XCTUnwrap(RawHook.connect(to: socketPath))
        gone.write(permissionPayload(session: "pair", toolUseId: "tu-a"))
        pump(until: { self.appState.permissionQueue.count == 1 }, "no card for the first request")
        let waiting = try XCTUnwrap(RawHook.connect(to: socketPath))
        waiting.write(permissionPayload(session: "pair", toolUseId: "tu-b", command: "make test"))
        let answer = waiting.readAnswerInBackground()
        pump(until: { self.appState.permissionQueue.count == 2 }, "no card for the second request")

        gone.close()
        pump(until: { self.appState.permissionQueue.count != 2 }, timeout: 2, "the card outlived its hook")
        pump(for: 0.3)
        XCTAssertEqual(appState.permissionQueue.map(\.toolUseId), ["tu-b"], "a sibling's card went with the hook")
        XCTAssertNil(answer.value, "the waiting hook was answered without the user: \(String(decoding: answer.value ?? Data(), as: UTF8.self))")

        appState.approvePermission()
        pump(until: { answer.value != nil }, "the answer did not reach the waiting hook")
        XCTAssertTrue(String(decoding: answer.value ?? Data(), as: UTF8.self).contains(#""behavior":"allow""#))
        waiting.close()
    }

    /// The same for two questions of one session.
    func testAQuestionsHookThatGoesTakesOnlyItsOwnQuestion() throws {
        let gone = try XCTUnwrap(RawHook.connect(to: socketPath))
        gone.write(remotePayload("Notification", session: "ask", extra: #","question":"First?""#))
        pump(until: { self.appState.questionQueue.count == 1 }, "no card for the first question")
        let waiting = try XCTUnwrap(RawHook.connect(to: socketPath))
        waiting.write(remotePayload("Notification", session: "ask", extra: #","question":"Second?""#))
        let answer = waiting.readAnswerInBackground()
        pump(until: { self.appState.questionQueue.count == 2 }, "no card for the second question")

        gone.close()
        pump(until: { self.appState.questionQueue.count != 2 }, timeout: 2, "the question outlived its hook")
        pump(for: 0.3)
        XCTAssertEqual(appState.questionQueue.map(\.question.question), ["Second?"], "a sibling's question went with the hook")
        XCTAssertNil(answer.value, "the waiting hook was answered without the user: \(String(decoding: answer.value ?? Data(), as: UTF8.self))")

        waiting.close()
        pump(until: { self.appState.questionQueue.isEmpty }, timeout: 2, "the question outlived its hook")
    }

    /// A replay of a held request (the same tool call, asked again) takes
    /// the first one's place, and the first hook gets its answer. The card
    /// then goes with the replay's hook, not with the first one's.
    func testAReplayedRequestGoesWithTheReplaysHook() throws {
        let first = try XCTUnwrap(RawHook.connect(to: socketPath))
        first.write(permissionPayload(session: "replay", toolUseId: "tu-r"))
        let firstAnswer = first.readAnswerInBackground()
        pump(until: { self.appState.permissionQueue.count == 1 }, "no card for the request")
        let replay = try XCTUnwrap(RawHook.connect(to: socketPath))
        replay.write(permissionPayload(session: "replay", toolUseId: "tu-r"))
        pump(until: { firstAnswer.value != nil }, "the replay did not let the first hook go")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        first.close()
        pump(for: 0.5)
        XCTAssertEqual(appState.permissionQueue.count, 1, "the replay's card went with the first hook")
        replay.close()
        pump(until: { self.appState.permissionQueue.isEmpty }, timeout: 2, "the card outlived the replay's hook")
    }

    /// Every held request is watched through one kqueue: holding one costs
    /// its socket and nothing more. It cost a kqueue of its own as well, and
    /// launchd's 256 descriptors ran out twice as fast.
    func testHeldRequestsShareOneKqueue() throws {
        let before = try openKqueues()
        var hooks: [RawHook] = []
        for index in 0..<10 {
            let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
            hook.write(permissionPayload(session: "fd-\(index)", toolUseId: "tu-\(index)"))
            hooks.append(hook)
        }
        pump(until: { self.appState.permissionQueue.count == 10 }, "no cards for the requests")
        pump(for: 0.3)  // every watch is set
        XCTAssertLessThanOrEqual(try openKqueues() - before, 1, "a held request costs a kqueue of its own")

        hooks.forEach { $0.close() }
        pump(until: { self.appState.permissionQueue.isEmpty }, timeout: 2, "cards outlived their hooks")
    }

    /// This process's open kqueues.
    private func openKqueues() throws -> Int {
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { throw XCTSkip("proc_pidinfo: \(String(cString: strerror(errno)))") }
        var infos = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &infos, size)
        return infos.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_KQUEUE) }
            .count
    }

    /// More than the island reads of one request is refused, and nothing
    /// reaches a card.
    func testAnOversizedRequestIsDenied() throws {
        let hook = try XCTUnwrap(RawHook.connect(to: socketPath))
        let answer = hook.writeInBackground(Data(repeating: UInt8(ascii: " "), count: 10_485_761), thenRead: true)
        pump(until: { answer.value != nil }, timeout: 10, "no answer to an oversized request")
        XCTAssertTrue(String(decoding: answer.value ?? Data(), as: UTF8.self).contains(#""behavior":"deny""#))
        XCTAssertNil(appState.pendingPermission)
        hook.close()
    }
}

/// One HookConnection on a socket pair, the hook's end in the test's hands.
final class HookConnectionTests: XCTestCase {
    private let queue = DispatchQueue(label: "HookConnectionTests")
    private var hookEnds: [Int32] = []

    override func tearDown() {
        hookEnds.forEach { Darwin.close($0) }
        hookEnds = []
        super.tearDown()
    }

    /// A connection and the hook's end of it.
    private func connectionPair(peerWatch: HookPeerWatch = .shared) throws -> (HookConnection, hook: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw XCTSkip("socketpair: \(String(cString: strerror(errno)))")
        }
        hookEnds.append(fds[1])
        return (HookConnection(fd: fds[0], queue: queue, peerWatch: peerWatch), fds[1])
    }

    /// Closes the hook's end.
    private func closeHook(_ hook: Int32) {
        Darwin.close(hook)
        hookEnds.removeAll { $0 == hook }
    }

    /// Set once `connection` closes.
    private func closing(_ connection: HookConnection) -> Flag {
        let closed = Flag()
        connection.onClose { closed.set() }
        return closed
    }

    /// Waits until `flag` is set; false after `timeout`.
    private func wait(for flag: Flag, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !flag.isSet {
            guard Date() < deadline else { return false }
            usleep(10_000)
        }
        return true
    }

    /// The safety net's check closes a held connection only once its hook
    /// is gone: a hook that half-closed and waits for its answer stays.
    func testThePeerCheckLeavesAWaitingHookAlone() throws {
        let (connection, hook) = try connectionPair()
        let closed = closing(connection)
        shutdown(hook, SHUT_WR)  // the request is written; the hook waits

        connection.closeIfPeerGone()
        XCTAssertFalse(wait(for: closed, timeout: 0.3), "the check cut off a waiting hook")

        closeHook(hook)
        connection.closeIfPeerGone()
        XCTAssertTrue(wait(for: closed, timeout: 2), "the check missed a hook that is gone")
    }

    /// A watched connection closes the moment its hook goes, and not before.
    func testAWatchedHookIsSeenGoingAtOnce() throws {
        let (connection, hook) = try connectionPair(peerWatch: HookPeerWatch())
        let closed = closing(connection)
        shutdown(hook, SHUT_WR)

        connection.closeWhenPeerLeaves()
        XCTAssertFalse(wait(for: closed, timeout: 0.3), "a waiting hook was cut off")
        closeHook(hook)
        XCTAssertTrue(wait(for: closed, timeout: 0.5), "the hook's going was not seen at once")
    }

    /// With no kqueue to be had (the descriptors ran out), a held connection
    /// still sees its hook go, by asking its socket now and then — and
    /// leaves a waiting hook alone.
    func testAHookIsSeenGoingWithoutAKqueue() throws {
        let noKqueue = HookPeerWatch(makeKqueue: {
            errno = EMFILE
            return -1
        })
        let (connection, hook) = try connectionPair(peerWatch: noKqueue)
        let closed = closing(connection)
        shutdown(hook, SHUT_WR)

        connection.closeWhenPeerLeaves()
        XCTAssertFalse(wait(for: closed, timeout: HookConnection.peerPollInterval * 1.5), "a waiting hook was cut off")
        closeHook(hook)
        XCTAssertTrue(wait(for: closed, timeout: HookConnection.peerPollInterval * 3), "the hook's going went unnoticed")
    }
}

/// The listener's own concerns.
final class HookSocketListenerTests: XCTestCase {
    /// launchd starts the app with 256 descriptors; the island raises that
    /// toward what it wants, never past the hard limit and never lower.
    func testTheDescriptorLimitRisesTowardWhatTheIslandWants() {
        let wanted = HookSocketListener.wantedDescriptorLimit
        XCTAssertEqual(HookSocketListener.raisedDescriptorLimit(soft: 256, hard: .max), wanted)
        XCTAssertEqual(HookSocketListener.raisedDescriptorLimit(soft: 256, hard: 1_024), 1_024)
        XCTAssertNil(HookSocketListener.raisedDescriptorLimit(soft: 10_240, hard: .max))
        XCTAssertNil(HookSocketListener.raisedDescriptorLimit(soft: 256, hard: 256))
    }

    func testRaisingTheDescriptorLimitLiftsLaunchdsDefault() throws {
        var saved = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &saved), 0)
        defer {
            var restored = saved
            setrlimit(RLIMIT_NOFILE, &restored)
        }
        var launchd = saved
        launchd.rlim_cur = 256
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &launchd), 0)

        HookSocketListener.raiseDescriptorLimit()
        var raised = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &raised), 0)
        XCTAssertEqual(raised.rlim_cur, min(saved.rlim_max, HookSocketListener.wantedDescriptorLimit))
    }
}

/// Set once, from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A hook client of the island's socket, writing the way hooks do.
private final class RawHook: @unchecked Sendable {
    /// Set once, from another thread.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        var value: Data? { lock.withLock { stored } }
        func set(_ data: Data) { lock.withLock { stored = data } }
    }

    private let fd: Int32
    private var closed = false

    private init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func connect(to path: String) -> RawHook? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        return RawHook(fd: fd)
    }

    /// Connects, writes `payload`, half-closes and closes: a hook that does
    /// not wait for the island.
    static func sendAndClose(_ payload: String, to path: String) {
        guard let hook = connect(to: path) else { return }
        hook.write(payload)
        hook.close()
    }

    /// Writes `payload` and half-closes, as every hook does once it has written.
    func write(_ payload: String) {
        writeAll(Data(payload.utf8))
        shutdown(fd, SHUT_WR)
    }

    /// Writes `data` (and half-closes) on another thread; then reads the
    /// answer to EOF when `thenRead`.
    func writeInBackground(_ data: Data, thenRead: Bool) -> Box {
        let box = Box()
        DispatchQueue.global().async { [self] in
            writeAll(data)
            shutdown(fd, SHUT_WR)
            if thenRead { box.set(readToEOF()) }
        }
        return box
    }

    /// Reads the answer to EOF on another thread.
    func readAnswerInBackground() -> Box {
        let box = Box()
        DispatchQueue.global().async { [self] in box.set(readToEOF()) }
        return box
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = send(fd, raw.baseAddress! + offset, raw.count - offset, MSG_NOSIGNAL)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return  // the island stopped reading (an oversized request)
                }
            }
        }
    }

    private func readToEOF() -> Data {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                answer.append(contentsOf: buffer[..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return answer
            }
        }
    }
}
