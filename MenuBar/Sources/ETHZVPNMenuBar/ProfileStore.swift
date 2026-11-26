import Foundation

struct VPNProfile: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var username: String
    var realm: String
    var server: String

    /// Profiles saved before `server` existed default to sslvpn.ethz.ch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        username    = try c.decode(String.self, forKey: .username)
        realm       = try c.decode(String.self, forKey: .realm)
        server      = try c.decodeIfPresent(String.self, forKey: .server) ?? AppConstants.defaultServer
    }

    init(id: String, displayName: String, username: String, realm: String, server: String = AppConstants.defaultServer) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.realm = realm
        self.server = server
    }

    var passwordService: String { "eth-vpn-password-\(id)" }
    var tokenService:   String { "eth-vpn-token-\(id)" }
}

@Observable final class ProfileStore {
    static let shared = ProfileStore()

    private let storeURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/ethz-vpn-connect")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }()

    private static let activeProfileIDKey = "eth-vpn-active-profile-id"

    private(set) var profiles: [VPNProfile] = []

    var activeProfileID = UserDefaults.standard.string(forKey: activeProfileIDKey) {
        didSet { UserDefaults.standard.set(activeProfileID, forKey: Self.activeProfileIDKey) }
    }

    var activeProfile: VPNProfile? {
        guard let id = activeProfileID else { return profiles.first }
        return profiles.first(where: { $0.id == id }) ?? profiles.first
    }

    private init() { load() }

    // MARK: - Persistence

    private func load() {
        profiles = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONDecoder().decode([VPNProfile].self, from: $0) } ?? []
    }

    func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    static func makeID(from name: String) -> String {
        let id = name.lowercased().replacingOccurrences(of: " ", with: "-")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return id.isEmpty ? UUID().uuidString.lowercased() : id
    }

    // MARK: - Mutation

    struct KeychainError: LocalizedError {
        var errorDescription: String? { "Could not save the credentials to the Keychain." }
    }

    /// `nil` secrets keep the values already in the Keychain.
    func upsert(_ profile: VPNProfile, password: String?, token: String?) throws {
        if let password, !KeychainHelper.set(service: profile.passwordService, value: password) { throw KeychainError() }
        if let token, !KeychainHelper.set(service: profile.tokenService, value: token) { throw KeychainError() }
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    func delete(_ profile: VPNProfile) {
        KeychainHelper.delete(service: profile.passwordService)
        KeychainHelper.delete(service: profile.tokenService)
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = profiles.first?.id }
        save()
    }

    // MARK: - Credential accessors

    func password(for profile: VPNProfile) -> String? {
        KeychainHelper.get(service: profile.passwordService)
    }

    func token(for profile: VPNProfile) -> String? {
        KeychainHelper.get(service: profile.tokenService)
    }

    func isComplete(profile: VPNProfile) -> Bool {
        KeychainHelper.exists(service: profile.passwordService) &&
        KeychainHelper.exists(service: profile.tokenService) &&
        !profile.username.isEmpty
    }

    var hasAnyCompleteProfile: Bool { profiles.contains(where: { isComplete(profile: $0) }) }
}
