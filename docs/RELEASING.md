# Release

Ein Tag `vX.Y.Z` löst in GitHub Actions den Release aus: bauen, mit Developer ID signieren, bei Apple
notarisieren, DMG und Sparkle-Appcast ans GitHub-Release hängen. Installierte Apps holen sich das Update
von `releases/latest/download/appcast.xml`.

## Ablauf

1. Version in der Datei `VERSION` erhöhen (z. B. `1.1.0`), committen, per PR nach `main`.
2. Auf `main` den Tag setzen und pushen: `git tag v$(cat VERSION) && git push origin v$(cat VERSION)`.
3. Der Workflow `Release` bricht ab, wenn Tag und `VERSION` nicht übereinstimmen. Sonst entstehen
   `MacAuth-<Version>.dmg` und `appcast.xml` am Release, mit automatisch erzeugten Release-Notes.

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

Das Skript legt das Sparkle-Schlüsselpaar nur an, wenn der Schlüsselbund noch keines hat (`generate_keys`).
MacAuth verwendet dasselbe Paar wie MacMonitor; der öffentliche Schlüssel steht in `Config/Sparkle.xcconfig`.
Das Skript bricht ab, wenn der Schlüssel im Schlüsselbund nicht zu dem in `Config/Sparkle.xcconfig` passt.
Es setzt diese Secrets im Repo:

| Secret | Inhalt |
|---|---|
| `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` | Zertifikat samt Schlüssel als .p12 (Base64) und dessen Zufallspasswort |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` | App-Store-Connect-API-Schlüssel für `notarytool` |
| `SPARKLE_PRIVATE_KEY` | privater EdDSA-Schlüssel, signiert die Updates im Appcast |

Ohne öffentlichen Schlüssel bricht `release.sh` ab, denn eine App ohne Schlüssel könnte keine Updates prüfen.

Der private Sparkle-Schlüssel darf nie verloren gehen: Ohne ihn lassen sich bestehende Installationen nicht
mehr aktualisieren. Sicherung per `generate_keys -x <Datei>` in einen Passwortmanager.

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

## Texte

`scripts/check-l10n.sh` prüft, dass jeder Schlüssel in den `.xcstrings`-Katalogen (`Sources/`, dazu
`Resources/InfoPlist.xcstrings` für Kameratext und App-Name) auf Deutsch und Englisch übersetzt ist.
`scripts/l10n-sync.sh` gleicht die Kataloge mit dem Code ab.

## Zertifikat läuft ab

Das Developer-ID-Application-Zertifikat läuft am **01.02.2027** ab. Danach kann der Release-Workflow nicht mehr
signieren. Rechtzeitig vorher:

1. Im Apple-Developer-Konto ein neues Developer-ID-Application-Zertifikat anlegen und in den Schlüsselbund laden.
2. `./scripts/setup-release-secrets.sh` erneut ausführen. Es ersetzt `DEVELOPER_ID_P12_BASE64` und
   `DEVELOPER_ID_P12_PASSWORD` im Repo.
3. Einen Probelauf mit `scripts/release.sh --skip-notarize` machen, dann den nächsten Tag setzen.

Bereits veröffentlichte Versionen laufen weiter: Gatekeeper prüft die Notarisierung und den Zeitstempel zum
Signierzeitpunkt, nicht das heutige Datum des Zertifikats. Auch Sparkle-Updates bleiben gültig, denn sie
hängen am EdDSA-Schlüssel, nicht am Zertifikat.

## Empfohlene Repo-Einstellungen

Diese Einstellungen liegen in GitHub und nicht im Repo; sie schützen die Release-Secrets:

- **Environment `release`** (Settings → Environments): Der Release-Job verweist darauf (`environment: release`).
  Dort „Required reviewers“ setzen, damit jeder Release freigegeben werden muss, und unter „Deployment branches
  and tags“ nur Tags `v*` zulassen. Die Secrets setzt `setup-release-secrets.sh` als Repo-Secrets; wer sie lieber
  nur im Environment hält, verschiebt sie dorthin.
- **Tag-Schutz für `v*`** (Settings → Rules → Rulesets, Ziel „Tags“, Muster `v*`): Nur Maintainer dürfen
  Release-Tags anlegen, ändern oder löschen. Ein Tag löst den signierten Release aus; ohne Schutz könnte
  ihn jeder mit Schreibrecht auslösen oder einen veröffentlichten Tag umbiegen.
- Branch-Schutz für `main`: Pull Request und grüner Check `CI` vor dem Merge.
