import Foundation
import Security

enum KeychainHelper {
    private static func query(_ service: String, _ extra: [CFString: Any] = [:]) -> CFDictionary {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: NSUserName(),
        ]
        q.merge(extra) { $1 }
        return q as CFDictionary
    }

    static func get(service: String) -> String? {
        var result: CFTypeRef?
        guard SecItemCopyMatching(query(service, [kSecReturnData: true]), &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    static func set(service: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(service), [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query(service, [kSecValueData: data]), nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func exists(service: String) -> Bool {
        SecItemCopyMatching(query(service), nil) == errSecSuccess
    }

    static func delete(service: String) {
        SecItemDelete(query(service))
    }
}
