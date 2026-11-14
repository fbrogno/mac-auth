#!/bin/zsh
# Builds, installs to /Applications (or ~/Applications) and starts MacAuth.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
target=/Applications
[[ -w $target ]] || { target=$HOME/Applications; mkdir -p "$target"; }

osascript -e 'tell application id "com.fbrogno.macauth" to quit' 2>/dev/null || true
sleep 1
rm -rf "$target/MacAuth.app"
cp -R build/MacAuth.app "$target/"
open "$target/MacAuth.app"
echo "Installiert nach $target/MacAuth.app und gestartet."
