# Privacy

MacAuth collects no data. Your accounts, secrets and codes never leave your Mac.

- **Storage:** everything is kept in an encrypted vault inside the app's sandbox container on this Mac. There is no account, no cloud sync and no telemetry.
- **Network:** the only connection MacAuth opens is the update check against this repository's GitHub Releases (Sparkle). It sends no account data, identifiers or usage data; as with any web request, GitHub sees the request itself, such as your IP address. Checks run about every 6 hours and shortly after launch; updates are downloaded from the same GitHub Releases. Automatic checks and automatic installation can be switched off in the settings.
- **Camera:** used only to scan a QR code when you import accounts. Frames are processed on the device and nothing is recorded or stored. Images you open or paste for import are not copied or kept.
- **Backups and transfers:** a backup file or a transfer QR code is created only when you ask for it, and only you decide where it goes.

Details: [SECURITY.md](SECURITY.md) and [docs/DESIGN.md](docs/DESIGN.md).
