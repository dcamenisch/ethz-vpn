import Foundation

/// Installs the root helper. The sudoers rule allows only the helper, which
/// lives in a root-owned directory with its own copies of openconnect and vpnc-script.
enum PrivilegedHelper {
    static let expectedVersion = "3"
    static let installDir  = "/Library/PrivilegedHelperTools/ethz-vpn"
    static let helperPath  = installDir + "/ethz-vpn-helper"
    static let sudoersPath = "/etc/sudoers.d/ethz-vpn"

    enum InstallError: LocalizedError {
        case missingComponent(String)
        case invalidUserName
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingComponent(let what):
                return "Could not find \(what). Install it with Homebrew (brew install openconnect) or use the release build."
            case .invalidUserName:
                return "Your macOS account name contains characters that cannot be used in a sudoers rule."
            case .cancelled:
                return "Installation was cancelled."
            case .failed(let detail):
                return "Installing the VPN helper failed: \(detail)"
            }
        }
    }

    // MARK: - Status

    /// `sudo -n helper version` succeeding proves the rule, ownership and files are all in place.
    static func isInstalled() -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: helperPath)
        guard (attrs?[.ownerAccountID] as? Int) == 0 else { return false }
        let result = run("/usr/bin/sudo", ["-n", helperPath, "version"])
        return result.status == 0
            && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == expectedVersion
    }

    // MARK: - Install

    struct Sources {
        let helper: String
        let openconnect: String
        let libDir: String?
        let vpncScript: String
    }

    static func locateSources() throws -> Sources {
        guard let helper = bundledResource("ethz-vpn-helper") else {
            throw InstallError.missingComponent("ethz-vpn-helper in the app bundle")
        }

        var openconnect: String?
        var libDir: String?
        if let bundled = bundledResource("openconnect") {
            openconnect = bundled
            let lib = (bundled as NSString).deletingLastPathComponent + "/lib"
            if FileManager.default.fileExists(atPath: lib) { libDir = lib }
        } else {
            for path in ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect"]
            where FileManager.default.isExecutableFile(atPath: path) {
                openconnect = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                break
            }
        }
        guard let openconnect else { throw InstallError.missingComponent("openconnect") }

        let vpnc = bundledResource("vpnc-script")
            ?? ["/opt/homebrew/etc/vpnc/vpnc-script", "/usr/local/etc/vpnc/vpnc-script",
                "/opt/homebrew/etc/vpnc-script", "/usr/local/etc/vpnc-script"]
                .first { FileManager.default.fileExists(atPath: $0) }
        guard let vpnc else { throw InstallError.missingComponent("vpnc-script") }

        return Sources(helper: helper, openconnect: openconnect, libDir: libDir, vpncScript: vpnc)
    }

    /// Prompts for an admin password once. `completion` runs on the main queue.
    static func install(completion: @escaping (Result<Void, Error>) -> Void) {
        let done: (Result<Void, Error>) -> Void = { r in DispatchQueue.main.async { completion(r) } }

        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
            done(.failure(InstallError.invalidUserName)); return
        }
        let src: Sources
        do { src = try locateSources() } catch { done(.failure(error)); return }

        // Base64 avoids AppleScript quoting; root-created mktemp paths avoid /tmp swap races.
        let script = """
        set -eu
        umask 022
        DEST=\(sq(installDir))
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        STAGE=$(mktemp -d /Library/PrivilegedHelperTools/.ethz-vpn.XXXXXX)
        trap 'rm -rf "$STAGE"' EXIT
        mkdir -p "$STAGE/Resources"
        cp \(sq(src.helper)) "$STAGE/ethz-vpn-helper"
        cp \(sq(src.openconnect)) "$STAGE/Resources/openconnect"
        cp \(sq(src.vpncScript)) "$STAGE/Resources/vpnc-script"
        \(src.libDir.map { "cp -R \(sq($0)) \"$STAGE/Resources/lib\"" } ?? ":")
        xattr -cr "$STAGE" 2>/dev/null || true
        chown -R root:wheel "$STAGE"
        chmod -R go-w "$STAGE"
        chmod 755 "$STAGE" "$STAGE/Resources" "$STAGE/ethz-vpn-helper" "$STAGE/Resources/openconnect" "$STAGE/Resources/vpnc-script"
        rm -rf "$DEST"
        mv "$STAGE" "$DEST"
        RULE=$(mktemp /private/var/run/ethz-vpn-sudoers.XXXXXX)
        printf '%s ALL=(root) NOPASSWD: %s\\n' \(sq(user)) \(sq(helperPath)) > "$RULE"
        /usr/sbin/visudo -cqf "$RULE"
        install -o root -g wheel -m 440 "$RULE" \(sq(sudoersPath))
        rm -f "$RULE"
        """
        let b64 = Data(script.utf8).base64EncodedString()
        let appleScript = "do shell script \"echo \(b64) | /usr/bin/base64 -D | /bin/sh\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = run("/usr/bin/osascript", ["-e", appleScript])
            if result.status == 0 {
                done(isInstalled() ? .success(()) : .failure(InstallError.failed("the helper was copied but sudo still asks for a password.")))
            } else if result.output.contains("-128") {
                done(.failure(InstallError.cancelled))
            } else {
                done(.failure(InstallError.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))))
            }
        }
    }

    // MARK: - Helpers

    /// SPM may nest the resources folder as Contents/Resources/Resources.
    static func bundledResource(_ name: String) -> String? {
        guard let base = Bundle.main.resourceURL else { return nil }
        for candidate in [base.appendingPathComponent(name),
                          base.appendingPathComponent("Resources").appendingPathComponent(name)] {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    private static func sq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
