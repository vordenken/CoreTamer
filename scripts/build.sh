#!/bin/bash
set -euo pipefail
trap 'echo "ERROR: Universal build failed at line $LINENO. Check the diagnostic above." >&2' ERR
cd "$(dirname "$0")/.."

# semver.txt line 1 is the single source of truth for the release version.
version="$(head -n 1 semver.txt | tr -d '[:space:]')"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: semver.txt line 1 must be MAJOR.MINOR.PATCH (found '$version')." >&2
  exit 1
fi
if [[ -n "${BUILD_NUMBER:-}" && ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: BUILD_NUMBER must be a positive integer (found '$BUILD_NUMBER')." >&2
  exit 1
fi
identity="${CODE_SIGN_IDENTITY:--}"
settings=("CODE_SIGN_IDENTITY=$identity")
if [[ -n "${BUILD_NUMBER:-}" ]]; then settings+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER"); fi
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then settings+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"); fi
output="${OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"

# Build outside the checkout: cloud-synced folders add Finder metadata that breaks codesign.
derived="$(mktemp -d "${TMPDIR:-/tmp}/CoreTamer-build.XXXXXX")"
trap 'rm -rf "$derived"' EXIT
# Mapping the checkout and build paths to "." keeps usernames and folders out of the binaries.
xcodebuild -project CoreTamer.xcodeproj -scheme CoreTamer -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$version" \
  "${settings[@]}" DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES \
  OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $PWD=. -file-prefix-map $derived=." \
  OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$PWD=. -ffile-prefix-map=$derived=." \
  OTHER_LDFLAGS="\$(inherited) -Wl,-oso_prefix,$derived" \
  -quiet build

app="$derived/package/CoreTamer.app"
mkdir -p "$derived/package"
ditto --norsrc "$derived/Build/Products/Release/CoreTamer.app" "$app"
xattr -cr "$app"
# Sign inside out, preserving Sparkle's sandbox entitlements on its nested services.
signing=(--force --options runtime --sign "$identity")
if [[ "$identity" != "-" ]]; then signing+=(--timestamp); fi
framework="$app/Contents/Frameworks/Sparkle.framework"
codesign "${signing[@]}" "$framework/Versions/B/Autoupdate"
while IFS= read -r -d '' bundle; do
  codesign "${signing[@]}" --preserve-metadata=entitlements "$bundle"
done < <(find "$framework" -depth -type d \
  \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -print0)
codesign "${signing[@]}" "$app/Contents/Helpers/CoreTamerController"
codesign "${signing[@]}" "$app"
codesign --verify --deep --strict "$app"
for executable in "$app/Contents/MacOS/CoreTamer" "$app/Contents/Helpers/CoreTamerController"; do
  lipo -verify_arch arm64 "$executable"
  lipo -verify_arch x86_64 "$executable"
  file "$executable"
  if strings -a "$executable" | grep '/Users/' > /dev/null; then
    echo "ERROR: $executable embeds a local /Users/ path." >&2
    exit 1
  fi
done
# Exclude cloud/Finder extended attributes from the redistributable archive.
ditto -c -k --norsrc --keepParent "$app" "$derived/package/CoreTamer.zip"
# Replace only these named build products; never remove the output directory itself.
rm -rf "$output/CoreTamer.app"
ditto --norsrc "$app" "$output/CoreTamer.app"
cp "$derived/package/CoreTamer.zip" "$output/CoreTamer.zip"
xattr -cr "$output/CoreTamer.app"
if ! codesign --verify --deep --strict "$output/CoreTamer.app"; then
  echo "ERROR: Exported app failed verification. Try OUTPUT_DIR in a non-cloud-synced folder." >&2
  exit 1
fi
printf 'Built CoreTamer %s: %s\nRun: open "%s"\n' \
  "$version" "$output/CoreTamer.app" "$output/CoreTamer.app"
