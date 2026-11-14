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

_To be written. See [docs/DESIGN.md](docs/DESIGN.md) for the design and its principles._

## Releases

Releases are built in GitHub Actions, signed with a Developer ID certificate, notarized by Apple, and updates are signed with an EdDSA key that Sparkle verifies. See [docs/RELEASING.md](docs/RELEASING.md).
