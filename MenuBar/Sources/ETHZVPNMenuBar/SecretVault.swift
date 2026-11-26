import CryptoKit
import Foundation
import LocalAuthentication

/// Encrypts profile secrets to a Secure Enclave key that can only be used after
/// Touch ID or the account password. Only ciphertext and the enclave-wrapped key
/// are stored on disk, so reading a secret needs the user, not just their session.
enum SecretVault {
    enum VaultError: LocalizedError {
        case unavailable, corrupt
        var errorDescription: String? {
            switch self {
            case .unavailable: return "This Mac has no Secure Enclave to protect the VPN secrets."
            case .corrupt: return "A saved secret could not be decrypted. Edit the profile and enter it again."
            }
        }
    }

    private static let keyURL = ProfileStore.directory.appendingPathComponent("enclave-key")
    private static let info = Data("ethz-vpn secret".utf8)

    /// Asks for Touch ID (or the account password) once; the returned context
    /// then unlocks the enclave key without further prompts.
    static func authenticate(reason: String, completion: @escaping (Result<LAContext, Error>) -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            DispatchQueue.main.async {
                completion(ok ? .success(context) : .failure(error ?? LAError(.authenticationFailed)))
            }
        }
    }

    static func seal(_ secret: String) throws -> String {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey().publicKey)
        let box = try AES.GCM.seal(Data(secret.utf8), using: symmetricKey(shared))
        guard let combined = box.combined else { throw VaultError.corrupt }
        return (ephemeral.publicKey.rawRepresentation + combined).base64EncodedString()
    }

    static func open(_ stored: String, context: LAContext) throws -> String {
        guard let blob = Data(base64Encoded: stored), blob.count > 64 else {
            throw VaultError.corrupt
        }
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: blob.prefix(64))
        let shared = try enclaveKey(context: context).sharedSecretFromKeyAgreement(with: peer)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: blob.dropFirst(64)), using: symmetricKey(shared))
        return String(decoding: plain, as: UTF8.self)
    }

    private static func symmetricKey(_ shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
    }

    private static func enclaveKey(context: LAContext? = nil) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        guard SecureEnclave.isAvailable else { throw VaultError.unavailable }
        if let data = try? Data(contentsOf: keyURL) {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data, authenticationContext: context)
        }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], nil)
        else { throw VaultError.unavailable }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
        try key.dataRepresentation.write(to: keyURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }
}
