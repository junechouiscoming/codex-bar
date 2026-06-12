#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexBar"
VERSION="${1:-1.0}"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
RELEASE_DIR="$ROOT_DIR/release"
STAGING_DIR="$ROOT_DIR/.build/dmg/$APP_NAME-$VERSION"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-arm64.dmg"

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT_DIR/scripts/build-app.sh"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$RELEASE_DIR"

ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "Built $DMG_PATH"
