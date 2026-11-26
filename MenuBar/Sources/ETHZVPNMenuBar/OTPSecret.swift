import Foundation

enum OTPSecret {
    enum ParseError: LocalizedError {
        case notBase32
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .notBase32:
                return "The OTP secret must be the base32 key (letters A–Z and digits 2–7) or the full otpauth:// link."
            case .unsupported(let what):
                return "This OTP uses \(what). Only SHA1, 6 digits and 30-second codes are supported."
            }
        }
    }

    /// Accepts the base32 key (any case, spaces allowed) or a full otpauth:// link.
    static func normalize(_ input: String) throws -> String {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("otpauth://") {
            let items = URLComponents(string: raw)?.queryItems ?? []
            let q = Dictionary(items.map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            guard let secret = q["secret"] else { throw ParseError.notBase32 }
            if let alg = q["algorithm"], alg.uppercased() != "SHA1" { throw ParseError.unsupported("algorithm \(alg)") }
            if let d = q["digits"], d != "6" { throw ParseError.unsupported("\(d) digits") }
            if let p = q["period"], p != "30" { throw ParseError.unsupported("a \(p)-second period") }
            raw = secret
        }
        let cleaned = raw.uppercased().filter { !" -\t".contains($0) }
        guard !cleaned.isEmpty,
              cleaned.range(of: "^[A-Z2-7]+=*$", options: .regularExpression) != nil
        else { throw ParseError.notBase32 }
        return cleaned
    }
}
