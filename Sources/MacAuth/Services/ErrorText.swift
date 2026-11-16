import AuthCore
import Foundation

/// Core errors carry fixed German texts; the UI maps them to localised ones by case.
enum ErrorText {
    static func message(for error: Error) -> String {
        switch error {
        case let e as Base32Error:
            switch e {
            case .invalidCharacter: return String(localized: "Der Schlüssel enthält ungültige Zeichen.")
            case .invalidLength: return String(localized: "Der Schlüssel hat eine ungültige Länge.")
            case .tooLong: return String(localized: "Der Schlüssel ist zu lang.")
            }
        case let e as OTPError:
            switch e {
            case .emptySecret: return String(localized: "Der Schlüssel ist leer.")
            case .invalidDigits: return String(localized: "Ungültige Stellenzahl (erlaubt: 6 bis 8).")
            case .invalidPeriod: return String(localized: "Ungültiges Intervall (erlaubt: 15 bis 120 Sekunden).")
            }
        case let e as OTPAuthError:
            switch e {
            case .notOTPAuthURI: return String(localized: "Das ist kein otpauth-Link.")
            case .malformedURI: return String(localized: "Der otpauth-Link ist fehlerhaft.")
            case .tooLong: return String(localized: "Der otpauth-Link ist zu lang.")
            case .unsupportedType: return String(localized: "Dieser Codetyp wird nicht unterstützt.")
            case .missingSecret: return String(localized: "Im Link fehlt der Schlüssel.")
            case .invalidSecret: return String(localized: "Der Schlüssel im Link ist ungültig.")
            case .invalidParameter: return String(localized: "Der Link enthält einen ungültigen Wert.")
            }
        case let e as MigrationError:
            switch e {
            case .notMigrationURI: return String(localized: "Das ist kein Google-Authenticator-Export.")
            case .missingData: return String(localized: "Im Export-Link fehlen die Daten.")
            case .invalidBase64, .malformedProtobuf: return String(localized: "Die Exportdaten sind beschädigt oder unvollständig.")
            case .tooLarge: return String(localized: "Die Exportdaten sind zu groß.")
            case .tooManyAccounts: return String(localized: "Der Export enthält zu viele Konten.")
            case .inconsistentBatch: return String(localized: "Die Angaben zur Reihenfolge der QR-Codes sind widersprüchlich.")
            case .unsupportedForExport(let label):
                return String(localized: "Das Konto „\(label)“ lässt sich nicht im Google-Format übertragen. Nutze stattdessen einen QR-Code je Konto.")
            }
        case let e as ProtectorError:
            switch e {
            case .secureEnclaveUnavailable: return String(localized: "Dieser Mac hat keine Secure Enclave.")
            case .userCancelled: return String(localized: "Die Entsperrung wurde abgebrochen.")
            case .authenticationFailed: return String(localized: "Die Authentifizierung ist fehlgeschlagen.")
            case .interactionNotAllowed:
                return String(localized: "Gerade ist keine Abfrage möglich, zum Beispiel weil der Bildschirm gesperrt ist. Versuche es gleich noch einmal.")
            case .keyUnavailable:
                return String(localized: "Der Schlüssel dieses Tresors ist auf diesem Mac nicht verfügbar, zum Beispiel weil der Tresor auf einem anderen Mac oder vor einem Zurücksetzen angelegt wurde. Die Datei selbst ist nicht verloren.")
            case .keyNotFound, .secureEnclaveFailure, .dataCorrupted:
                return String(localized: "Der Schlüssel des Tresors ließ sich gerade nicht lesen. Versuche es noch einmal, deine Daten sind damit nicht verloren.")
            case .keychainFailure: return String(localized: "Der Schlüsselbund meldet einen Fehler.")
            case .invalidAccessControl: return String(localized: "Die Zugriffsregel für den Schlüssel konnte nicht erstellt werden.")
            }
        case let e as VaultError:
            switch e {
            case .noVault: return String(localized: "Es gibt noch keinen Tresor.")
            case .alreadyExists: return String(localized: "Es gibt bereits einen Tresor.")
            case .locked, .notUnlocked: return String(localized: "Der Tresor ist gesperrt.")
            case .corrupted: return String(localized: "Der Tresor ist beschädigt oder wurde verändert.")
            case .unsupportedVersion: return String(localized: "Der Tresor hat ein unbekanntes Format. Bitte aktualisiere MacAuth.")
            case .protectorMismatch: return String(localized: "Der Tresor ist mit einer anderen Schutzart gesichert.")
            case .noPreviousGeneration: return String(localized: "Es gibt keine ältere Fassung des Tresors.")
            case .replacedFileNotFound: return String(localized: "Diese Tresordatei gibt es nicht mehr.")
            case .unreadableKeyFiles: return String(localized: "Die Schlüsseldateien des Tresors lassen sich nicht lesen.")
            case .authenticationRequired: return String(localized: "Dafür ist zuerst eine Anmeldung mit Touch ID oder Passwort nötig.")
            case .ioFailure: return String(localized: "Die Tresordatei konnte nicht gelesen oder geschrieben werden.")
            }
        case let e as BackupError:
            switch e {
            case .passwordTooShort(let n): return String(localized: "Das Passwort muss mindestens \(n) Zeichen lang sein.")
            case .notABackup: return String(localized: "Das ist keine MacAuth-Sicherung.")
            case .unsupportedVersion: return String(localized: "Die Sicherung hat ein unbekanntes Format. Bitte aktualisiere MacAuth.")
            case .unsupportedParameters: return String(localized: "Die Sicherung verwendet nicht unterstützte oder unsichere Parameter.")
            case .wrongPasswordOrCorrupt: return String(localized: "Passwort falsch oder Datei beschädigt.")
            case .ioFailure: return String(localized: "Die Datei konnte nicht gelesen oder geschrieben werden.")
            }
        case let e as ImportError:
            switch e {
            case .emptyFile: return String(localized: "Die Datei ist leer.")
            case .tooLarge: return String(localized: "Die Datei ist zu groß.")
            case .tooManyEntries: return String(localized: "Die Datei enthält zu viele Einträge.")
            case .unrecognizedFormat: return String(localized: "Das Dateiformat wird nicht erkannt. Unterstützt werden Aegis, 2FAS, Ente Auth (otpauth-Liste), Bitwarden, andOTP, CSV-Dateien mit einer Code-Spalte (Apple Passwörter, 1Password, Proton Pass u. a.), die Android-Datenbank von Microsoft Authenticator (PhoneFactor) und MacAuth-Sicherungen.")
            case .encryptedFile(let format):
                return String(localized: "Die \(format.displayName)-Datei ist verschlüsselt. Exportiere sie in \(format.displayName) unverschlüsselt, importiere sie hier und lösche die Exportdatei danach.")
            case .unsupportedVersion: return String(localized: "Die Version dieser Datei wird nicht unterstützt.")
            case .damagedDatabase: return String(localized: "Die Datenbank ist beschädigt oder unvollständig und lässt sich nicht lesen. Kopiere die Datei „PhoneFactor“ noch einmal vom Gerät.")
            case .malformedCSV: return String(localized: "Die CSV-Datei ist fehlerhaft und lässt sich nicht lesen. Exportiere sie noch einmal aus der App.")
            }
        default:
            return String(localized: "Es ist ein unerwarteter Fehler aufgetreten.")
        }
    }
}

extension SkipReason {
    var localizedText: String {
        switch self {
        case .unsupportedType(let t): String(localized: "Codetyp „\(t)“ wird nicht unterstützt")
        case .unsupportedAlgorithm(let a): String(localized: "Algorithmus „\(a)“ wird nicht unterstützt")
        case .invalidSecret: String(localized: "Schlüssel ungültig")
        case .invalidParameter(let p): String(localized: "Ungültiger Wert für „\(p)“")
        case .notAnOTPAuthLine: String(localized: "Keine otpauth-Zeile")
        case .malformed: String(localized: "Eintrag fehlerhaft")
        case .noStandardCode: String(localized: "Kein Einmalcode hinterlegt (Anmeldung per Mitteilung oder ohne Passwort). Richte das Konto beim Dienst neu ein.")
        }
    }
}

extension ExportSkipReason {
    var localizedText: String {
        switch self {
        case .hotpNotSupported: String(localized: "Zähler-basierte Codes (HOTP) lassen sich in diesem Format nicht ablegen")
        case .invalidAccount: String(localized: "Die Kontodaten sind ungültig")
        }
    }
}

extension ImportFormat {
    /// Name for the review sheet; the German core names of apps stay as they are.
    var localizedName: String {
        switch self {
        case .applePasswordsCSV: String(localized: "Apple Passwörter (CSV)")
        case .genericCSV: String(localized: "CSV-Datei")
        case .otpauthLines: String(localized: "otpauth-Liste")
        default: displayName
        }
    }
}
