import Foundation

@Observable final class SetupViewModel {
    enum Phase: Equatable {
        case idle
        case saving
        case installingHelper
        case error(String)
        case sudoersWarning(String)
        case done
    }

    var username: String
    var password: String
    var otpSecret: String
    var realm: String
    var showPassword: Bool = false
    var showOTP: Bool = false
    var phase: Phase = .idle

    var canSave: Bool {
        switch phase {
        case .idle, .error: return true
        default: return false
        }
    }

    var statusMessage: (text: String, isError: Bool)? {
        switch phase {
        case .idle, .done:
            return nil
        case .saving:
            return ("Saving credentials...", false)
        case .installingHelper:
            return ("Installing sudoers rule (requires admin password)...", false)
        case .error(let msg):
            return (msg, true)
        case .sudoersWarning(let msg):
            return (msg, true)
        }
    }

    init() {
        username = SecretsHelper.readUsername() ?? ""
        realm = SecretsHelper.readRealm() ?? "student-net"
        password = KeychainHelper.get(service: "eth-vpn-password") ?? ""
        otpSecret = KeychainHelper.get(service: "eth-vpn-token") ?? ""
    }

    func save(openconnectPath: String) {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOTP = otpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRealm = realm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "student-net"
            : realm.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedUsername.isEmpty else { phase = .error("Username is required."); return }
        guard !password.isEmpty else { phase = .error("WLAN Password is required."); return }
        guard !trimmedOTP.isEmpty else { phase = .error("OTP Secret is required."); return }

        phase = .saving
        guard KeychainHelper.set(service: "eth-vpn-password", value: password),
              KeychainHelper.set(service: "eth-vpn-token", value: trimmedOTP) else {
            phase = .error("Failed to save credentials to Keychain.")
            return
        }

        do {
            try SecretsHelper.writeFiles(username: trimmedUsername, realm: trimmedRealm)
        } catch {
            phase = .error("Failed to write config files: \(error.localizedDescription)")
            return
        }

        phase = .installingHelper
        SudoersHelper.installIfNeeded(openconnectPath: openconnectPath) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.phase = .done
                case .failure(let error):
                    let msg = "Sudoers install failed: \(error.localizedDescription)\nYou may be prompted for a password when connecting."
                    self.phase = .sudoersWarning(msg)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.phase = .done
                    }
                }
            }
        }
    }

    func requestCancel() {
        phase = .done
    }
}
