import Foundation

/// `otpauth://totp|hotp/Issuer:name?secret=...` (Google Key URI format).
public enum OTPAuthURI {
    public static func isOTPAuthURI(_ string: String) -> Bool {
        hasScheme(string.trimmingCharacters(in: .whitespacesAndNewlines), "otpauth://")
    }

    public static func parse(_ input: String, now: Date = Date()) throws -> Account {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.utf8.count <= Limits.maxOTPAuthURIBytes else { throw OTPAuthError.tooLong }
        guard hasScheme(s, "otpauth://") else { throw OTPAuthError.notOTPAuthURI }
        var rest = Substring(String(decoding: s.utf8.dropFirst("otpauth://".utf8.count), as: UTF8.self))
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        var path = rest
        var query: Substring = ""
        if let q = rest.firstIndex(of: "?") {
            path = rest[..<q]
            query = rest[rest.index(after: q)...]
        }
        let typeText: Substring
        var labelRaw: Substring = ""
        if let slash = path.firstIndex(of: "/") {
            typeText = path[..<slash]
            labelRaw = path[path.index(after: slash)...]
        } else {
            typeText = path
        }
        let typeName = typeText.lowercased()
        let kind: OTPKind
        switch typeName {
        case "totp": kind = .totp
        case "hotp": kind = .hotp
        default: throw OTPAuthError.unsupportedType(String(typeName.prefix(16)))
        }
        guard let label = PercentCoding.decode(labelRaw) else { throw OTPAuthError.malformedURI }

        var params: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let name: Substring
            let value: Substring
            if let eq = pair.firstIndex(of: "=") {
                name = pair[..<eq]
                value = pair[pair.index(after: eq)...]
            } else {
                name = pair
                value = ""
            }
            guard let key = PercentCoding.decode(name)?.lowercased(), let val = PercentCoding.decode(value) else {
                throw OTPAuthError.malformedURI
            }
            if params[key] == nil { params[key] = val }
        }

        guard let secretText = params["secret"], !secretText.isEmpty else { throw OTPAuthError.missingSecret }
        let secret: Data
        do { secret = try Base32.decode(secretText) } catch { throw OTPAuthError.invalidSecret }
        guard !secret.isEmpty, secret.count <= Limits.maxSecretBytes else { throw OTPAuthError.invalidSecret }

        let paramIssuer = (params["issuer"] ?? "").trimmingCharacters(in: .whitespaces)
        var name = label.trimmingCharacters(in: .whitespaces)
        var labelIssuer = ""
        if !paramIssuer.isEmpty, label.hasPrefix(paramIssuer + ":") {
            // The label repeats the issuer parameter (which may itself contain a colon).
            name = String(label.dropFirst(paramIssuer.count + 1)).trimmingCharacters(in: .whitespaces)
        } else if let colon = label.firstIndex(of: ":") {
            labelIssuer = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
            name = String(label[label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let issuer = paramIssuer.isEmpty ? labelIssuer : paramIssuer
        guard issuer.utf8.count <= Limits.maxTextBytes, name.utf8.count <= Limits.maxTextBytes else {
            throw OTPAuthError.tooLong
        }

        let algorithm: OTPAlgorithm
        switch params["algorithm"]?.uppercased() {
        case nil, "SHA1": algorithm = .sha1
        case "SHA256": algorithm = .sha256
        case "SHA512": algorithm = .sha512
        default: throw OTPAuthError.invalidParameter("algorithm")
        }
        var digits = 6
        if let d = params["digits"] {
            guard let v = Int(d), OTP.allowedDigits.contains(v) else { throw OTPAuthError.invalidParameter("digits") }
            digits = v
        }
        var period = OTP.defaultPeriod
        if kind == .totp, let p = params["period"] {
            guard let v = Int(p), OTP.allowedPeriods.contains(v) else { throw OTPAuthError.invalidParameter("period") }
            period = v
        }
        var counter: UInt64 = 0
        if kind == .hotp, let c = params["counter"] {
            guard let v = UInt64(c) else { throw OTPAuthError.invalidParameter("counter") }
            counter = v
        }
        return Account(issuer: issuer, name: name, secret: secret, algorithm: algorithm, digits: digits,
                       period: period, kind: kind, counter: counter, createdAt: now)
    }

    /// Serialises an account. The URI contains the secret; treat the result as sensitive.
    public static func string(for account: Account) -> String {
        var label = ""
        if !account.issuer.isEmpty {
            label += PercentCoding.encode(account.issuer) + ":"
        } else if account.name.contains(":") {
            // Keeps a colon inside the name from being read back as an issuer separator.
            label += ":"
        }
        label += PercentCoding.encode(account.name)
        var items = ["secret=" + Base32.encode(account.secret)]
        if !account.issuer.isEmpty { items.append("issuer=" + PercentCoding.encode(account.issuer)) }
        items.append("algorithm=" + account.algorithm.rawValue.uppercased())
        items.append("digits=\(account.digits)")
        switch account.kind {
        case .totp: items.append("period=\(account.period)")
        case .hotp: items.append("counter=\(account.counter)")
        }
        return "otpauth://\(account.kind.rawValue)/\(label)?" + items.joined(separator: "&")
    }

    private static func hasScheme(_ s: String, _ scheme: String) -> Bool {
        let head = String(decoding: s.utf8.prefix(scheme.utf8.count), as: UTF8.self)
        return head.lowercased() == scheme
    }
}
