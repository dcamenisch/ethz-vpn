import Foundation

enum SudoersHelper {
    static func isInstalled(openconnectPath: String) -> Bool {
        let filePath = "/etc/sudoers.d/ethz-vpn"
        guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return false }
        let realPath = URL(fileURLWithPath: openconnectPath).resolvingSymlinksInPath().path
        let escapedPath = realPath.replacingOccurrences(of: " ", with: #"\ "#)
        guard contents.contains(escapedPath) else { return false }
        // Also verify root ownership — macOS rejects sudoers files not owned by root
        let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
        let ownerID = attrs?[.ownerAccountID] as? Int
        return ownerID == 0
    }

    static func installIfNeeded(openconnectPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isInstalled(openconnectPath: openconnectPath) else { completion(.success(())); return }

        let user = NSUserName()
        let realPath = URL(fileURLWithPath: openconnectPath).resolvingSymlinksInPath().path
        let escapedPath = realPath.replacingOccurrences(of: " ", with: #"\ "#)
        let rule = "\(user) ALL=(ALL) NOPASSWD: \(escapedPath)\n\(user) ALL=(ALL) NOPASSWD: /usr/bin/pkill\n"

        // Write rule to a temp file from Swift (avoids shell quoting issues with special chars)
        let tmpPath = "/tmp/ethz-vpn-sudoers.tmp"
        let ruleData = rule.data(using: .utf8)!
        guard FileManager.default.createFile(atPath: tmpPath, contents: ruleData,
                                             attributes: [.posixPermissions: 0o600]) else {
            completion(.failure(NSError(domain: "SudoersHelper", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create temp sudoers file."])))
            return
        }

        // Use AppleScript only for the privileged part: validate + move + chown + chmod
        // chown root:wheel is required — macOS rejects sudoers files not owned by root
        let script = """
        do shell script "/usr/sbin/visudo -cf \(tmpPath) && mv \(tmpPath) /etc/sudoers.d/ethz-vpn && chown root:wheel /etc/sudoers.d/ethz-vpn && chmod 440 /etc/sudoers.d/ethz-vpn" with administrator privileges
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        process.terminationHandler = { proc in
            if proc.terminationStatus == 0 {
                completion(.success(()))
            } else {
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? "Unknown error"
                completion(.failure(NSError(
                    domain: "SudoersHelper",
                    code: Int(proc.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errText.trimmingCharacters(in: .whitespacesAndNewlines)]
                )))
            }
        }

        do {
            try process.run()
        } catch {
            completion(.failure(error))
        }
    }
}
