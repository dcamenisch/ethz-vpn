import Foundation
import LocalAuthentication

struct VPNProfile: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var username: String
    var realm: String
    var server = AppConstants.defaultServer
    /// Ciphertext from `SecretVault.seal`, only decryptable on this Mac after Touch ID.
    var sealedPassword: String?
    var sealedToken: String?

    var isComplete: Bool { !username.isEmpty && sealedPassword != nil && sealedToken != nil }
}

@Observable final class ProfileStore {
    static let shared = ProfileStore()

    static let directory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/ethz-vpn-connect")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()
    private let storeURL = directory.appendingPathComponent("profiles.json")

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

    func upsert(_ profile: VPNProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    func delete(_ profile: VPNProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = profiles.first?.id }
        save()
    }

    /// Needs a context authenticated with `SecretVault.authenticate`.
    func secrets(for profile: VPNProfile, context: LAContext) throws -> (password: String, token: String)? {
        guard let password = profile.sealedPassword, let token = profile.sealedToken else { return nil }
        return (try SecretVault.open(password, context: context), try SecretVault.open(token, context: context))
    }

    var hasAnyCompleteProfile: Bool { profiles.contains(where: \.isComplete) }
}
