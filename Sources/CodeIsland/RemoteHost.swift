import Foundation

struct RemoteHost: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var host: String
    var user: String
    var port: Int?
    var identityFile: String
    var autoConnect: Bool
    /// Optional SSH_AUTH_SOCK path — lets password-manager-backed SSH agents
    /// (1Password, Bitwarden, etc.) sign the handshake when the GUI launch
    /// didn't inherit the env var from a shell. See issue #81.
    var authSocket: String
    /// Comma-separated cwd substrings. When non-empty, only remote sessions whose
    /// working directory contains one of these substrings are shown — lets users on
    /// a shared remote account scope the panel to their own project folders (#240).
    /// Empty = show every session from this host (previous behavior).
    var cwdFilter: String
    /// The host's agents run as users other than the SSH user — in a
    /// container, under sudo. Off, the island's socket on the host is in a
    /// folder only the SSH user can enter (0700), and its hooks use only a
    /// socket of their own user's. On, every user there may pass through
    /// that folder to the socket (0711) and connect to it (0666), and the
    /// hooks are told the SSH user owns it (`CODEISLAND_SOCKET_OWNER_UID`),
    /// so a hook run as another user uses that socket — and still no other.
    var agentsRunAsOtherUsers: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        user: String = "",
        port: Int? = nil,
        identityFile: String = "",
        autoConnect: Bool = false,
        authSocket: String = "",
        cwdFilter: String = "",
        agentsRunAsOtherUsers: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.autoConnect = autoConnect
        self.authSocket = authSocket
        self.cwdFilter = cwdFilter
        self.agentsRunAsOtherUsers = agentsRunAsOtherUsers
    }

    // Backward compatibility: hosts persisted before authSocket/cwdFilter existed decode
    // with "", and before agentsRunAsOtherUsers with false (the owner-only socket).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.host = try c.decode(String.self, forKey: .host)
        self.user = try c.decode(String.self, forKey: .user)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
        self.identityFile = try c.decode(String.self, forKey: .identityFile)
        self.autoConnect = try c.decode(Bool.self, forKey: .autoConnect)
        self.authSocket = try c.decodeIfPresent(String.self, forKey: .authSocket) ?? ""
        self.cwdFilter = try c.decodeIfPresent(String.self, forKey: .cwdFilter) ?? ""
        self.agentsRunAsOtherUsers = try c.decodeIfPresent(Bool.self, forKey: .agentsRunAsOtherUsers) ?? false
    }

    var sshTarget: String {
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUser.isEmpty {
            return host.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(trimmedUser)@\(host.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// The shared socket path hooks used before #193. Nothing is forwarded
    /// there any more: the live path, in a folder of the SSH user's own, is
    /// made and checked at connect time (`RemoteInstaller.prepareRemoteSocketPath`),
    /// and a host whose folder fails that check does not connect. Only the
    /// install scripts' default when no path is given.
    var remoteSocketPath: String { "/tmp/codeisland.sock" }

    var displayAddress: String {
        if let port {
            return "\(sshTarget):\(port)"
        }
        return sshTarget
    }
}
