import Darwin
import Foundation
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "HookServer")

/// The island's end of the hook socket: a Unix-domain stream listener that
/// accepts and reads every connection on its own queue, off the main thread.
///
/// A hook that does not wait for an answer may close its end the moment it
/// has written its event: the remote hook does, and so does a plugin whose
/// process quits right after its SessionEnd. The kernel keeps such a
/// connection, with its bytes and its EOF, until it is accepted. NWListener
/// did not: a connection whose peer had closed before NWListener had set it
/// up was dropped without a callback, on whatever queue the listener ran,
/// and its event was lost — a stale card, when that was a Stop.
final class HookSocketListener: @unchecked Sendable {
    let path: String
    private let queue: DispatchQueue
    private let onConnection: @Sendable (HookConnection) -> Void
    // On `queue`, once started.
    private var source: DispatchSourceRead?
    private var paused = false

    /// `onConnection` gets each accepted connection, on `queue`.
    init(path: String, queue: DispatchQueue, onConnection: @escaping @Sendable (HookConnection) -> Void) {
        self.path = path
        self.queue = queue
        self.onConnection = onConnection
    }

    deinit {
        // Dropped without stop(): the socket must not stay open. Nothing else
        // can be running: every handler holds the listener weakly.
        guard let source else { return }
        if paused { source.resume() }
        source.cancel()
    }

    /// Creates the socket file, readable by this user only, and starts
    /// accepting. False, logged, when the socket cannot be created.
    func start() -> Bool {
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            log.error("HookServer: socket path too long: \(self.path, privacy: .public)")
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.error("HookServer: socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // The umask is set before bind() creates the socket file, so the file
        // is never accessible to anyone else, not even briefly.
        let previousUmask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousUmask)
        guard bound == 0, listen(fd, SOMAXCONN) == 0 else {
            log.error("HookServer: cannot listen on \(self.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            if bound == 0 { unlink(path) }
            return false
        }
        // Belt-and-suspenders: owner-only even if the umask did not take.
        chmod(path, 0o700)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        return true
    }

    /// Stops accepting and closes the listener. Connections already accepted
    /// carry on until they are answered.
    func stop() {
        queue.async { [self] in
            guard let source else { return }
            self.source = nil
            if paused {
                paused = false
                source.resume()
            }
            source.cancel()
        }
    }

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client >= 0 {
                onConnection(HookConnection(fd: client, queue: queue))
                continue
            }
            let error = errno
            switch error {
            case EINTR, ECONNABORTED:
                continue
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                // The connection waits in the backlog; try again shortly
                // rather than spin on a listener that stays readable.
                log.error("HookServer: cannot accept: \(String(cString: strerror(error)), privacy: .public)")
                pause()
                return
            default:
                return  // EAGAIN: none left
            }
        }
    }

    private func pause() {
        guard let source, !paused else { return }
        paused = true
        source.suspend()
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.paused, let source = self.source else { return }
            self.paused = false
            source.resume()
        }
    }
}

/// One accepted hook connection. Its state lives on the listener's queue;
/// ``respond(_:)``, ``cancel()``, ``onClose(_:)`` and
/// ``closeWhenPeerLeaves()`` may be called from any thread.
final class HookConnection: @unchecked Sendable {
    /// What the hook sent.
    enum Request {
        /// Everything up to the hook's EOF — or up to a read error, as
        /// NWConnection's receive handed it over.
        case received(Data)
        /// More than the limit; the rest is not read.
        case tooLarge
        /// The connection failed before a single byte.
        case failed
    }

    private let fd: Int32
    private let queue: DispatchQueue
    // On `queue`:
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var peerWatch: DispatchSourceRead?
    /// Sources on `fd` whose cancel handler has not run yet: the descriptor
    /// is closed only once they are gone.
    private var sourcesOnDescriptor = 0
    private var received = Data()
    private var unsent = Data()
    private var finishing = false
    private var closed = false
    private var closeHandlers: [@Sendable () -> Void] = []

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Reads what the hook sends, to its EOF, and hands it to `completion`
    /// on the queue. Called once, on the queue.
    func readRequest(limit: Int, completion: @escaping (Request) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            guard let request = readAvailable(limit: limit) else { return }
            reader?.cancel()
            reader = nil
            completion(request)
        }
        countOnDescriptor(source)
        reader = source
        source.resume()
    }

    /// Writes `answer` — nothing, when it is empty — then closes.
    func respond(_ answer: Data) {
        queue.async { [self] in
            guard !finishing else { return }
            unsent = answer
            writeUnsent()
        }
    }

    /// Closes without an answer.
    func cancel() {
        queue.async { [self] in finish() }
    }

    /// Runs `handler` on the queue once the connection is closed: answered,
    /// cancelled, or its hook gone (``closeWhenPeerLeaves()``).
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if closed {
                handler()
            } else {
                closeHandlers.append(handler)
            }
        }
    }

    /// Closes the connection as soon as the hook at the other end is gone —
    /// killed, or its agent answered without the island.
    ///
    /// A hook half-closes its end once it has written (the bridge's
    /// `shutdown(SHUT_WR)`), so its EOF on the read side says nothing. The
    /// write side ends only when the hook is gone: the write filter, edge
    /// triggered, fires once when it is registered (writable), then not again
    /// until that happens (EV_EOF). Nothing is polled.
    func closeWhenPeerLeaves() {
        queue.async { [self] in
            guard !finishing, peerWatch == nil else { return }
            let watch = kqueue()
            guard watch >= 0 else {
                log.error("HookServer: kqueue() failed: \(String(cString: strerror(errno)), privacy: .public)")
                return
            }
            _ = fcntl(watch, F_SETFD, FD_CLOEXEC)
            var change = kevent(
                ident: UInt(fd),
                filter: Int16(EVFILT_WRITE),
                flags: UInt16(EV_ADD | EV_CLEAR),
                fflags: 0,
                data: 0,
                udata: nil
            )
            guard kevent(watch, &change, 1, nil, 0, nil) == 0 else {
                Darwin.close(watch)
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: watch, queue: queue)
            source.setEventHandler { [self] in
                var event = kevent()
                var now = timespec(tv_sec: 0, tv_nsec: 0)
                while kevent(watch, nil, 0, &event, 1, &now) > 0 {
                    if event.flags & UInt16(EV_EOF) != 0 {
                        finish()
                        return
                    }
                }
            }
            source.setCancelHandler { Darwin.close(watch) }
            peerWatch = source
            source.resume()
        }
    }

    // MARK: - On the queue

    /// What has arrived; the request once it is complete, else nil.
    private func readAvailable(limit: Int) -> Request? {
        withUnsafeTemporaryAllocation(byteCount: 65_536, alignment: 1) { buffer in
            while true {
                let count = read(fd, buffer.baseAddress, buffer.count)
                if count > 0 {
                    received.append(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count)
                    if received.count > limit { return .tooLarge }
                    continue
                }
                if count == 0 { return .received(received) }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    return nil
                default:
                    return received.isEmpty ? .failed : .received(received)
                }
            }
        }
    }

    private func writeUnsent() {
        while !unsent.isEmpty {
            // A hook may be gone before its answer: EPIPE then, not a SIGPIPE,
            // which the app does not ignore. Per write, not SO_NOSIGPIPE: the
            // kernel takes no option on a socket whose peer closed before it
            // was accepted.
            let written = unsent.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
            if written > 0 {
                unsent.removeFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                waitUntilWritable()
                return
            } else {
                break  // EPIPE: the hook is gone, nobody is left to answer.
            }
        }
        finish()
    }

    private func waitUntilWritable() {
        guard writer == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in writeUnsent() }
        countOnDescriptor(source)
        writer = source
        source.resume()
    }

    /// The descriptor stays open until `source` is cancelled and gone.
    private func countOnDescriptor(_ source: DispatchSourceProtocol) {
        sourcesOnDescriptor += 1
        source.setCancelHandler { [self] in
            sourcesOnDescriptor -= 1
            closeIfDone()
        }
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        peerWatch?.cancel()
        peerWatch = nil
        closeIfDone()
    }

    private func closeIfDone() {
        guard finishing, !closed, sourcesOnDescriptor == 0 else { return }
        closed = true
        Darwin.close(fd)
        let handlers = closeHandlers
        closeHandlers = []
        handlers.forEach { $0() }
    }
}
