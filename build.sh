#!/bin/zsh
# Builds Aura and installs it to /Applications.
#   ./build.sh            build + install + launch
#   ./build.sh --no-open  build + install only
#
# Needs: Xcode (26 or newer) and XcodeGen (`brew install xcodegen`).
# Set XCODE_PATH if the Xcode you want isn't the one `xcode-select` points at,
# e.g. XCODE_PATH=/Applications/Xcode-beta.app ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

[[ -n "${XCODE_PATH:-}" ]] && export DEVELOPER_DIR="$XCODE_PATH/Contents/Developer"
# Outside the source tree, or codesign trips on Finder metadata.
DERIVED="${AURA_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Aura-cli}"

xcodegen generate --quiet
xcodebuild -project Aura.xcodeproj -scheme Aura -configuration Release -derivedDataPath "$DERIVED" build \
  | grep -E "error:|warning: .*Sources|BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/Release/Aura.app"
[[ -d "$APP" ]] || { echo "build failed"; exit 1; }

pkill -x Aura 2>/dev/null || true
[[ -d /Applications/Aura.app ]] && rm -rf /Applications/Aura.app
ditto "$APP" /Applications/Aura.app

# Sign with a local Apple Development certificate when there is one, so macOS remembers the
# Spotify + audio permissions across rebuilds (ad-hoc signatures change every build, which
# makes macOS ask again each time). Falls back to ad-hoc signing.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --entitlements Support/Aura.entitlements /Applications/Aura.app
echo "Installed /Applications/Aura.app (signed with ${IDENTITY:-ad-hoc})"

[[ "${1:-}" == "--no-open" ]] || open /Applications/Aura.app
