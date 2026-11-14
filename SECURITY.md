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
- **Someone weakening the app at your unlocked Mac:** switching off the unlock prompt, the auto-lock or
  the screen protection needs a fresh authentication, and launch arguments cannot override these
  settings.
- **Screen sharing and screenshots:** the window content is excluded by default. This is a request to
  macOS that ordinary screen sharing and screenshots honour; it is not a guarantee against every
  capture method.
- **Hostile input:** QR payloads, links and import files are checked against size and count limits and
  tested with malformed data; the binary formats are read by small parsers of our own, JSON by
  Foundation, images by the system frameworks (ImageIO, Vision). The app runs in the App Sandbox with the Hardened Runtime.
- **A tampered update:** updates must carry a valid EdDSA signature and come as a notarized,
  Developer-ID-signed app.
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

### Network

MacAuth opens exactly one kind of connection: the Sparkle update check against this repository's GitHub
Releases. No account data, identifiers or usage data are sent. Automatic checks can be switched off.

## Releases

Releases are built in GitHub Actions, signed with a Developer ID certificate, notarized by Apple, and updates are signed with an EdDSA key that Sparkle verifies. See [docs/RELEASING.md](docs/RELEASING.md).
