import Foundation

/// Why an account was left out of an export. Never contains the secret.
public enum ExportSkipReason: Sendable, Equatable {
    /// The target format has no HOTP (counter based) codes.
    case hotpNotSupported
    /// The account's parameters are invalid (empty secret, digits or period out of range).
    case invalidAccount

    public var description: String {
        switch self {
        case .hotpNotSupported: "Zähler-basierte Codes (HOTP) lassen sich in diesem Format nicht ablegen"
        case .invalidAccount: "Die Kontodaten sind ungültig"
        }
    }
}

/// An account that could not be represented in an export: display label and reason, never a secret.
public struct ExportSkippedEntry: Sendable, Equatable {
    public var label: String
    public var reason: ExportSkipReason

    public init(label: String, reason: ExportSkipReason) {
        self.label = label
        self.reason = reason
    }
}

/// Result of an export. `data` contains every secret of `exportedCount` accounts: treat it as sensitive.
/// Accounts in `skipped` are not in `data`; parameters are never changed silently.
public struct ExportResult: Sendable {
    public var data: Data
    public var exportedCount: Int
    public var skipped: [ExportSkippedEntry]
}

/// Plain-text exports for moving accounts to other apps. All functions are pure.
///
/// Sources of the formats:
/// - Aegis: https://github.com/beemdevelopment/Aegis/blob/master/docs/vault.md (unencrypted vault: `header.slots`
///   and `header.params` are null, `db` is an object, db version 3)
/// - Apple Passwords CSV: header `Title,URL,Username,Password,Notes,OTPAuth`; the OTPAuth cell is written the
///   way the Passwords app writes it itself, `otpauth://totp?secret=…&algorithm=…&digits=…&period=…` without label
///   (community sources; Apple publishes no specification)
public enum AccountExporter {
    /// One `otpauth://` link per line, UTF-8, trailing newline.
    public static func otpauthList(_ accounts: [Account]) -> ExportResult {
        var lines: [String] = []
        var skipped: [ExportSkippedEntry] = []
        for a in sorted(accounts) {
            guard (try? a.validate()) != nil else { skipped.append(.init(label: a.displayLabel, reason: .invalidAccount)); continue }
            lines.append(OTPAuthURI.string(for: a))
        }
        return ExportResult(data: Data(lines.map { $0 + "\n" }.joined().utf8), exportedCount: lines.count, skipped: skipped)
    }

    /// Aegis unencrypted vault (JSON). Groups are exported by their id; accounts keep their group, favourite flag
    /// (`pinned`) and note.
    public static func aegisJSON(_ accounts: [Account], groups: [AccountGroup]) throws -> ExportResult {
        var entries: [[String: Any]] = []
        var skipped: [ExportSkippedEntry] = []
        let groupIDs = Set(groups.map(\.id))
        for a in sorted(accounts) {
            guard (try? a.validate()) != nil else { skipped.append(.init(label: a.displayLabel, reason: .invalidAccount)); continue }
            var info: [String: Any] = ["secret": Base32.encode(a.secret), "algo": a.algorithm.rawValue.uppercased(), "digits": a.digits]
            switch a.kind {
            case .totp: info["period"] = a.period
            case .hotp: info["counter"] = NSNumber(value: a.counter)
            }
            entries.append([
                "type": a.kind.rawValue,
                "uuid": a.id.uuidString.lowercased(),
                "name": a.name,
                "issuer": a.issuer,
                "note": a.note,
                "favorite": a.pinned,
                "icon": NSNull(), "icon_mime": NSNull(), "icon_hash": NSNull(),
                "info": info,
                "groups": a.groupID.flatMap { groupIDs.contains($0) ? [$0.uuidString.lowercased()] : nil } ?? [],
            ])
        }
        let root: [String: Any] = [
            "version": 1,
            "header": ["slots": NSNull(), "params": NSNull()],
            "db": [
                "version": 3,
                "entries": entries,
                "groups": groups.map { ["uuid": $0.id.uuidString.lowercased(), "name": $0.name] },
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return ExportResult(data: data, exportedCount: entries.count, skipped: skipped)
    }

    /// CSV for the macOS Passwords app (File > Import Passwords). TOTP only; HOTP accounts are returned as skipped.
    /// Title = issuer (or the name if there is no issuer), Username = account name, Notes = note; URL and
    /// Password stay empty. Cells are only quoted per RFC 4180 and otherwise written unchanged: the consumer is the
    /// Passwords app, not a spreadsheet, so no formula-injection prefix (it would corrupt names like `+49…`).
    public static func applePasswordsCSV(_ accounts: [Account]) -> ExportResult {
        var rows = ["Title,URL,Username,Password,Notes,OTPAuth"]
        var skipped: [ExportSkippedEntry] = []
        var count = 0
        for a in sorted(accounts) {
            guard (try? a.validate()) != nil else { skipped.append(.init(label: a.displayLabel, reason: .invalidAccount)); continue }
            guard a.kind == .totp else { skipped.append(.init(label: a.displayLabel, reason: .hotpNotSupported)); continue }
            let uri = "otpauth://totp?secret=\(Base32.encode(a.secret))&algorithm=\(a.algorithm.rawValue.uppercased())&digits=\(a.digits)&period=\(a.period)"
            let title = a.issuer.isEmpty ? a.name : a.issuer
            let username = a.issuer.isEmpty ? "" : a.name
            let cells = [title, "", username, "", a.note].map { CSV.escape($0) } + [CSV.escape(uri)]
            rows.append(cells.joined(separator: ","))
            count += 1
        }
        return ExportResult(data: Data(rows.map { $0 + "\n" }.joined().utf8), exportedCount: count, skipped: skipped)
    }

    private static func sorted(_ accounts: [Account]) -> [Account] {
        accounts.enumerated().sorted { a, b in
            a.element.sortIndex != b.element.sortIndex ? a.element.sortIndex < b.element.sortIndex : a.offset < b.offset
        }.map(\.element)
    }
}

/// Writes sensitive files readable by the owner only.
public enum PrivateFile {
    /// Creates or truncates `url`, sets mode 0600 and removes every ACL entry on the open descriptor (before any data
    /// is written, so the content is never readable by others, not even for a moment), writes `data` and flushes it.
    /// A half-written file is removed.
    ///
    /// What this guarantees: the file has mode 0600 and no ACL entries, also if it existed before (with `chmod +a`
    /// entries) or inherited entries from its folder when it was created. What it cannot: volumes that do not
    /// keep Unix permissions (exFAT, FAT, some network shares) and copies of the file made later.
    public static func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BackupError.ioFailure("") }
        var ok = fchmod(fd, 0o600) == 0 && clearACL(fd)
        if ok {
            ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = Foundation.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    offset += n
                }
                return true
            }
        }
        ok = ok && fsync(fd) == 0
        guard close(fd) == 0, ok else {
            try? FileManager.default.removeItem(at: url)
            throw BackupError.ioFailure("")
        }
    }

    /// Replaces the file's ACL with an empty one. A file without ACL (or on a volume that has none) is fine;
    /// an ACL that cannot be removed is a failure.
    static func clearACL(_ fd: Int32) -> Bool {
        guard let current = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            return [ENOENT, ENOTSUP, EINVAL].contains(errno)   // no ACL, or this volume has none
        }
        acl_free(UnsafeMutableRawPointer(current))
        guard let empty = acl_init(0) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        return acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) == 0
    }
}
