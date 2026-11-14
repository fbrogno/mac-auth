#!/bin/zsh
# Builds build/MacAuth.app (Release) from project.yml via XcodeGen + xcodebuild.
#
# Signing is done here, not by Xcode, so Sparkle's nested code is signed from the inside out
# (XPC services, Updater.app, Autoupdate, framework, app) without --deep, as the Sparkle sandboxing
# guide asks for: https://sparkle-project.org/documentation/sandboxing/
#
# The app is sandboxed (Resources/MacAuth.entitlements). Sparkle's Installer.xpc and the helpers keep the
# entitlements they ship with (--preserve-metadata=entitlements), the app gets the entitlement file.
# Sparkle's Downloader.xpc is removed: with com.apple.security.network.client the app downloads itself.
#
# SIGN_IDENTITY  "-" = ad-hoc, otherwise a keychain identity (name or SHA-1).
#                Default: "Developer ID Application", else "Apple Development", else ad-hoc.
# VERSION        Marketing version comes from the VERSION file, build number from the commit count.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen fehlt (brew install xcodegen)." >&2; exit 1; }

version=$(<VERSION)
version=${version//[[:space:]]/}
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

# --- signing identity -------------------------------------------------------------------
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
pick() { print -r -- "$identities" | awk -v kind="$1" -F'"' '$2 ~ "^" kind {split($1, a, " "); print a[2]; exit}'; }
identity=${SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  identity=$(pick "Developer ID Application")
  [[ -n $identity ]] || identity=$(pick "Apple Development")
  [[ -n $identity ]] || identity="-"
fi
if [[ $identity == "-" ]]; then
  kind="ad-hoc"
else
  name=$(print -r -- "$identities" | awk -v id="$identity" -F'"' 'index($1, id) {print $2; exit}')
  [[ -n $name ]] || name=$identity
  case $name in
    "Developer ID Application"*) kind="Developer ID" ;;
    "Apple Development"*) kind="Apple Development" ;;
    *) kind=$name ;;
  esac
fi

# --- build ------------------------------------------------------------------------------
xcodegen generate --quiet
xcodebuild -project MacAuth.xcodeproj -scheme MacAuth -configuration Release \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  -quiet build

app=build/MacAuth.app
rm -rf "$app"
ditto build/DerivedData/Build/Products/Release/MacAuth.app "$app"

# The entitlements must name this app's own Sparkle services (<bundle id>-spks / -spki).
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
plutil -lint Resources/MacAuth.entitlements >/dev/null
for suffix in spks spki; do
  grep -q "<string>$bundle_id-$suffix</string>" Resources/MacAuth.entitlements \
    || { echo "Resources/MacAuth.entitlements: mach-lookup-Eintrag $bundle_id-$suffix fehlt." >&2; exit 1; }
done

# --- sparkle: drop the downloader service (not needed with network.client) -------------------
for fw in "$app"/Contents/Frameworks/Sparkle.framework(N); do
  for v in "$fw"/Versions/[A-Z](N); do rm -rf "$v/XPCServices/Downloader.xpc"; done
done

# --- sign, innermost first ---------------------------------------------------------------
sign_args=(--force --sign "$identity")
if [[ $identity == "-" ]]; then
  # Library validation would refuse ad-hoc signed frameworks, so no hardened runtime here.
  sign_args+=(--timestamp=none)
elif [[ $kind == "Developer ID" ]]; then
  sign_args+=(--options runtime --timestamp)
else
  sign_args+=(--options runtime --timestamp=none)
fi
sign() { codesign "${sign_args[@]}" --preserve-metadata=entitlements "$@"; }

for fw in "$app"/Contents/Frameworks/*.framework(N); do
  for v in "$fw"/Versions/[A-Z](N); do
    for xpc in "$v"/XPCServices/*.xpc(N); do sign "$xpc"; done
    [[ -d $v/Updater.app ]] && sign "$v/Updater.app"
    [[ -f $v/Autoupdate ]] && sign "$v/Autoupdate"
  done
  sign "$fw"
done
codesign "${sign_args[@]}" --entitlements Resources/MacAuth.entitlements "$app"

codesign --verify --deep --strict "$app"
echo "Gebaut: $app $version ($build), signiert: $kind"
