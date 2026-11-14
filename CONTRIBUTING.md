# Contributing

Thanks for looking at MacAuth. Bug reports and small, focused pull requests are welcome. For anything bigger than a fix, please open an issue first so we can agree on the approach before you spend time on it.

- Security problem: do not open a public issue, see [SECURITY.md](SECURITY.md).
- Never put real secrets, backup files or QR codes of your own accounts into an issue, a test or a screenshot.

## How the repository is laid out

| Path | What is in it |
|---|---|
| `Sources/AuthCore` | The library without UI and without dependencies: OTP (TOTP/HOTP), Base32, `otpauth` URIs, Google Authenticator export format, vault, key protection, backup file |
| `Tests/AuthCoreTests` | Tests for `AuthCore` (RFC test vectors, fixtures, round trips) |
| `Sources/MacAuth` | The app (SwiftUI), built from `project.yml` with XcodeGen, not by SwiftPM; Sparkle updater |
| `Resources` | `Info.plist`, entitlements (App Sandbox), localised Info.plist texts, app icon |
| `project.yml`, `Config` | XcodeGen project of the app, public Sparkle key |
| `scripts`, `.github/workflows` | Build, signing, release, CI |
| `docs` | Design ([docs/DESIGN.md](docs/DESIGN.md)), release guide ([docs/RELEASING.md](docs/RELEASING.md)), backup format |

The rule of thumb: logic goes into `AuthCore` and has tests. The app target only shows and acts. `AuthCore` must stay free of third-party code.

## Build and test

You need macOS 15 or newer, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
swift test                               # tests for AuthCore
SIGN_IDENTITY=- ./scripts/build-app.sh   # build/MacAuth.app, ad-hoc signed
scripts/check-l10n.sh                    # string catalogs complete (de, en)
```

CI runs `swift test` and an ad-hoc app build on every pull request. Please run `swift test` yourself before you push.

Do not run `scripts/release.sh` or `scripts/setup-release-secrets.sh`. They sign and publish and need the maintainer's credentials.

## Style

- Follow the code around you. Small files, clear names, comments that explain why, not what. Code and comments in English.
- UI texts: German is the source language, English comes from the `.xcstrings` catalogs. Every new text needs both (`scripts/l10n-sync.sh`, then `scripts/check-l10n.sh`).
- A secret never goes into a log, a preference, a file name, a window title or an error message. Errors name the account, never the secret.
- No new dependencies without a discussion. Sparkle is the only one, and it lives in the app target.
- The app is sandboxed. A change to the entitlements needs a reason in the pull request and an update of the check in `scripts/release.sh`.

## Commits and pull requests

Use [Conventional Commits](https://www.conventionalcommits.org): `type(scope): subject`, for example `fix(core): reject a period of 0`. Types in use: `feat`, `fix`, `perf`, `docs`, `build`, `ci`, `chore` (plus `refactor` and `test` where they fit). Scopes in use: `core`, `app`, `release`, `build`. Write the subject in English or German, in the imperative, without a final period.

One pull request, one topic. Describe what changes for the user and how you checked it. Link the issue if there is one. A green CI run is required before merging.

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
