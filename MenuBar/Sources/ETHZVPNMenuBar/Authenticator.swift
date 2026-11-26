import AppKit
import Foundation
import LocalAuthentication

/// Requires Touch ID (or the account password) before stored credentials are used,
/// so an unlocked Mac alone is not enough to connect.
enum Authenticator {
    private static let requireKey = "eth-vpn-require-auth"

    static var isRequired: Bool {
        get { UserDefaults.standard.object(forKey: requireKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: requireKey) }
    }

    /// Completes on the main queue; `(false, nil)` means the user cancelled.
    static func authenticate(reason: String, force: Bool = false,
                             completion: @escaping (_ ok: Bool, _ error: String?) -> Void) {
        guard force || isRequired else { completion(true, nil); return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Password"
        var policyError: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            completion(false, "Authentication is unavailable: \(policyError?.localizedDescription ?? "unknown error")")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            DispatchQueue.main.async {
                if ok { completion(true, nil); return }
                let code = (error as? LAError)?.code
                if code == .userCancel || code == .appCancel || code == .systemCancel {
                    completion(false, nil)
                } else {
                    completion(false, error?.localizedDescription ?? "Authentication failed.")
                }
            }
        }
    }
}
