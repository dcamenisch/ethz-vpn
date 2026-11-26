import Foundation
import LocalAuthentication

struct VPNProfile: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var username: String
    var realm: String
    var server = AppConstants.defaultServer

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

    /// Seals new secrets; `nil` keeps the saved ones, or copies them from `source` when duplicating.
    func upsert(_ profile: VPNProfile, password: String?, token: String?, copyingFrom source: VPNProfile? = nil) throws {
        try storeSecret(password, service: profile.passwordService, fallback: source?.passwordService)
        try storeSecret(token, service: profile.tokenService, fallback: source?.tokenService)
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    private func storeSecret(_ secret: String?, service: String, fallback: String?) throws {
        let value = try secret.map(SecretVault.seal) ?? fallback.flatMap(KeychainHelper.get)
        if let value, !KeychainHelper.set(service: service, value: value) { throw KeychainError() }
    }

    func delete(_ profile: VPNProfile) {
        KeychainHelper.delete(service: profile.passwordService)
        KeychainHelper.delete(service: profile.tokenService)
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = profiles.first?.id }
        save()
    }

    // MARK: - Credential accessors

    /// Needs a context authenticated with `SecretVault.authenticate`.
    func secrets(for profile: VPNProfile, context: LAContext) throws -> (password: String, token: String)? {
        func read(_ service: String) throws -> String? {
            try KeychainHelper.get(service: service).map { try SecretVault.open($0, context: context) }
        }
        guard let password = try read(profile.passwordService), let token = try read(profile.tokenService) else { return nil }
        return (password, token)
    }

    func isComplete(profile: VPNProfile) -> Bool {
        KeychainHelper.exists(service: profile.passwordService) &&
        KeychainHelper.exists(service: profile.tokenService) &&
        !profile.username.isEmpty
    }

    var hasAnyCompleteProfile: Bool { profiles.contains(where: { isComplete(profile: $0) }) }
}
