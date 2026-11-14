import Foundation

// All error descriptions are German (the UI source language) and never contain secrets.
// UI code that needs English should switch over the cases instead.

public enum Base32Error: Error, Equatable, LocalizedError {
    case invalidCharacter
    case invalidLength
    case tooLong

    public var errorDescription: String? {
        switch self {
        case .invalidCharacter: "Der Schlüssel enthält ungültige Zeichen."
        case .invalidLength: "Der Schlüssel hat eine ungültige Länge."
        case .tooLong: "Der Schlüssel ist zu lang."
        }
    }
}

public enum OTPError: Error, Equatable, LocalizedError {
    case emptySecret
    case invalidDigits(Int)
    case invalidPeriod(Int)

    public var errorDescription: String? {
        switch self {
        case .emptySecret: "Der Schlüssel ist leer."
        case .invalidDigits: "Ungültige Stellenzahl (erlaubt: 6 bis 8)."
        case .invalidPeriod: "Ungültiges Intervall (erlaubt: 15 bis 120 Sekunden)."
        }
    }
}

public enum OTPAuthError: Error, Equatable, LocalizedError {
    case notOTPAuthURI
    case malformedURI
    case tooLong
    case unsupportedType(String)
    case missingSecret
    case invalidSecret
    case invalidParameter(String)

    public var errorDescription: String? {
        switch self {
        case .notOTPAuthURI: "Das ist kein otpauth-Link."
        case .malformedURI: "Der otpauth-Link ist fehlerhaft."
        case .tooLong: "Der otpauth-Link ist zu lang."
        case .unsupportedType(let t): "Nicht unterstützter Codetyp „\(t)“."
        case .missingSecret: "Im Link fehlt der Schlüssel."
        case .invalidSecret: "Der Schlüssel im Link ist ungültig."
        case .invalidParameter(let p): "Ungültiger Wert für „\(p)“."
        }
    }
}

public enum MigrationError: Error, Equatable, LocalizedError {
    case notMigrationURI
    case missingData
    case invalidBase64
    case malformedProtobuf
    case tooLarge
    case tooManyAccounts
    case inconsistentBatch
    /// The account cannot be written in Google's format (e.g. 7 digits). Carries the account label, never the secret.
    case unsupportedForExport(String)

    public var errorDescription: String? {
        switch self {
        case .notMigrationURI: "Das ist kein Google-Authenticator-Export."
        case .missingData: "Im Export-Link fehlen die Daten."
        case .invalidBase64: "Die Exportdaten sind beschädigt."
        case .malformedProtobuf: "Die Exportdaten sind beschädigt oder unvollständig."
        case .tooLarge: "Die Exportdaten sind zu groß."
        case .tooManyAccounts: "Der Export enthält zu viele Konten."
        case .inconsistentBatch: "Die Angaben zur Reihenfolge der QR-Codes sind widersprüchlich."
        case .unsupportedForExport(let a): "Das Konto „\(a)“ lässt sich nicht im Google-Format übertragen."
        }
    }
}

public enum ProtectorError: Error, Equatable, LocalizedError {
    case secureEnclaveUnavailable
    case userCancelled
    case authenticationFailed
    /// Temporary: the system could not show an authentication prompt right now (e.g. locked keychain, no
    /// GUI session; `errSecInteractionNotAllowed`, -25308). Retrying later can succeed. Never a verdict on the key.
    case interactionNotAllowed
    case keyNotFound
    /// The system reports that the key (blob) is unknown or unusable on THIS device, e.g. CryptoTokenKit
    /// `corruptedData` (-3) or `objectNotFound` (-6): the vault was made on another Mac or before a reset.
    /// It is a statement about this device, not about the data: the vault file and backups are untouched.
    case keyUnavailable(Int)
    case keychainFailure(Int32)
    case secureEnclaveFailure(Int)
    case dataCorrupted
    case invalidAccessControl

    public var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable: "Dieser Mac hat keine Secure Enclave."
        case .userCancelled: "Die Entsperrung wurde abgebrochen."
        case .authenticationFailed: "Die Authentifizierung ist fehlgeschlagen."
        case .interactionNotAllowed: "Die Abfrage ist gerade nicht möglich. Bitte später erneut versuchen."
        case .keyNotFound: "Der Schlüssel dieses Tresors ist auf diesem Mac nicht vorhanden."
        case .keyUnavailable(let c): "Der Schlüssel dieses Tresors ist auf diesem Mac nicht verfügbar (\(c))."
        case .keychainFailure(let s): "Der Schlüsselbund meldet einen Fehler (\(s))."
        case .secureEnclaveFailure(let c): "Die Secure Enclave meldet einen Fehler (\(c))."
        case .dataCorrupted: "Die Schutzdaten des Tresors sind beschädigt."
        case .invalidAccessControl: "Die Zugriffsregel für den Schlüssel konnte nicht erstellt werden."
        }
    }
}

public enum VaultError: Error, Equatable, LocalizedError {
    case noVault
    case alreadyExists
    case locked
    case notUnlocked
    case corrupted
    case unsupportedVersion(Int)
    case protectorMismatch(stored: String)
    case noPreviousGeneration
    case replacedFileNotFound
    /// A file that may reference key material could not be read, so nothing was deleted.
    case unreadableKeyFiles
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .noVault: "Es gibt noch keinen Tresor."
        case .alreadyExists: "Es gibt bereits einen Tresor."
        case .locked, .notUnlocked: "Der Tresor ist gesperrt."
        case .corrupted: "Der Tresor ist beschädigt oder wurde verändert."
        case .unsupportedVersion(let v): "Der Tresor hat ein unbekanntes Format (Version \(v))."
        case .protectorMismatch(let s): "Der Tresor ist mit „\(s)“ geschützt."
        case .noPreviousGeneration: "Es gibt keine ältere Fassung des Tresors."
        case .replacedFileNotFound: "Diese beiseitegelegte Tresordatei gibt es nicht mehr."
        case .unreadableKeyFiles: "Eine Tresordatei war nicht lesbar; es wurde nichts gelöscht."
        case .ioFailure(let m): "Dateifehler: \(m)"
        }
    }
}

public enum BackupError: Error, Equatable, LocalizedError {
    case passwordTooShort(minimum: Int)
    case notABackup
    case unsupportedVersion(Int)
    case unsupportedParameters
    /// Deliberately one case for both: a wrong password and a tampered file cannot be told apart.
    case wrongPasswordOrCorrupt
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .passwordTooShort(let n): "Das Passwort muss mindestens \(n) Zeichen lang sein."
        case .notABackup: "Das ist keine MacAuth-Sicherung."
        case .unsupportedVersion(let v): "Die Sicherung hat ein unbekanntes Format (Version \(v))."
        case .unsupportedParameters: "Die Sicherung verwendet nicht unterstützte oder unsichere Parameter."
        case .wrongPasswordOrCorrupt: "Passwort falsch oder Datei beschädigt."
        case .ioFailure(let m): "Dateifehler: \(m)"
        }
    }
}

public enum ImportError: Error, Equatable, LocalizedError {
    case emptyFile
    case tooLarge
    case tooManyEntries
    case unrecognizedFormat
    /// An encrypted Aegis or 2FAS file. Not decrypted; the user should export unencrypted.
    case encryptedFile(ImportFormat)
    case unsupportedVersion(String)
    /// The file looks like CSV but cannot be parsed. Carries a fixed reason text, never file content.
    case malformedCSV(String)

    public var errorDescription: String? {
        switch self {
        case .emptyFile: "Die Datei ist leer."
        case .tooLarge: "Die Datei ist zu groß."
        case .tooManyEntries: "Die Datei enthält zu viele Einträge."
        case .unrecognizedFormat: "Das Dateiformat wird nicht erkannt."
        case .encryptedFile(let f): "Die \(f.displayName)-Datei ist verschlüsselt. Bitte unverschlüsselt exportieren."
        case .unsupportedVersion(let v): "Die Dateiversion (\(v)) wird nicht unterstützt."
        case .malformedCSV(let r): "Die CSV-Datei ist fehlerhaft (\(r))."
        }
    }
}
