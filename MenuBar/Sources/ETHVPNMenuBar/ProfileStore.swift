import Foundation

struct VPNProfile: Codable, Identifiable, Equatable {
    var id: String       // unique name, used as Keychain key suffix
    var displayName: String
    var username: String
    var realm: String

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

    private let activeProfileIDKey = "eth-vpn-active-profile-id"

    private(set) var profiles: [VPNProfile] = []

    @ObservationIgnored var activeProfileID: String? {
        get { UserDefaults.standard.string(forKey: activeProfileIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeProfileIDKey) }
    }

    var activeProfile: VPNProfile? {
        guard let id = activeProfileID else { return profiles.first }
        return profiles.first(where: { $0.id == id }) ?? profiles.first
    }

    private init() { load() }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([VPNProfile].self, from: data) else {
            profiles = migratedLegacyProfile().map { [$0] } ?? []
            return
        }
        profiles = decoded
    }

    func save() {
        let data = try? JSONEncoder().encode(profiles)
        try? data?.write(to: storeURL, options: .atomic)
    }

    // MARK: - Mutation

    func upsert(_ profile: VPNProfile, password: String, token: String) {
        _ = KeychainHelper.set(service: profile.passwordService, value: password)
        _ = KeychainHelper.set(service: profile.tokenService,   value: token)
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

    // MARK: - Legacy migration (single-profile flat files → first profile)

    private func migratedLegacyProfile() -> VPNProfile? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/ethz-vpn-connect")
        let usernameURL = dir.appendingPathComponent("ethzvpnusername.txt")
        guard let username = try? String(contentsOf: usernameURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty,
              KeychainHelper.exists(service: "eth-vpn-password"),
              KeychainHelper.exists(service: "eth-vpn-token") else { return nil }

        let realmURL = dir.appendingPathComponent("ethzvpnrealm.txt")
        let realm = (try? String(contentsOf: realmURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? "student-net"

        // Migrate Keychain entries to new keys
        let profile = VPNProfile(id: "default", displayName: "Default", username: username, realm: realm)
        if let pw  = KeychainHelper.get(service: "eth-vpn-password") { _ = KeychainHelper.set(service: profile.passwordService, value: pw) }
        if let tok = KeychainHelper.get(service: "eth-vpn-token")    { _ = KeychainHelper.set(service: profile.tokenService,    value: tok) }
        return profile
    }
}
