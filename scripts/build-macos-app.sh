#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST_DIR="$REPO_ROOT/dist"
APP_DIR="$DIST_DIR/K-AI 설치.app"

if [[ -L "$DIST_DIR" || (-e "$DIST_DIR" && ! -d "$DIST_DIR") ]]; then
  printf 'refusing unsafe dist path\n' >&2
  exit 1
fi
mkdir -p "$DIST_DIR"
REPO_REAL=$(cd "$REPO_ROOT" && pwd -P)
DIST_REAL=$(cd "$DIST_DIR" && pwd -P)
if [[ "$DIST_REAL" != "$REPO_REAL/dist" ]]; then
  printf 'refusing dist path outside the repository\n' >&2
  exit 1
fi
if [[ -L "$APP_DIR" || (-e "$APP_DIR" && ! -d "$APP_DIR") ]]; then
  printf 'refusing unsafe app bundle path\n' >&2
  exit 1
fi

cd "$REPO_ROOT"
swift build -c release --product KAIInstallerApp
swift build -c release --product kai-installer-cli
BIN_DIR=$(swift build -c release --show-bin-path)

rm -rf -- "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
install -m 0755 "$BIN_DIR/KAIInstallerApp" "$APP_DIR/Contents/MacOS/KAIInstaller"
install -m 0644 "$REPO_ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
install -m 0755 "$BIN_DIR/kai-installer-cli" "$DIST_DIR/kai-installer-cli"

plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

printf 'Built: %s\n' "$APP_DIR"
