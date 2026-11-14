import AuthCore
import Foundation

/// Invented accounts for the documentation images. The real vault is never touched.
enum DemoData {
    /// 16 seconds into a minute: 30 s codes have 14 s left, the 20 s code of "Git-Server" only 4.
    static let now = Date(timeIntervalSince1970: 1_800_000_016)

    static let firma = AccountGroup(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "Firma", symbol: "building.2", colour: "#3B82F6")
    static let privat = AccountGroup(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "Privat", symbol: "house", colour: "#10B981")
    static let groups = [firma, privat]

    private static func account(_ n: Int, _ issuer: String, _ name: String, group: AccountGroup, pinned: Bool = false,
                                period: Int = 30, digits: Int = 6, kind: OTPKind = .totp, counter: UInt64 = 0, secretSeed: UInt8? = nil) -> Account {
        let seed = secretSeed ?? UInt8(n * 17 % 251)
        var bytes: [UInt8] = []
        for i in 0..<20 { bytes.append(UInt8((i * 31 + Int(seed) * 7 + 11) % 256)) }
        let idText = String(format: "00000000-0000-0000-0000-%012d", n)
        let id = UUID(uuidString: idText) ?? UUID()
        return Account(id: id, issuer: issuer, name: name, secret: Data(bytes), digits: digits, period: period, kind: kind,
                       counter: counter, groupID: group.id, pinned: pinned, sortIndex: n)
    }

    static let accounts: [Account] = [
        account(1, "Nordwind Cloud", "admin@nordwind.example", group: firma, pinned: true),
        account(2, "Beispielbank", "Mia Muster", group: privat, pinned: true),
        account(3, "Git-Server", "entwicklung@firma.example", group: firma, period: 20),
        account(4, "Mailstadt", "info@beispiel.example", group: firma),
        account(5, "Wolkenspeicher", "familie@beispiel.example", group: privat),
        account(6, "Reiseportal", "Mia Muster", group: privat, kind: .hotp, counter: 7),
        account(7, "Projektboard", "team@firma.example", group: firma),
        account(8, "Steuerportal", "Mia Muster", group: privat, digits: 8),
        account(9, "Zeiterfassung Pro", "m.muster@firma.example", group: firma),
    ]

    /// Accounts for the transfer image: the last two cannot be written in Google's format (45 s interval, 7 digits).
    static var transferAccounts: [Account] {
        accounts + [
            account(10, "Altsystem VPN", "vpn@firma.example", group: firma, period: 45),
            account(11, "Hausverwaltung", "Mia Muster", group: privat, digits: 7),
        ]
    }

    /// Same secret as "Nordwind Cloud": shows up as a duplicate in the review sheet.
    static var reviewAccounts: [Account] {
        var duplicate = account(1, "Nordwind Cloud", "admin@nordwind.example", group: firma)
        duplicate.id = UUID()
        return [
            duplicate,
            account(21, "Lagerverwaltung", "lager@firma.example", group: firma, secretSeed: 201),
            account(22, "Fotoalbum", "Mia Muster", group: privat, secretSeed: 202),
            account(23, "Rechnungsportal", "buchhaltung@firma.example", group: firma, digits: 8, secretSeed: 203),
        ].map { var a = $0; a.groupID = nil; return a }
    }
}
