import Foundation

enum SecretsHelper {
    private static let secretsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/ethz-vpn-connect")

    static func areComplete() -> Bool {
        guard KeychainHelper.exists(service: "eth-vpn-password"),
              KeychainHelper.exists(service: "eth-vpn-token") else { return false }
        let usernameURL = secretsDir.appendingPathComponent("ethzvpnusername.txt")
        guard let username = try? String(contentsOf: usernameURL, encoding: .utf8),
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }

    static func writeFiles(username: String, realm: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        try username.write(to: secretsDir.appendingPathComponent("ethzvpnusername.txt"), atomically: true, encoding: .utf8)
        try realm.write(to: secretsDir.appendingPathComponent("ethzvpnrealm.txt"), atomically: true, encoding: .utf8)
    }

    static func readUsername() -> String? {
        let url = secretsDir.appendingPathComponent("ethzvpnusername.txt")
        return try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readRealm() -> String? {
        let url = secretsDir.appendingPathComponent("ethzvpnrealm.txt")
        return try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
