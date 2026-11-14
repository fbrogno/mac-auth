# MacAuth – Design

MacAuth is a native macOS app (macOS 15+, Swift/SwiftUI) for two-factor codes (TOTP/HOTP). It imports
Google Authenticator exports, keeps every secret on this Mac only and makes copying a code a one-step action.

Repo `fbrogno/mac-auth` (public, MIT) · bundle ID `com.fbrogno.macauth` · UI texts: German is the source
language, English comes from `.xcstrings` catalogs · code and comments in English.

## Principles

1. **Local only.** No account, no cloud, no telemetry, no icon downloads. The only network traffic is the
   Sparkle update check (signed appcast from GitHub Releases).
2. **No third-party code in the security path.** `AuthCore` uses CryptoKit, CommonCrypto, Security and
   LocalAuthentication only. Sparkle is the single dependency and lives in the app target.
3. **Secrets never leave the vault in plain text.** Not into logs, UserDefaults, crash output, window
   titles, file names or error messages. Errors name the account, never the secret.
4. **Honest about limits.** `SECURITY.md` states what the app protects against and what it does not.

## Layout

| Path | Content |
|---|---|
| `Package.swift`, `Sources/AuthCore`, `Tests/AuthCoreTests` | tested library, no UI, no dependencies |
| `Sources/MacAuth` | SwiftUI app (built from `project.yml` via XcodeGen, not by SwiftPM) |
| `project.yml`, `scripts/`, `Config/`, `Resources/`, `.github/workflows/` | build, signing, notarization, release |

## AuthCore

### OTP
- TOTP (RFC 6238) and HOTP (RFC 4226); SHA-1, SHA-256, SHA-512; 6 to 8 digits; period 15–120 s (default 30).
- `Base32` (RFC 4648; decoding ignores case, spaces, dashes and padding).
- `otpauth://totp|hotp/...` parse and serialise (issuer from label prefix and/or `issuer` parameter).

### Google Authenticator export
- `otpauth-migration://offline?data=<base64 protobuf>`; hand-written protobuf reader/writer, no dependency.
- Fields: `otp_parameters` (secret, name, issuer, algorithm, digits, type, counter), `version`,
  `batch_size`, `batch_index`, `batch_id`. Unknown fields are skipped, malformed input throws a typed error.
- Batches: an export can span several QR codes; the importer reports "2 of 3 scanned" via batch id/index.
- Writer: the same format for "transfer to phone" (max. 10 accounts per QR code). Google's format has no
  period field and only 6 or 8 digits; accounts it cannot represent are refused, never exported with
  silently changed parameters. They can be transferred as single `otpauth://` QR codes.

### Other import formats
`ImportDetector` recognises a file by its content, not by its extension: a text file with one `otpauth://` link
per line (Ente Auth and many others), Aegis (unencrypted JSON export), 2FAS (unencrypted `.2fas` export),
MacAuth's own backup, Google migration links, and the following password-manager formats:
- **Apple Passwords CSV** (`Title,URL,Username,Password,Notes,OTPAuth`; the OTPAuth cell holds an `otpauth://` link).
- **Generic CSV** with a header row and an OTP column named `OTPAuth`, `totp`, `login_totp` (Bitwarden CSV), `2fa`,
  `otp` or `One-time password` (case-insensitive); covers 1Password (`OTPAuth`) and Proton Pass (`totp`) CSV. The
  cell is an `otpauth://` link or a bare Base32 setup key (then SHA1/6/30). Issuer and name come from the link,
  otherwise from the title/name and username/login/email columns.
- **Bitwarden JSON** (unencrypted): `items[].login.totp`, link or bare Base32 key; `steam://` entries are listed as unusable.
- **andOTP** plain JSON backup (top-level array, Base32 `secret`, `type` TOTP/HOTP; STEAM/MOTP listed as unusable).

Encrypted Aegis/2FAS/Bitwarden files are recognised and refused with a hint to export unencrypted. Entries that
cannot be used are listed with their label and the reason, never with their secret.
CSV files are read by an own RFC 4180 parser (quotes, doubled quotes, embedded commas/newlines, CRLF/LF, BOM) with
limits (rows, columns, field size); malformed input throws a typed `ImportError`. **Only the code and label columns
are kept:** the file is read into memory for parsing, and the parser drops every other column (password, notes, URL)
while scanning, so nothing but the OTP value and the label columns reaches a result, error or description and nothing
else is retained after the parse. Rows without a code are skipped silently and counted in
`ImportResult.rowsWithoutCode` ("37 Einträge ohne Code übersprungen"). A row whose only content sits in a discarded
column still counts as a row (toward `rowsWithoutCode` and the row limit); blank lines before the header are skipped.
A CSV without any usable code and without any unusable entry has `hasNothingToReview` and leads to the "Keine Codes
gefunden" alert, never to an empty review sheet; a text with `otpauth://` lines whose first line merely looks like a
CSV header is read as a line list. JSON counters (andOTP, Aegis) must be exact non-negative integers up to
`UInt64.max`; anything else (`5.7`, `1e30`, negative) lists the entry as unusable.

### Other export formats
`AccountExporter` (pure functions, `[Account]` to `Data`) writes an `otpauth://` list (one link per line), an
unencrypted Aegis vault (`header.slots/params` null, db version 3) and a CSV for the Apple Passwords app (TOTP
only; Title = issuer (the name if there is no issuer), Username = name (empty without issuer), URL/Password empty,
Notes = the account note (empty if there is none), OTPAuth label-less like the Passwords app writes it). The import of
this CSV does not read Notes (notes in password managers often hold recovery codes) and reads an empty Username with a
label-less link as "name = Title, no issuer", so an export/import round trip keeps issuer and name stable.
Each function reports accounts it cannot represent (HOTP in the Passwords CSV, invalid parameters) as
`ExportSkippedEntry` with label and reason; parameters are never changed silently. CSV cells are only quoted per
RFC 4180 and otherwise written unchanged, so labels that start with `=`, `+`, `-` or `@` are kept verbatim: the
consumer is the Passwords app, not a spreadsheet, and a formula-injection prefix (a leading apostrophe) would corrupt
usernames such as `+49…` or `-name`. The file must not be opened in a spreadsheet (see `SECURITY.md`).
All three outputs contain every secret in plain text and need a fresh authentication in the UI. `PrivateFile.write`
creates the file with mode 0600, removes every ACL entry (`acl_set_fd_np` with an empty ACL; both set on the open
descriptor before any data is written, so a pre-existing `chmod +a` entry or one inherited from the folder does not
survive) and removes a half-written file. Not guaranteed: volumes without Unix permissions (exFAT, some network shares)
and later copies.

### Model
`Account`: id (UUID), issuer, name, secret (bytes), algorithm, digits, period, kind (totp/hotp), counter,
groupID, pinned, sortIndex, createdAt, lastUsedAt, note.
`Group`: id, name, symbol (SF Symbol name), colour. Defaults on first start: "Firma", "Privat".
Duplicate = same secret bytes + same kind/algorithm/digits/period.

### Vault
- One file: `Application Support/MacAuth/vault.json` (inside the sandbox container). Written atomically
  (temp file, `F_FULLFSYNC`, rename, directory sync); the previous generation is kept as
  `vault.previous.json`.
- **Nothing is ever overwritten blindly.** Whenever an existing vault file would be replaced by something
  that is not its own next generation (restore from a backup, recovery, an unknown file found at save
  time), the old file is first set aside unchanged as `vault.replaced-<UTC time>.json`, together with its
  key material. These files are never deleted automatically and can be restored from the lock screen.
- Envelope (JSON): `version`, `protector`, protector fields, `nonce`, `ciphertext`, `tag`.
  Payload: JSON of accounts and groups, sealed with **ChaCha20-Poly1305** under a random 256-bit vault key;
  the envelope header is authenticated as AAD.
- The vault key is held by a `KeyProtector`:
  - **SecureEnclaveProtector** (default when a Secure Enclave is present): CryptoKit
    `SecureEnclave.P256.KeyAgreement.PrivateKey` with access control
    `[.privateKeyUsage, .userPresence]`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The envelope stores
    the enclave key blob (usable on this device only), an ephemeral public key and the wrapped vault key
    (ECDH → HKDF-SHA256 → ChaCha20-Poly1305). Unlocking therefore *cryptographically* needs Touch ID or the
    login password; it is not a mere UI gate.
  - **KeychainProtector** (fallback: no Secure Enclave, or the user turned the unlock prompt off): vault key
    as generic password in the login keychain, never synchronised through iCloud. Each wrap creates its
    own item; an item is only removed after the file that replaces it has been written. Note: the
    file-based login keychain ignores `ThisDeviceOnly`, so this item travels with Time Machine and
    Migration Assistant, protected by the login password. The app lock is then a
    `LAContext.deviceOwnerAuthentication` gate. Whether that gate is required is stored as `appLock` in
    the authenticated header of the vault file, not in the preferences: it can only be lowered through
    the unlocked store after a fresh authentication, and a file without the field counts as "required".
  - Switching the app lock back ON (keychain mode) also creates a new vault key and discards `vault.previous.json`
    (`setRequiresAppAuthentication`), so a previous generation that says `appLock=false` under the same key cannot
    be restored later.
  - Changing the protector always creates a **new vault key** and re-seals the contents, then destroys the
    old key material and the previous generation that depended on it. Key material that a set-aside file
    (`vault.replaced-*`) still refers to is kept. A key that once lived in the
    keychain therefore never protects a later Secure Enclave vault.
  - **InMemoryProtector** for tests.
- **Security settings** (`SecuritySettings`: auto-lock, screen protection, hidden codes, clipboard clearing) are part of
  the vault payload (`VaultData.security`, missing = strict defaults), not of the preferences. They are not written
  to backup files, not read from them and not merged by imports. While locked, the strict defaults apply. A vault
  payload of 1.0.0 lacks the field and opens unchanged. On the first unlock after the update the old preference values
  are migrated once (adopted only if at least as strict as the default) and the old keys are removed.
- **Restore requires authentication.** Every restore from the lock screen (earlier version, set-aside file,
  previous generation, backup file) first needs `LAContext` device-owner authentication (`RecoveryAuthorization`: one
  lock generation, five minutes, used up by the restore). `VaultStore` marks every restore/recovery (`pendingAuthentication`,
  with a marker file next to the vault, also set when `load()` falls back to the previous generation):
  `requiresAppAuthentication` is then true whatever the restored header says, a keychain vault with `appLock=false`
  refuses `unlock` without `appAuthenticated`, and the first successful unlock re-seals the vault with `appLock=true`
  under a new key (previous generation dropped) and strict security settings. The user can switch the prompt off again
  afterwards, after a fresh authentication.
- Unlocking always goes through the protector; there is no shortcut for an already unlocked store.
  Locking takes effect immediately; a lock generation counter lets the app discard results of anything
  that was still running (unlock prompts, file dialogs, camera callbacks).
- Unlocked state: vault key and accounts live in memory only; locking drops them (key bytes overwritten
  best-effort). Auto-lock after inactivity (default 5 min; 1/5/15/60/never) and always on sleep, screen
  lock and fast user switching.
- A lost Secure Enclave key (new Mac, erased Mac) is recovered from a backup file – by design. The core
  never declares a key permanently unusable on its own: temporary conditions (for example a locked
  screen, error -25308) are reported as "try again later"; `keyUnavailable` says that this device cannot
  use the stored key (vault from another or an erased Mac), which is a statement about the device, not
  about the file or a backup. After any failed unlock the lock screen offers "restore from backup" and
  "restore an earlier version"; replacing a vault is always the user's explicit decision and keeps the
  old file.

### Backup file (`.macauth`)
- JSON: `format: "macauth-backup"`, `version: 1`, `kdf: {name: "pbkdf2-hmac-sha256", iterations: 600000,
  salt}`, `cipher: "aes-256-gcm"`, `nonce`, `ciphertext`, `tag`. The header is authenticated as AAD.
- Password: at least 10 characters, entered twice. Wrong password and tampering are distinguishable from
  I/O errors but not from each other (both: "Passwort falsch oder Datei beschädigt").
- The format is documented in `docs/backup-format.md` with a short stand-alone decryption script, so a
  backup never depends on this app.

## App

Sandboxed (`app-sandbox`, `network.client` for Sparkle, `device.camera`, `files.user-selected.read-write`),
Hardened Runtime, Developer ID, notarised. No data-protection keychain, so no provisioning profile is needed.

### Window
A normal window with Dock icon (min. 760 × 520): sidebar + card grid.
- **Sidebar:** Alle · Favoriten · groups (Firma, Privat, own groups; rename, colour, symbol, delete) · lock.
- **Cards:** monogram tile in a colour derived from the issuer, issuer, account name, the code in large
  monospaced digits grouped `482 913`, a countdown ring. In the last 5 s the ring turns red and the next
  code is shown small. HOTP cards show a "next code" button instead of a ring.
- **Copy:** click on a card, `↵` on the selection, or `⌘1`–`⌘9` for the first nine visible cards. The card
  confirms with "Kopiert ✓". Optional: hide the window after copying.
- **Search:** the field has focus on start and after unlocking; typing anywhere filters (issuer, name,
  group, note); `esc` clears; arrow keys move the selection.
- **Shortcuts:** `⌘N` add · `⌘F` search · `⌘L` lock · `⌘,` settings · `⌘C` copy selection · `⌥⌘C` copy
  next code · `⌘⌫` delete with confirmation (only when no text field has focus; "Cancel" is the default
  button of every destructive dialog).
- **Global shortcut** (optional, off by default): shows or hides the window from anywhere; with "hide after
  copying" the previous app is in front again as soon as the code is on the clipboard.
- **Context menu:** copy, copy next code, edit, move to group, pin, show QR code (after re-authentication),
  delete. Drag to reorder, drag onto a sidebar group to move.
- **List mode** as a denser alternative to the grid.

### First start and import
The first start shows three large choices: **Aus Google Authenticator importieren**, **Backup
wiederherstellen**, **Manuell hinzufügen**. Import sources:
- Mac camera (scan the export QR from the phone screen; live preview, multi-QR batches counted),
- image file or screenshot (open panel, drag onto the window, paste from the clipboard),
- a single `otpauth://` link or setup key typed in,
- an export file of another app (see "Other import formats").
The camera is the recommended way. After an import from a screenshot or a plain-text export the app
reminds the user to delete that file, because it contains every secret. The import dialog also offers
"Aus Apple Passwörter" (how-to: Passwörter app, Ablage > Alle Passwörter in eine Datei exportieren) and
"Aus anderer App (Datei)" (list of supported apps). The review sheet names the detected format and shows
"N Einträge ohne Code übersprungen"; for password-manager files (Apple Passwords, generic CSV, Bitwarden) it states
that only the codes are imported and passwords are ignored and not stored, and the reminder after the import says the
file holds all passwords.
QR decoding with Vision (`VNDetectBarcodesRequest`). Every import ends in a **review sheet**: found
accounts with checkboxes, target group (Firma/Privat/…) for all or per row, duplicates marked and
unchecked. Nothing is stored before the user confirms. Imported images are never copied or kept.

### Export
- Encrypted backup file (see above).
- "Auf Handy übertragen": QR codes in Google's migration format, or one `otpauth://` QR per account.
- "Für andere App exportieren (unverschlüsselt)" (File menu; the encrypted backup stays the recommended way): link
  list (`.txt`), Aegis (`.json`), Apple Passwords (`.csv`). Flow (`BackupFlow.startPlainExport`, `PlainExportSheet`):
  fresh authentication, then the sheet with target choice, then a warning stage (every secret in plain text, anyone
  with the file can generate the codes, import and delete right away, never in cloud folders; "Abbrechen" is the
  default button), then the save panel, then the write (mode 0600, no ACL), then a confirmation with the number of
  accounts written, the accounts that could not be exported (label and reason) and the reminder to delete the file.
  The save panel opens first; the file content is built only after the user chose a location and the lock generation
  is still the one the authentication was done in, and it is never kept in view state. The backup export works the
  same way (panel first, then the encryption). `FilePanels.cancelAll()` closes every open open/save panel when the
  vault locks, so no panel stays over the lock screen, and every step checks the lock generation, so nothing is
  written after locking. Nothing goes to the clipboard, logs or preferences.
All three need a fresh authentication; on a Mac without a login password, where the system check passes without asking
(`AuthOutcome.noPasscode`), an additional explicit confirmation names that nothing protects the export. So does every
setting that lowers protection (unlock prompt off, longer or no auto-lock, screen protection off, hidden codes off,
longer or no clipboard clearing); while the vault is locked the security settings cannot be changed at all. These
settings live in the vault (see "Security settings"); the remaining preferences are read from the app's persistent
domain only, so launch arguments cannot override them. `--print-settings` shows what a naive `UserDefaults` read
returns next to what the app uses (the strict defaults while no vault is unlocked).

### Clipboard
Copied codes carry `org.nspasteboard.ConcealedType` (clipboard managers skip them), stay on this Mac
(no Universal Clipboard) and are cleared after 30 s (10/30/60/never) if the clipboard still holds the code.

### Screen
Window content is excluded from screen sharing and screenshots (`NSWindow.sharingType = .none`), default
on, switchable. Optional: codes hidden until hover/selection.

### Settings
Unlock (Touch ID/password required, auto-lock time), clipboard clearing, screen protection and hide codes (these four
are stored in the vault), hide after copy, default group for imports, updates (Sparkle), backup reminder.

Updates: Sparkle checks every 6 hours (`SUScheduledCheckInterval`) plus one quiet background check about 12 s
after launch (not if the last check was under 15 minutes ago). Background checks never open a window (gentle
reminders: `standardUserDriverShouldHandleShowingScheduledUpdate` returns false). A found update shows as a notice
at the bottom of the sidebar ("Update verfügbar – Version X"); a click opens Sparkle's window. The notice stays until
the update is installed or skipped; it is only shown in the main window, so while the vault is locked nothing is
shown and it appears again after unlocking. The version text comes from the unsigned appcast and is only shown if it
consists of `[0-9A-Za-z.\-+ ]` and is at most 20 characters (`AppPolicy.displayVersion`); otherwise the notice says
"Update verfügbar" without a version. "Updates automatisch installieren" (`automaticallyDownloadsUpdates`,
default on via `SUAutomaticallyUpdate`) downloads in the background and installs when the app quits; it needs
automatic checks. The updater never starts in demo mode. Sparkle accepts an update if the EdDSA signature or the
Developer ID identity matches (not notarization); see `SECURITY.md` for the trust model.

## Verification
- `swift test`: RFC 6238 and RFC 4226 vectors, Base32, otpauth URIs, migration reader/writer against fixed
  byte fixtures, vault round trip, backup round trip, wrong password, tampered header/ciphertext.
- `MacAuth --render-docs <dir>` renders the main views with demo data to PNG (light and dark, de and en)
  for review and for the README. Demo data only, never the real vault.
- `scripts/release.sh` verifies signature, Hardened Runtime, entitlements, notarisation and Gatekeeper.
