import CryptoKit
import Darwin
import Foundation
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "RemoteHookSockets")

/// Why a remote host has no socket of its own, and so does not connect.
enum RemoteHookSocketFailure: Error, Equatable {
    /// The folder the host sockets go in is not one only this user can use:
    /// another user's, a symlink, a file.
    case folderNotPrivate(path: String)
    /// The island cannot listen at `path`.
    case cannotListen(path: String)

    /// What Settings → Remote shows for the host.
    func message(_ l10n: L10n) -> String {
        switch self {
        case .folderNotPrivate(let path):
            return String(format: l10n["remote_socket_folder_unsafe"], path)
        case .cannotListen(let path):
            return String(format: l10n["remote_socket_unavailable"], path)
        }
    }
}

/// Where each remote host's hooks arrive on this Mac: `RemoteHookSockets`,
/// or a stand-in in tests.
@MainActor
protocol RemoteHookSocketProviding: AnyObject {
    /// Binds a socket for `host` — a fresh one, closing any it had — and
    /// returns its path: the only place the host's forward may end.
    func open(for host: RemoteHost) -> Result<String, RemoteHookSocketFailure>
    /// The host was renamed: its requests carry the new name.
    func rename(hostId: String, to name: String)
    /// Closes the host's socket and removes its file.
    func close(hostId: String)
    /// Closes every host's socket.
    func closeAll()
    /// Removes the sockets an earlier run left behind.
    func removeStale()
}

/// A socket of its own for each connected remote host, bound by the island
/// when the host connects, at the Mac's end of the host's SSH forward. Every
/// request on it is that host's (``HookOrigin``) — whatever the payload
/// says — and a forward never ends at a path the island did not just bind:
/// not at the main socket, which another user may have taken first.
///
/// The sockets live in a folder only this user can enter, beside the main
/// socket: `/tmp/codeisland-<uid>-hosts/` for `/tmp/codeisland-<uid>.sock`.
/// An island on a socket of its own (`CODEISLAND_SOCKET_PATH`) keeps its
/// hosts apart too. Each is named after a digest of its host's id
/// (`h-<16 hex>.sock`): the same on every connect, short enough for
/// `sun_path` whatever the id, and nothing an id can steer out of the
/// folder. A socket goes when its host disconnects or is removed, or the
/// island quits; one a crash left behind goes at the next launch
/// (``removeStale()``).
@MainActor
final class RemoteHookSockets: RemoteHookSocketProviding {
    /// The folder the sockets are in.
    let directory: String
    private let makeServer: (_ path: String, _ origin: HookOrigin) -> HookServer
    /// By host id.
    private var servers: [String: HookServer] = [:]

    /// `makeServer` makes the server for a host's socket; it is started
    /// here.
    init(directory: String, makeServer: @escaping (_ path: String, _ origin: HookOrigin) -> HookServer) {
        self.directory = directory
        self.makeServer = makeServer
    }

    /// The island's: each host's server hands what it receives to `appState`.
    convenience init(
        appState: AppState,
        directory: String = RemoteHookSockets.directory(forMainSocket: HookServer.socketPath)
    ) {
        self.init(directory: directory) { path, origin in
            HookServer(appState: appState, socketPath: path, origin: origin)
        }
    }

    /// The folder for host sockets beside the main socket at `path`: its
    /// name without `.sock`, plus `-hosts`.
    nonisolated static func directory(forMainSocket path: String) -> String {
        let base = path.hasSuffix(".sock") ? String(path.dropLast(".sock".count)) : path
        return base + "-hosts"
    }

    /// The socket name for the host `id`: `h-` and the first 8 bytes of the
    /// id's SHA-256, in hex.
    nonisolated static func socketName(forHostId id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return "h-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".sock"
    }

    /// Whether `name` is one ``socketName(forHostId:)`` gives.
    nonisolated static func isSocketName(_ name: String) -> Bool {
        guard name.hasPrefix("h-"), name.hasSuffix(".sock") else { return false }
        let digest = name.dropFirst(2).dropLast(".sock".count)
        return digest.count == 16 && digest.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Where the host `id`'s socket is.
    func path(forHostId id: String) -> String {
        directory + "/" + Self.socketName(forHostId: id)
    }

    /// Whether the host has a socket open, and where.
    func openPath(forHostId id: String) -> String? {
        servers[id]?.socketPath
    }

    func open(for host: RemoteHost) -> Result<String, RemoteHookSocketFailure> {
        // Bound afresh on every connect: a socket file removed from under a
        // live listener would otherwise leave the host unreachable for good.
        close(hostId: host.id)
        guard Self.preparePrivateFolder(directory) else {
            return .failure(.folderNotPrivate(path: directory))
        }
        let path = path(forHostId: host.id)
        // Two ids with one digest would share a socket, and each other's
        // requests: neither gets this one.
        guard !servers.values.contains(where: { $0.socketPath == path }) else {
            log.error("Two remote hosts' sockets would share \(path, privacy: .public)")
            return .failure(.cannotListen(path: path))
        }
        let server = makeServer(path, .remoteHost(id: host.id, name: host.name))
        guard server.start() else {
            return .failure(.cannotListen(path: path))
        }
        servers[host.id] = server
        log.info("Listening for remote host \(host.id, privacy: .public) at \(path, privacy: .public)")
        return .success(path)
    }

    func rename(hostId: String, to name: String) {
        servers[hostId]?.renameHost(to: name)
    }

    func close(hostId: String) {
        guard let server = servers.removeValue(forKey: hostId) else { return }
        server.stop()
    }

    func closeAll() {
        for hostId in Array(servers.keys) {
            close(hostId: hostId)
        }
    }

    /// Removes the host sockets an earlier run left behind (a crash, or a
    /// quit that never closed them). Only in the folder, and only while it is
    /// still one only this user can use; only sockets of this user's, under
    /// a name a host socket takes, and never one of this run's.
    func removeStale() {
        removeStale(uid: getuid())
    }

    /// ``removeStale()`` as the user `uid`: for tests, which cannot make a
    /// file another user owns.
    func removeStale(uid: uid_t) {
        guard let folder = Self.openPrivateFolder(directory, creating: false, uid: uid) else { return }
        defer { Darwin.close(folder) }
        let open = Set(servers.values.map { ($0.socketPath as NSString).lastPathComponent })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names where Self.isSocketName(name) && !open.contains(name) {
            // Relative to the folder checked above, never followed.
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFSOCK,
                  info.st_uid == uid else { continue }
            if unlinkat(folder, name, 0) == 0 {
                log.info("Removed a stale remote host socket: \(name, privacy: .public)")
            }
        }
    }

    // MARK: - The folder

    /// Makes `path` a folder only this user can use, or finds it one: it is
    /// created 0700, or it is already a folder — not a symlink to one — this
    /// user owns, whose mode is narrowed to 0700 if it let anyone else in.
    /// False, logged, for anything else: whatever another user put there, a
    /// symlink, a file. Nothing is created inside it until it passes. `uid`
    /// is for tests, which cannot make a folder another user owns.
    nonisolated static func preparePrivateFolder(_ path: String, uid: uid_t = getuid()) -> Bool {
        guard let folder = openPrivateFolder(path, creating: true, uid: uid) else { return false }
        Darwin.close(folder)
        return true
    }

    /// The folder at `path`, opened, once it is a private folder of `uid`'s
    /// (``preparePrivateFolder(_:uid:)``); nil when it is not, or is not
    /// there and `creating` is false.
    nonisolated private static func openPrivateFolder(_ path: String, creating: Bool, uid: uid_t) -> Int32? {
        if creating, mkdir(path, 0o700) != 0, errno != EEXIST {
            log.error("Cannot create \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        // O_NOFOLLOW: a symlink at `path`, whoever made it, is refused, not
        // followed; the checks and the chmod below act on what was opened.
        let folder = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            if creating || errno != ENOENT {
                log.error("\(path, privacy: .public) is not a folder CodeIsland can use for remote host sockets: \(String(cString: strerror(errno)), privacy: .public)")
            }
            return nil
        }
        var info = stat()
        guard fstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            log.error("Cannot read \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            Darwin.close(folder)
            return nil
        }
        guard info.st_uid == uid else {
            log.error("\(path, privacy: .public) belongs to uid \(info.st_uid), not this user: no remote host socket goes there")
            Darwin.close(folder)
            return nil
        }
        if info.st_mode & 0o077 != 0, fchmod(folder, 0o700) != 0 {
            log.error("Cannot make \(path, privacy: .public) private: \(String(cString: strerror(errno)), privacy: .public)")
            Darwin.close(folder)
            return nil
        }
        return folder
    }
}
