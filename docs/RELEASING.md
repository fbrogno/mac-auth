# Release

Ein Tag `vX.Y.Z` löst in GitHub Actions den Release aus: bauen, mit Developer ID signieren, bei Apple
notarisieren, DMG und Sparkle-Appcast ans GitHub-Release hängen. Installierte Apps holen sich das Update
von `releases/latest/download/appcast.xml`.

## Ablauf

1. Version in der Datei `VERSION` erhöhen (z. B. `1.1.0`), committen, per PR nach `main`.
2. Auf `main` den Tag setzen und pushen: `git tag v$(cat VERSION) && git push origin v$(cat VERSION)`.
3. Der Workflow `Release` bricht ab, wenn Tag und `VERSION` nicht übereinstimmen. Sonst entstehen
   `MacAuth-<Version>.dmg` und `appcast.xml` am Release, mit automatisch erzeugten Release-Notes. Dazu kommt
   `MacAuth.dmg`, eine byte-gleiche Kopie der DMG unter festem Namen: Der Link
   `https://github.com/fbrogno/mac-auth/releases/latest/download/MacAuth.dmg` im README zeigt dadurch immer auf die
   neueste Version. Der Appcast verweist weiter auf die versionierte Datei; die Kopie hat dieselbe Attestation
   (der Workflow nennt beide Dateien als Subject), und die `.sha256`-Datei nennt die versionierte Datei, der Hash ist derselbe.

Die Build-Nummer ist die Anzahl der Commits (`git rev-list --count HEAD`), Sparkle vergleicht sie.

Lokaler Probelauf ohne Apple-Server: `scripts/release.sh --skip-notarize`. Echter lokaler Lauf: zusätzlich
`NOTARY_PROFILE=<Schlüsselbund-Profil>` und `SPARKLE_USE_KEYCHAIN=1` setzen (Profil einmalig mit
`xcrun notarytool store-credentials`).

## Einmalige Einrichtung

Voraussetzungen: Developer-ID-Application-Zertifikat im Schlüsselbund, App-Store-Connect-API-Schlüssel
(`.p8`, Key-ID, Issuer-ID), `gh` angemeldet mit Schreibrecht auf das Repo.

```bash
./scripts/setup-release-secrets.sh
```

Das Skript legt zuerst das GitHub-Environment `release` an (falls es fehlt) und beschränkt es auf Tags `v*`.
Dann legt es MacAuths **eigenes** Sparkle-Schlüsselpaar im Login-Schlüsselbund an, nur wenn es noch keines gibt:
`generate_keys --account macauth`. Das Paar von MacMonitor wird bewusst nicht mitbenutzt: Sonst könnte ein
kompromittiertes Schwester-Repo MacAuth-Updates signieren, und nach dem ersten Release lässt sich der Schlüssel nur
noch per Rotation ändern. Das Skript und `release.sh` brechen ab, wenn der öffentliche Schlüssel dem von MacMonitor
entspricht. Der öffentliche Schlüssel kommt in `Config/Sparkle.xcconfig` (bis dahin leer; die App läuft ohne
Schlüssel, ihr Updater bleibt aus, und `release.sh` bricht ab). Das Skript bricht auch ab, wenn dort schon ein
anderer Schlüssel steht als der im Schlüsselbund. Die sechs Secrets liegen als **Environment-Secrets** von `release`
(nicht als Repo-Secrets); nur Jobs, die dieses Environment verwenden (also Tags `v*`), sehen sie:

| Secret | Inhalt |
|---|---|
| `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` | Zertifikat samt Schlüssel als .p12 (Base64) und dessen Zufallspasswort |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` | App-Store-Connect-API-Schlüssel für `notarytool` |
| `SPARKLE_PRIVATE_KEY` | privater EdDSA-Schlüssel, signiert die Updates im Appcast |

Ohne öffentlichen Schlüssel bricht `release.sh` ab, denn eine App ohne Schlüssel könnte keine Updates prüfen.

Der private Sparkle-Schlüssel darf nie verloren gehen: Ohne ihn lassen sich bestehende Installationen nicht
mehr aktualisieren. Sicherung einmalig nach der Einrichtung, in einen Passwortmanager:

```bash
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account macauth -x <Datei>
```

Die Datei danach löschen. Auf einem neuen Mac wiederherstellen mit `generate_keys --account macauth -f <Datei>`.
Lokale Läufe mit `SPARKLE_USE_KEYCHAIN=1` benutzen dasselbe Konto (`--account macauth` bei `sign_update` und
`generate_appcast`).

## Wie signiert wird

`scripts/build-app.sh` baut ohne Xcode-Signatur und signiert danach von innen nach außen, ohne `--deep`:
Sparkles XPC-Dienst, `Updater.app`, `Autoupdate`, das Framework, zuletzt die App, jeweils mit Hardened
Runtime und Zeitstempel. `release.sh` prüft das (`codesign --verify --deep --strict`, Developer-ID-Autorität,
Runtime-Flag, Zeitstempel für jede Komponente), baut die DMG (APFS, lzfse), signiert sie und notarisiert sie.

### App Sandbox und Sparkle

MacAuth läuft in der App Sandbox (`Resources/MacAuth.entitlements`): `app-sandbox`, `network.client`,
`device.camera`, `files.user-selected.read-write`. Sparkle ist danach eingerichtet, wie
[die Sparkle-Doku zur Sandbox](https://sparkle-project.org/documentation/sandboxing/) es verlangt:

- `SUEnableInstallerLauncherService = YES` in `Resources/Info.plist`: Sparkle installiert Updates über den
  Installer-XPC-Dienst außerhalb der Sandbox.
- Das Entitlement `com.apple.security.temporary-exception.mach-lookup.global-name` mit
  `com.fbrogno.macauth-spks` und `com.fbrogno.macauth-spki` (`$(PRODUCT_BUNDLE_IDENTIFIER)-spks`/`-spki`).
  `codesign` ersetzt keine Build-Variablen, deshalb steht die Bundle-ID ausgeschrieben in der Datei;
  `build-app.sh` und `release.sh` prüfen, dass sie zur Bundle-ID der App passt.
- Den Downloader-Dienst braucht die App nicht (die Doku: nur ohne `network.client`), `SUEnableDownloaderService`
  bleibt aus, und `build-app.sh` entfernt `Downloader.xpc` aus dem Framework.
- Signiert wird in der Reihenfolge der Doku, mit Hardened Runtime und ohne `--deep`: `Installer.xpc`
  (mit `--preserve-metadata=entitlements`, Sparkle 2.6+), `Autoupdate`, `Updater.app`, `Sparkle.framework`; die App
  zuletzt mit der Entitlements-Datei.

`release.sh` verlangt zusätzlich: genau diese vier Entitlements plus die Sparkle-Ausnahme und sonst keine
(kein `get-task-allow`, kein `disable-library-validation`), Sandbox aktiv, `NSCameraUsageDescription` gesetzt,
kein `LSUIElement`, kein `Downloader.xpc`. Die Entitlements gelten für das Developer-ID-Profil; die Sandbox
braucht kein Provisioning-Profil, solange kein Data-Protection-Schlüsselbund und keine App-Gruppe verwendet wird.

Ad-hoc-Builds (CI, `SIGN_IDENTITY=-`) tragen dieselben Entitlements, aber ohne Hardened Runtime und Zeitstempel.

### Symbol

`scripts/make-icon.sh` zeichnet das Symbol programmgesteuert (`scripts/make-icon.swift`) und schreibt
`Resources/AppIcon.icns`; das 1024er-PNG liegt danach unter `build/icon-1024.png`.

### Release-Job und Abhängigkeiten

- Werkzeuge werden im Release-Job **vor** dem Zertifikat-Import installiert. XcodeGen ist fest auf eine Version gesetzt
  (Release-ZIP von GitHub, SHA-256 wird geprüft), kein ungepinntes `brew install`. Dieselbe Prüfung läuft in `ci.yml`.
- Das Zertifikat kommt in einen temporären Schlüsselbund, nur `/usr/bin/codesign` darf den Schlüssel nutzen
  (`-T /usr/bin/codesign`, dazu `set-key-partition-list`); der Schlüsselbund wird am Ende immer gelöscht (`if: always()`).
- Sparkle ist in `project.yml` auf den Commit des Tags 2.10.1 festgelegt (`revision:`), nicht nur auf die Version.
  Beim Wechsel: `git ls-remote https://github.com/sparkle-project/Sparkle 'refs/tags/<Version>'` und Commit samt Versionskommentar tauschen.
- Actions sind auf Commit-SHAs gepinnt; Dependabot (`.github/dependabot.yml`) schlägt wöchentlich neue SHAs vor.
  Einen CodeQL-Workflow gibt es nicht: Die Swift-Analyse braucht macOS-Runner und einen vollständigen Xcode-Build,
  und der sicherheitsrelevante Code (`AuthCore`) ist klein und durch Tests abgedeckt; das lohnt den Aufwand nicht.

## Release prüfen

Jeder Release enthält `MacAuth-<Version>.dmg`, `MacAuth-<Version>.dmg.sha256`, `appcast.xml` und `MacAuth.dmg` (Kopie
der versionierten DMG, siehe oben). Die DMGs haben eine
Build-Provenance-Attestation (GitHub Actions, Sigstore). Prüfen, dass eine heruntergeladene DMG aus diesem Repo
und diesem Workflow stammt:

```bash
gh attestation verify MacAuth-<Version>.dmg --repo fbrogno/mac-auth
shasum -a 256 -c MacAuth-<Version>.dmg.sha256          # oder: shasum -a 256 MacAuth-<Version>.dmg, Vergleich mit den Release-Notes
spctl -a -vv -t open --context context:primary-signature MacAuth-<Version>.dmg
codesign -dv --verbose=4 MacAuth-<Version>.dmg         # Authority=Developer ID Application, Timestamp, Team-ID
```

Nach dem Einhängen der DMG dasselbe für die App: `codesign -dv --verbose=4 /Volumes/MacAuth/MacAuth.app`
(Flags `runtime`) und `spctl -a -vv /Volumes/MacAuth/MacAuth.app` (`source=Notarized Developer ID`).

## Texte

`scripts/check-l10n.sh` prüft, dass jeder Schlüssel in den `.xcstrings`-Katalogen (`Sources/`, dazu
`Resources/InfoPlist.xcstrings` für Kameratext und App-Name) auf Deutsch und Englisch übersetzt ist.
`scripts/l10n-sync.sh` gleicht die Kataloge mit dem Code ab.

## Zertifikat läuft ab

Das Developer-ID-Application-Zertifikat läuft am **01.02.2027** ab. Danach kann der Release-Workflow nicht mehr
signieren. Rechtzeitig vorher:

1. Im Apple-Developer-Konto ein neues Developer-ID-Application-Zertifikat anlegen und in den Schlüsselbund laden.
2. `./scripts/setup-release-secrets.sh` erneut ausführen. Es ersetzt `DEVELOPER_ID_P12_BASE64` und
   `DEVELOPER_ID_P12_PASSWORD` im Environment.
3. Einen Probelauf mit `scripts/release.sh --skip-notarize` machen, dann den nächsten Tag setzen.

Bereits veröffentlichte Versionen laufen weiter: Gatekeeper prüft die Notarisierung und den Zeitstempel zum
Signierzeitpunkt, nicht das heutige Datum des Zertifikats. Auch Sparkle-Updates bleiben gültig, denn sie
hängen am EdDSA-Schlüssel, nicht am Zertifikat.

## Empfohlene Repo-Einstellungen

Diese Einstellungen liegen in GitHub und nicht im Repo; sie schützen die Release-Secrets:

- **Environment `release`** (Settings → Environments): Der Release-Job verweist darauf (`environment: release`).
  Dort „Required reviewers“ setzen, damit jeder Release freigegeben werden muss, und unter „Deployment branches
  and tags“ nur Tags `v*` zulassen. Die Secrets setzt `setup-release-secrets.sh` bereits als Secrets dieses Environments.
- **Tag-Schutz für `v*`** (Settings → Rules → Rulesets, Ziel „Tags“, Muster `v*`): Nur Maintainer dürfen
  Release-Tags anlegen, ändern oder löschen. Ein Tag löst den signierten Release aus; ohne Schutz könnte
  ihn jeder mit Schreibrecht auslösen oder einen veröffentlichten Tag umbiegen.
- Branch-Schutz für `main`: Pull Request und grüner Check `CI` vor dem Merge.
