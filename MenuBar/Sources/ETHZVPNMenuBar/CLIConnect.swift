import Foundation
import LocalAuthentication

/// `ETHZVPNMenuBar --connect [profile]`: used by the ethz-vpn CLI, since only
/// this binary can unseal the secrets after Touch ID.
enum CLIConnect {
    static func run(profileName: String?) -> Int32 {
        let store = ProfileStore.shared
        let profile = profileName.map { name in
            store.profiles.first { $0.id.caseInsensitiveCompare(name) == .orderedSame
                || $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
        } ?? store.activeProfile
        guard let profile else { return fail("No profile named \"\(profileName ?? "")\".") }
        guard PrivilegedHelper.isInstalled() else {
            return fail("The VPN helper is not installed. Open ETHZ VPN and save a profile first.")
        }

        let context = LAContext()
        var authError: Error?
        let done = DispatchSemaphore(value: 0)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "connect to the ETH VPN as \(profile.username)") { ok, error in
            if !ok { authError = error ?? LAError(.authenticationFailed) }
            done.signal()
        }
        done.wait()
        if let authError { return fail(authError.localizedDescription) }

        let secrets: (password: String, token: String)
        do {
            guard let s = try store.secrets(for: profile, context: context) else { return fail("No secrets saved for \(profile.displayName).") }
            secrets = s
        } catch {
            return fail(error.localizedDescription)
        }

        store.activeProfileID = profile.id
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", PrivilegedHelper.helperPath, "connect-bg", profile.username, profile.realm, profile.server]
        let stdin = Pipe()
        process.standardInput = stdin
        do { try process.run() } catch { return fail(error.localizedDescription) }
        stdin.fileHandleForWriting.write(Data("\(secrets.password)\n\(secrets.token)\n".utf8))
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        return 1
    }
}
