# Security policy

## Supported versions

Security fixes go into the latest release. MacAuth updates itself through Sparkle, so users get a fixed version without doing anything. Older versions are not patched.

## Reporting a vulnerability

Please do not open a public issue or pull request for a security problem.

Report it privately through GitHub: open the [Security tab of this repository](https://github.com/fbrogno/mac-auth/security) and choose "Report a vulnerability" ([GitHub Security Advisories](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)).

Please include:

- the MacAuth version (Settings, Updates) and your macOS version,
- what you found and what it allows an attacker to do,
- steps to reproduce, or a proof of concept if you have one.

Never send real secrets, backup files or QR codes from your own accounts. Use test data.

You will get an answer as soon as the maintainer can read the report. This is a small open-source project without a paid security team, so please allow some days. If the report is confirmed, the fix is prepared privately, released, and the advisory is published with credit to you if you want it.

## What counts

Examples of what we want to hear about:

- a way to read secrets out of the vault, the backup file or the clipboard without the unlock step,
- a weakness in the vault, key protection or backup encryption,
- secrets showing up in logs, preferences, crash output, file names or error messages,
- tampering with the update channel, the signature or the notarization,
- a way out of the App Sandbox.

## Threat model

The design is described in [docs/DESIGN.md](docs/DESIGN.md). This section says what it is meant to
withstand and where it stops.

### What MacAuth protects against

- **Someone who gets a copy of your files** (stolen backup disk, synced home folder, another user on the
  Mac): the vault file is encrypted with ChaCha20-Poly1305. With the default protection the vault key is
  wrapped by a key that never leaves this Mac's Secure Enclave, so the file is useless on any other
  device and cannot be attacked by guessing a password.
- **Someone at your unlocked Mac for a moment:** opening the vault needs Touch ID or the login password.
  This is enforced by the Secure Enclave, not by a check in the app's own code. The vault locks itself
  after inactivity and on sleep, screen lock and user switching.
- **Other apps reading the clipboard history:** copied codes are marked as concealed, which clipboard
  managers that follow the convention skip, are not sent to other devices through Universal Clipboard,
  and are removed after a short time.
- **Someone weakening the app at your unlocked Mac:** switching off the unlock prompt, or lowering the
  auto-lock, the screen protection, the hidden codes or the clipboard clearing, needs a fresh authentication.
  These four settings are stored inside the encrypted, authenticated vault (not in the preferences file, which
  can be edited without any authentication), so editing the preferences or passing launch arguments cannot
  lower them. While the vault is locked the strict defaults apply (auto-lock 5 minutes, screen protection on,
  clipboard cleared after 30 seconds). They are not part of backup files and are not taken over from a
  restored or imported file. A vault written by version 1.0.0 carried them in the preferences: on the first
  unlock an old value is adopted only if it is at least as strict as the default, otherwise the default is used.
- **A restore as a way around the lock:** every restore from the lock screen (an earlier version, a set-aside
  vault file, the previous generation, or a backup file) first needs Touch ID or the login password, which
  works even if the Secure Enclave key is lost. A restored vault is always opened with an authentication
  first, whatever its file says about the unlock prompt, and it comes back with the strict settings above.
- **Screen sharing and screenshots:** the window content is excluded by default. This is a request to
  macOS that ordinary screen sharing and screenshots honour; it is not a guarantee against every
  capture method.
- **Hostile input:** QR payloads, links and import files are checked against size and count limits and
  tested with malformed data; the binary formats are read by small parsers of our own, JSON by
  Foundation, images by the system frameworks (ImageIO, Vision). The app runs in the App Sandbox with the Hardened Runtime.
- **A tampered update (partly):** Sparkle installs an update only if the download carries a valid EdDSA
  signature made with the private key that belongs to the public key in the installed app, or if the new app's
  Developer ID code signature matches the one of the installed app (either check is enough; Sparkle keeps the
  second one for key rotation). Sparkle does not check notarization. Notarization is done by the release
  pipeline and is checked by Gatekeeper when someone downloads the app for the first time, not when an update
  is installed. The update feed (`appcast.xml`) is not signed by us; a changed feed can only point to a file
  that still has to pass the checks above, and the version text in the update notice is shortened and limited
  to harmless characters before it is shown. This does not protect against whoever controls the release
  pipeline: see "Releases" below.
- **A lost backup file:** it is encrypted with AES-256-GCM under a key derived from your password
  (PBKDF2-HMAC-SHA256, 600,000 rounds). Its strength is the strength of that password.

### What it does not protect against

- **Malware running as you while the vault is unlocked.** Software with your user rights that can read
  the app's memory, record the screen through other means, log keystrokes or control the app can obtain
  codes or secrets. No authenticator on a general-purpose computer can prevent this.
- **An attacker with your login password.** The unlock step accepts Touch ID or the login password, by
  design, so that a broken sensor does not lock you out.
- **Codes after they left the app.** A copied code is in the clipboard until it is cleared; apps that
  read the clipboard in that window see it. A code is only valid for seconds, a secret is not – secrets
  are never put on the clipboard.
- **Having both factors on one device.** If your passwords live on the same Mac, a full compromise of
  that Mac exposes both. Keep this in mind for high-value accounts.
- **Weak backup passwords.** A backup file can be attacked offline. Use a long passphrase.
- **Loss of the Mac without a backup.** The Secure Enclave key cannot be exported. Without a backup file
  the codes are gone. This is intended; the app reminds you to export a backup.
- **Import leftovers.** A screenshot of an export QR code or a plain-text export from another app contains
  every secret. MacAuth never copies such files, but it cannot delete them for you; it reminds you to.
  A password-manager export (Apple Passwords, Bitwarden, CSV) also holds every password. MacAuth reads the
  file into memory to parse it, keeps only the code and the label columns (issuer, name) and retains nothing
  else after the parse (the CSV scanner drops all other columns, notes included, while scanning); the file
  itself stays on disk until you delete it.
- **Plain-text exports.** "Export for Another App" (otpauth list, Aegis JSON, Apple Passwords CSV) writes every
  secret unencrypted and takes the data out of the app's protection: anyone who gets the file can generate
  the codes. It therefore needs a fresh authentication each time, shows a warning first, writes the file
  readable by the owner only (mode 0600 and no ACL entries, also if the file existed before or its folder
  would pass entries on) and puts nothing on the clipboard, in logs or in preferences. This cannot be
  guaranteed on volumes without Unix permissions (exFAT, FAT, some network shares), and it does not cover
  copies made later. Where the file goes and when it is deleted is up to you; never leave it in a cloud folder.
- **Spreadsheets and the Apple Passwords CSV.** The CSV for the Passwords app keeps the labels (issuer, name,
  note) exactly as they are, without neutralising cells that start with `=`, `+`, `-` or `@`: the consumer is
  the Passwords app, and a prefix would corrupt names such as `+49...`. Do not open this file in a spreadsheet
  program, where a crafted label could be run as a formula. The import of this CSV does not read the Notes
  column (notes in password managers often hold recovery codes).
- **A Mac without a login password.** macOS then has nothing to ask for: the system authentication passes
  without a question, and the Secure Enclave or keychain protection falls back to the state of the Mac.
  Nothing protects the plain-text export, the QR transfer and the backup export from someone at the unlocked
  Mac. MacAuth asks for an explicit confirmation naming this before each of them, and works normally
  otherwise. Set a login password in System Settings.

### Protection levels

| Setting | Vault key | Unlock |
|---|---|---|
| Default (Mac with Secure Enclave) | wrapped by a Secure Enclave key, bound to this Mac | Touch ID or login password, enforced by the enclave |
| Unlock prompt switched off, or no Secure Enclave | stored in the login keychain, not synchronised through iCloud | app lock (system authentication) unless switched off; the switch is stored in the authenticated header of the vault file and can only be changed while unlocked, after a fresh authentication |

The second level is weaker: the keychain item is guarded by macOS for this app's signature, but the lock
shown by the app is then a check in the app's own code, and the login keychain is part of Time Machine
backups and Migration Assistant transfers, protected by the login password. The settings show which
level is actually in use. Switching between the levels always creates a new vault key, so a key that
was once in the keychain does not protect a later Secure Enclave vault.

One limit remains from a time with the unlock prompt switched off: a vault file written then (a set-aside
`vault.replaced-*` file, or a copy in a Time Machine backup) and its keychain item are kept, because
MacAuth never deletes old vault files on its own. The app asks for an authentication before it restores
such a file, but someone with your user rights who puts the file in place by hand, outside the app, gets
a vault that opens without a prompt. If you ever used that mode, delete old `vault.replaced-*` files in
`~/Library/Containers/com.fbrogno.macauth/Data/Library/Application Support/MacAuth/` once you no longer
need them.

### Network

MacAuth opens exactly one kind of connection: the Sparkle update check against this repository's GitHub
Releases. No account data, identifiers or usage data are sent. Automatic checks can be switched off.

## Releases

Releases are built in GitHub Actions from a tag, signed with a Developer ID certificate and notarized by Apple (Gatekeeper checks this when the app is first downloaded). The DMG is published on GitHub Releases together with the appcast, whose entries carry an EdDSA signature of the DMG. See [docs/RELEASING.md](docs/RELEASING.md).

What the installed app checks before it installs an update: the EdDSA signature of the download against the public key in the app, or, as an alternative, that the new app is signed with the same Developer ID identity as the installed one. It does not check notarization, and the appcast feed itself is not signed. Updates are downloaded and installed automatically by default (installation happens when MacAuth quits); automatic checks and automatic installation can be switched off in Settings, Updates.

Trust therefore rests on the release pipeline: whoever controls the GitHub account or repository, the release workflow and its signing secrets (the Developer ID certificate, the Sparkle private key) can ship an update that every installed copy accepts, and such an update runs with access to the vault once it is unlocked. There is no second signer and no delay. If you cannot accept that, switch automatic installation off and install releases by hand after checking them.
