import AppKit
import Darwin
import Foundation
import Observation
import os
import UserNotifications

enum VPNState {
    case connected(ip: String)
    case connecting
    case disconnected
    case disconnecting

    var isConnected: Bool { if case .connected = self { return true }; return false }
    var isTransitioning: Bool {
        switch self {
        case .connecting, .disconnecting: return true
        default: return false
        }
    }
}

enum AppConstants {
    static let appName       = "ETHZ VPN"
    static let defaultRealm  = "student-net"
    static let defaultServer = "sslvpn.ethz.ch"
}

@Observable final class VPNController {
    static let shared = VPNController()

    private(set) var state: VPNState = .disconnected
    private(set) var lastError: String?
    private(set) var log: [String] = []
    private(set) var connectedSince: Date?
    var onStateChange: ((VPNState) -> Void)?
    var onError: ((String) -> Void)?

    private var statusTimer: Timer?
    private var process: Process?
    private var pendingOutput = Data()
    private static let logger = Logger(subsystem: "com.dcamenisch.ethz-vpn-menubar", category: "vpn")
    private static let connectTimeout: TimeInterval = 60
    private static let connectedMarkers = ["Configured as ", "Connected as ", "ESP session established", "DTLS connected"]

    private init() {
        if isOpenconnectRunning() { state = .connected(ip: vpnIP() ?? ""); connectedSince = Date() }
        startPolling()
    }

    // MARK: - Public API

    func connect(profile: VPNProfile? = nil) {
        guard case .disconnected = state else { return }
        guard let target = profile ?? ProfileStore.shared.activeProfile, !target.username.isEmpty else {
            NotificationCenter.default.post(name: .vpnSecretsNotFound, object: nil)
            return
        }
        ProfileStore.shared.activeProfileID = target.id
        lastError = nil
        setState(.connecting)
        Authenticator.authenticate(reason: "connect to the ETH VPN as \(target.username)") { [weak self] ok, error in
            guard let self else { return }
            if ok { self.start(target) }
            else if let error { self.fail(error) }
            else { self.setState(.disconnected) }
        }
    }

    private func start(_ target: VPNProfile) {
        let store = ProfileStore.shared
        guard let password = store.password(for: target), let token = store.token(for: target) else {
            fail("No password or OTP secret is saved for “\(target.displayName)”. Edit the profile and enter them again.")
            return
        }
        if PrivilegedHelper.isInstalled() {
            launch(target, password: password, token: token)
            return
        }
        PrivilegedHelper.install { [weak self] result in
            switch result {
            case .success: self?.launch(target, password: password, token: token)
            case .failure(let error): self?.fail(error.localizedDescription)
            }
        }
    }

    func toggleConnection() {
        switch state {
        case .disconnected: connect()
        case .connected:    disconnect()
        default: break
        }
    }

    func disconnect() {
        guard process != nil || isOpenconnectRunning() else { return }
        setState(.disconnecting)
        process = nil
        stopHelper { [weak self] in
            if case .disconnecting = self?.state { self?.setState(.disconnected) }
        }
    }

    // MARK: - Connection

    private func launch(_ profile: VPNProfile, password: String, token: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", PrivilegedHelper.helperPath, "connect", profile.username, profile.realm, profile.server]

        let stdin = Pipe(), output = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = output
        proc.standardError = output
        log = ["Connecting [\(profile.displayName)] \(profile.username)@\(profile.realm).ethz.ch to \(profile.server)"]
        pendingOutput = Data()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data, from: proc) }
        }
        proc.terminationHandler = { [weak self] proc in
            output.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                self?.consume(rest, from: proc)
                self?.processExited(proc, server: profile.server)
            }
        }

        do {
            try proc.run()
        } catch {
            fail("Could not start the VPN helper: \(error.localizedDescription)")
            return
        }
        process = proc
        stdin.fileHandleForWriting.write(Data("\(password)\n\(token)\n".utf8))
        try? stdin.fileHandleForWriting.close()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self, self.process === proc, case .connecting = self.state else { return }
            self.process = nil
            self.stopHelper {}
            self.fail("Timed out after \(Int(Self.connectTimeout)) seconds without a connection to \(profile.server).")
        }
    }

    private func consume(_ data: Data, from proc: Process) {
        guard process === proc, !data.isEmpty else { return }
        pendingOutput.append(data)
        while let newline = pendingOutput.firstIndex(of: 0x0A) {
            let line = String(decoding: pendingOutput[..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingOutput.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            log.append(line)
            Self.logger.info("\(line, privacy: .public)")
            if log.count > 300 { log.removeFirst(log.count - 300) }
            if case .connecting = state, Self.connectedMarkers.contains(where: line.contains) {
                setState(.connected(ip: vpnIP() ?? ""))
            }
        }
    }

    private func processExited(_ proc: Process, server: String) {
        guard process === proc else { return }
        process = nil
        if let tail = String(data: pendingOutput, encoding: .utf8), !tail.isEmpty { log.append(tail) }
        let wasConnecting = { if case .connecting = state { return true }; return false }()
        if wasConnecting || proc.terminationStatus != 0 {
            fail(ConnectionDiagnosis.message(status: proc.terminationStatus, log: log, server: server))
        } else {
            setState(.disconnected)
            postNotification(body: "VPN connection closed.")
        }
    }

    private func fail(_ message: String) {
        lastError = message
        log.append("Error: \(message)")
        Self.logger.error("\(message, privacy: .public)")
        setState(.disconnected)
        postNotification(body: message)
        onError?(message)
    }

    private func stopHelper(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            PrivilegedHelper.run("/usr/bin/sudo", ["-n", PrivilegedHelper.helperPath, "disconnect"])
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: - Status polling (also picks up sessions started from the CLI)

    private func startPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
    }

    private func pollStatus() {
        let running = isOpenconnectRunning()
        switch state {
        case .connecting:
            break
        case .disconnecting:
            if !running { setState(.disconnected) }
        case .connected:
            if running {
                setState(.connected(ip: vpnIP() ?? ""))
            } else if process == nil {
                setState(.disconnected)
                postNotification(body: "VPN disconnected unexpectedly.")
            }
        case .disconnected:
            if running { setState(.connected(ip: vpnIP() ?? "")) }
        }
    }

    // MARK: - Helpers

    private func setState(_ newState: VPNState) {
        if !newState.isConnected { connectedSince = nil }
        else if !state.isConnected { connectedSince = Date() }
        state = newState
        onStateChange?(newState)
    }

    func isOpenconnectRunning() -> Bool {
        PrivilegedHelper.run("/usr/bin/pgrep", ["-x", "openconnect"]).status == 0
    }

    func vpnIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cursor = ifaddr
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name).hasPrefix("utun"),
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty { return ip }
            }
        }
        return nil
    }

    private func postNotification(body: String) {
        let content = UNMutableNotificationContent()
        content.title = AppConstants.appName
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Turns openconnect/helper output into an actionable message.
enum ConnectionDiagnosis {
    static func message(status: Int32, log: [String], server: String) -> String {
        let text = log.joined(separator: "\n").lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        if has("a password is required", "a terminal is required") {
            return "The VPN helper is not authorized. Open Manage Profiles and save a profile to reinstall it."
        }
        if let helperLine = log.last(where: { $0.hasPrefix("ethz-vpn-helper:") }) {
            return String(helperLine.dropFirst("ethz-vpn-helper:".count)).trimmingCharacters(in: .whitespaces).capitalizedFirst
        }
        if has("login failed", "failed to obtain webvpn cookie", "authentication failed", "auth failed", "invalid credentials") {
            return "Login failed. ETH rejected the username, WLAN password or OTP code. Check the profile, the realm, and that your Mac's clock is correct."
        }
        if has("tokencode", "token secret", "otp") && has("fail", "invalid") {
            return "The OTP secret could not be used to generate a code. Re-enter it in the profile."
        }
        if has("getaddrinfo", "failed to resolve", "nodename nor servname") {
            return "Could not resolve \(server). Check your internet connection and the server name."
        }
        if has("failed to connect to", "connection refused", "network is unreachable", "failed to open https connection", "no route to host", "timed out") {
            return "Could not reach \(server). Check your internet connection."
        }
        if has("certificate") && has("verify", "invalid", "fail") {
            return "The server certificate for \(server) could not be verified."
        }
        if has("vpnc-script", "failed to spawn script") || (has("script") && has("returned error")) {
            return "Connected, but configuring the network failed (vpnc-script). Reinstall the helper from Manage Profiles."
        }
        let last = log.last(where: { !$0.hasPrefix("Connecting [") }) ?? "no output"
        return "openconnect exited with status \(status): \(last)"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Notification.Name {
    static let vpnSecretsNotFound = Notification.Name("com.dcamenisch.ethz-vpn.secretsNotFound")
}
