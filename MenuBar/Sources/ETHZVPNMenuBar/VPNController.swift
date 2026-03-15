import Foundation
import AppKit
import UserNotifications

enum VPNState {
    case connected(ip: String)
    case connecting
    case disconnected
    case disconnecting

    var isConnected: Bool    { if case .connected    = self { return true }; return false }
    var isTransitioning: Bool { if case .connecting  = self { return true }
                                if case .disconnecting = self { return true }; return false }
}

// MARK: - App-wide constants
enum AppConstants {
    static let appName        = "ETH VPN"
    static let defaultRealm   = "student-net"
}

final class VPNController {
    static let shared = VPNController()

    private(set) var state: VPNState = .disconnected
    private var statusTimer: Timer?
    private var openconnectProcess: Process?
    var onStateChange: ((VPNState) -> Void)?

    private init() {
        // Synchronous initial check so state is correct before first UI render
        if isOpenconnectRunning() {
            state = .connected(ip: vpnIP() ?? "")
        }
        startPolling()
    }

    // MARK: - Public API

    func connect(profile: VPNProfile? = nil) {
        // Gate on our state machine, not pgrep — avoids a race where the
        // sudo/openconnect process is still dying but pgrep still finds it.
        guard case .disconnected = state else { return }
        let store = ProfileStore.shared
        guard let target = profile ?? store.activeProfile else {
            NotificationCenter.default.post(name: .vpnSecretsNotFound, object: nil)
            return
        }
        guard
            let password = store.password(for: target),
            let token    = store.token(for: target)
        else {
            NotificationCenter.default.post(name: .vpnSecretsNotFound, object: nil)
            return
        }
        let username = target.username
        let realm    = target.realm
        let subnet   = target.subnet
         guard !username.isEmpty else {
            NotificationCenter.default.post(name: .vpnSecretsNotFound, object: nil)
            return
        }
        // Remember this as the active profile
        // Construct the target URL: sslvpn.ethz.ch[/subnet]
        let baseUrl = "sslvpn.ethz.ch"
        let fullUrl = subnet.isEmpty ? baseUrl : "\(baseUrl)/\(subnet)"

        store.activeProfileID = target.id
        setState(.connecting)

        let openconnectPath = bundledOpenconnectPath()

        // Write token config to a temp file (mode 0600) so the secret never
        // appears in the process argument list (visible via `ps aux`).
        let configPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ethz-vpn-\(UUID().uuidString).conf").path
        let configContent = "token-mode=totp\ntoken-secret=sha1:base32:\(token)\n"
        let configData = configContent.data(using: .utf8)!
        FileManager.default.createFile(atPath: configPath, contents: configData,
                                       attributes: [.posixPermissions: 0o600])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // Run openconnect WITHOUT -b: we keep the process alive in the background
        // via Swift's Process (which is already async). The -b flag causes openconnect
        // to fork-and-exit, which tears down stdin before the child can read the password.
        process.arguments = [
            openconnectPath,
            "-u", "\(username)@\(realm).ethz.ch",
            "-g", realm,
            "--useragent=AnyConnect",
            "--passwd-on-stdin",
            "--config", configPath,
            "--no-external-auth",
            fullUrl
        ]

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            // Config file is no longer needed once the process exits
            try? FileManager.default.removeItem(atPath: configPath)
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                // Only update state if this is still the active process —
                // prevents a stale termination handler from clobbering a
                // reconnect that already launched a new process.
                guard self.openconnectProcess === proc else { return }
                self.openconnectProcess = nil
                self.setState(.disconnected)
                if proc.terminationStatus != 0 {
                    let detail = errText
                        .components(separatedBy: .newlines)
                        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                        ?? "status \(proc.terminationStatus)"
                    self.postNotification(body: "Connection failed: \(detail)")
                }
            }
        }

        do {
            try process.run()
            openconnectProcess = process
            // Write password then close stdin so openconnect knows input is done
            let input = (password + "\n").data(using: .utf8)!
            stdinPipe.fileHandleForWriting.write(input)
            stdinPipe.fileHandleForWriting.closeFile()
        } catch {
            try? FileManager.default.removeItem(atPath: configPath)
            setState(.disconnected)
            postNotification(body: "Failed to launch openconnect: \(error.localizedDescription)")
        }
    }

    /// Connects if disconnected, disconnects if connected, no-ops while transitioning.
    func toggleConnection() {
        switch state {
        case .disconnected: connect()
        case .connected:    disconnect()
        default: break
        }
    }

    func disconnect() {
        guard isOpenconnectRunning() else { return }
        setState(.disconnecting)
        openconnectProcess = nil  // disown so any pending terminationHandler is a no-op
        shell("/usr/bin/sudo", ["/usr/bin/pkill", "-SIGINT", "-x", "openconnect"])
        // Force-kill fallback: if still running after 6s, send SIGKILL
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard case .disconnecting = self?.state else { return }
            _ = self?.shell("/usr/bin/sudo", ["/usr/bin/pkill", "-SIGKILL", "-x", "openconnect"])
            self?.setState(.disconnected)
        }
    }

    // MARK: - Status polling

    func startPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
        pollStatus()
    }

    private func pollStatus() {
        let running = isOpenconnectRunning()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.state {
            case .connecting:
                if running {
                    let ip = self.vpnIP() ?? ""
                    self.setState(.connected(ip: ip))
                }
            case .disconnecting:
                if !running {
                    self.setState(.disconnected)
                }
            case .connected:
                if !running {
                    self.setState(.disconnected)
                    self.postNotification(body: "VPN disconnected unexpectedly.")
                } else {
                    // Refresh IP
                    let ip = self.vpnIP() ?? ""
                    self.setState(.connected(ip: ip))
                }
            case .disconnected:
                if running {
                    let ip = self.vpnIP() ?? ""
                    self.setState(.connected(ip: ip))
                }
            }
        }
    }

    // MARK: - Helpers

    private func setState(_ newState: VPNState) {
        state = newState
        onStateChange?(newState)
    }

    func isOpenconnectRunning() -> Bool {
        let result = shell("/usr/bin/pgrep", ["-x", "openconnect"])
        return result == 0
    }

    func vpnIP() -> String? {
        // Enumerate utun interfaces for an inet address
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cursor = ifaddr
        while let ifa = cursor {
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("utun"), let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == AF_INET {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    if !ip.isEmpty { return ip }
                }
            }
            cursor = ifa.pointee.ifa_next
        }
        return nil
    }

    @discardableResult
    private func shell(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func bundledOpenconnectPath() -> String {
        // 1. Canonical bundle location: Contents/Resources/openconnect
        //    This must match the path written into the sudoers rule.
        //    We check this before Bundle.main.path(forResource:) because SPM may
        //    nest a second copy under Resources/Resources/ which would mismatch.
        if let bundleResources = Bundle.main.resourceURL {
            let canonical = bundleResources.appendingPathComponent("openconnect").path
            let real = URL(fileURLWithPath: canonical).resolvingSymlinksInPath().path
            if FileManager.default.isExecutableFile(atPath: real) { return real }
        }
        // 2. Homebrew fallbacks (developer machine)
        for path in ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                return FileManager.default.isExecutableFile(atPath: real) ? real : path
            }
        }
        return "openconnect"
    }

    func resolvedOpenconnectPath() -> String { bundledOpenconnectPath() }

    func postNotification(body: String) {
        let content = UNMutableNotificationContent()
        content.title = AppConstants.appName
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - C socket imports
import Darwin

extension Notification.Name {
    static let vpnSecretsNotFound = Notification.Name("com.dcamenisch.ethz-vpn.secretsNotFound")
}
