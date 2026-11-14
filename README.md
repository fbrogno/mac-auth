**English** · [Deutsch](README.de.md)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/main-grid-dark-en.png">
    <img src="docs/images/main-grid-light-en.png" alt="MacAuth main window: sidebar with groups, cards with one-time codes and countdown rings" width="760">
  </picture>
</p>

# MacAuth

MacAuth is a native macOS app for two-factor codes (TOTP/HOTP). It keeps your secrets in an encrypted vault on this Mac only and makes copying a code a single step.

## Why

- 2FA codes where you work: on the Mac, one click or keystroke away.
- Work and private accounts stay apart, in groups ("Firma" and "Privat" are created on first start).
- Moves your accounts over from Google Authenticator.
- Everything is local: no account, no cloud, no telemetry. See [PRIVACY.md](PRIVACY.md).

## Features

- Import from Google Authenticator via the Mac camera, an image file or screenshot (open, drag, paste), or a single `otpauth://` link or setup key. Every import ends in a review step; nothing is stored until you confirm, duplicates are marked.
- Copy a code by clicking its card, with `↵` or with `⌘1`–`⌘9`. The next code is copied with `⌥⌘C`.
- Search by just typing; groups and favorites; grid or list view.
- Vault with Secure Enclave key protection and Touch ID (or login password).
- Auto-lock after inactivity (1, 5, 15, 60 minutes or never), and always on sleep, screen lock and user switching.
- Copied codes are marked as concealed and cleared from the clipboard after 10, 30 or 60 seconds (or never).
- Window hidden from screen sharing and screenshots (can be switched off); optional: codes shown only on hover or selection.
- Encrypted backup file with an open, documented format ([docs/backup-format.md](docs/backup-format.md)).
- Transfer accounts to a phone as QR codes (Google's migration format, or one `otpauth://` QR per account).
- German and English interface.

<table>
  <tr>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/first-run-dark.png"><img src="docs/images/first-run-light.png" alt="First start: import from Google Authenticator, restore a backup or add manually"></picture></td>
    <td width="50%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/import-review-dark.png"><img src="docs/images/import-review-light.png" alt="Review step before importing: found accounts, target group, duplicates unchecked"></picture></td>
  </tr>
</table>

The screenshots show demo data. Apart from the main window, they show the German interface.

## Install

1. Download the DMG from the [latest release](https://github.com/fbrogno/mac-auth/releases/latest).
2. Open it and drag MacAuth to Applications.

Requires macOS 15 or newer. The app is signed with a Developer ID and notarized by Apple. It updates itself (Sparkle, signed updates); you can switch automatic checks off.

## Getting started

1. In Google Authenticator on your phone: menu, **Transfer accounts**, **Export accounts**, select accounts. A QR code appears.
2. In MacAuth choose **Import from Google Authenticator** and scan the QR code with the Mac camera. If the export spans several QR codes, MacAuth counts them ("2 of 3").
3. Check the list, pick a group, import.
4. Then export a backup (`⇧⌘E`) and store it somewhere safe. Use a long password; it protects the file.

Do not delete the accounts from Google Authenticator before you have checked that the codes in MacAuth work.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-dark.png">
    <img src="docs/images/settings-light.png" alt="Settings, Security tab: unlock requirement, auto-lock, screen protection" width="420">
  </picture>
</p>

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| typing | search (`esc` clears) |
| `↑` `↓` `←` `→` | move selection |
| `↵` or `⌘C` | copy code of the selected account |
| `⌘1`–`⌘9` | copy code of the first nine visible cards |
| `⌥⌘C` | copy the next code |
| `⌘F` | focus search |
| `⌘N` / `⇧⌘N` | new account / new group |
| `⇧⌘I` | import |
| `⌘V` | paste an image or link to import |
| `⇧⌘E` | export backup |
| `⌘L` | lock |
| `⌘⌫` | delete selected account (with confirmation) |
| `⌘,` | settings |

## Security

- The vault is one file, sealed with ChaCha20-Poly1305. On a Mac with a Secure Enclave the vault key is wrapped by a key that never leaves it; opening needs Touch ID or the login password, enforced by the enclave. Without it (or if you switch the prompt off) the key sits in the login keychain, which is weaker.
- Secrets are never put on the clipboard, only the current code.
- The backup is AES-256-GCM with a key from your password (PBKDF2-HMAC-SHA256, 600,000 rounds). Its strength is the strength of your password.
- **Without a backup file, the codes are gone if you lose the Mac** or erase it. The Secure Enclave key cannot be exported. That is intended.
- Having password and second factor on one device is a deliberate trade-off. If that Mac is fully compromised, both are exposed. Think twice for high-value accounts.
- Not covered: malware running as you while the vault is unlocked, an attacker who knows your login password.

The threat model is in [SECURITY.md](SECURITY.md) (which also explains how to report a vulnerability), the design in [docs/DESIGN.md](docs/DESIGN.md).

## Build from source

You need macOS 15+, Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
swift test                               # tests for AuthCore
SIGN_IDENTITY=- ./scripts/build-app.sh   # build/MacAuth.app, ad-hoc signed
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the layout, style and how to send a pull request.

## License

[MIT](LICENSE). MacAuth is not affiliated with Google. "Google Authenticator" is a trademark of Google LLC.
