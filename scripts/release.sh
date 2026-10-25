#!/bin/bash
set -euo pipefail
trap 'echo "ERROR: Release step failed at line $LINENO. Check the diagnostic above." >&2' ERR
cd "$(dirname "$0")/.."

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

case "${1:-}" in
  check)
    : "${ACTOR:?}" "${EVENT_NAME:?}" "${REF_NAME:?}" "${GITHUB_OUTPUT:?}"
    case "$ACTOR" in
      "github-actions[bot]"|"coretamer-ci-bot"|"coretamer-ci-bot[bot]")
        echo "should-build=false" >> "$GITHUB_OUTPUT"
        exit 0
        ;;
    esac
    case "$REF_NAME" in
      main|feature/*) ;;
      *) fail "Releases require main or feature/* (found '$REF_NAME')." ;;
    esac
    should_build=true
    if [[ "$EVENT_NAME" != workflow_dispatch && "$REF_NAME" == main \
      && "${BEFORE:-}" != 0000000000000000000000000000000000000000 ]]; then
      : "${BEFORE:?}" "${HEAD_SHA:?}"
      if git diff --quiet "$BEFORE" "$HEAD_SHA" -- semver.txt; then
        should_build=false
      else
        status=$?
        [[ "$status" == 1 ]] || fail "Cannot compare $BEFORE with $HEAD_SHA."
      fi
    fi
    echo "should-build=$should_build" >> "$GITHUB_OUTPUT"
    ;;
  prepare)
    : "${REF_NAME:?}" "${RUN_NUMBER:?}" "${GITHUB_SHA:?}" "${GITHUB_OUTPUT:?}" "${RUNNER_TEMP:?}"
    version="$(head -n 1 semver.txt | tr -d '[:space:]')"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid version '$version' in semver.txt."
    [[ "$RUN_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "RUN_NUMBER must be a positive integer."
    # Filter tag output in Bash: version dots must be literal, and no-match is not a Git error.
    case "$REF_NAME" in
      main)
        tag="v$version"
        channel=stable
        prerelease=false
        ;;
      feature/*)
        latest=0
        retry=0
        tags="$(git tag -l "v$version-beta*")"
        for candidate in $tags; do
          number="${candidate#"v$version-beta"}"
          [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
          if (( number > latest )); then latest="$number"; fi
          if [[ "$(git rev-list -n 1 "$candidate")" == "$GITHUB_SHA" ]] && (( number > retry )); then
            retry="$number"
          fi
        done
        if (( retry > 0 )); then number="$retry"; else number=$((latest + 1)); fi
        tag="v$version-beta$number"
        channel=beta
        prerelease=true
        ;;
      *) fail "Releases require main or feature/* (found '$REF_NAME')." ;;
    esac
    if git show-ref --verify --quiet "refs/tags/$tag"; then
      [[ "$(git rev-list -n 1 "$tag")" == "$GITHUB_SHA" ]] \
        || fail "Tag $tag belongs to a different commit; refusing to move it."
    fi
    awk '
      /^---$/ { found = 1; next }
      /^## [0-9]+\.[0-9]+\.[0-9]+$/ { exit }
      found { print }
    ' semver.txt > "$RUNNER_TEMP/changelog.txt"
    [[ -s "$RUNNER_TEMP/changelog.txt" ]] || fail "semver.txt has no current release notes after ---."
    {
      echo "version=$version"
      echo "tag=$tag"
      echo "channel=$channel"
      echo "prerelease=$prerelease"
      echo "build=$((RUN_NUMBER + 10))"
    } >> "$GITHUB_OUTPUT"
    ;;
  package)
    : "${RUNNER_TEMP:?}" "${OUTPUT_DIR:?}" "${CREATE_DMG_VERSION:?}" "${CODE_SIGN_IDENTITY:?}"
    [[ -d "$OUTPUT_DIR/CoreTamer.app" ]] || fail "Build $OUTPUT_DIR/CoreTamer.app first."
    archive="$RUNNER_TEMP/create-dmg.tar.gz"
    curl --fail --location --silent --show-error \
      "https://github.com/create-dmg/create-dmg/archive/refs/tags/v${CREATE_DMG_VERSION}.tar.gz" \
      --output "$archive"
    tar -xzf "$archive" -C "$RUNNER_TEMP"
    bash "$RUNNER_TEMP/create-dmg-${CREATE_DMG_VERSION}/create-dmg" \
      --volname "CoreTamer" --window-pos 200 120 --window-size 600 400 \
      --icon-size 100 --icon "CoreTamer.app" 175 190 --app-drop-link 425 190 \
      "$RUNNER_TEMP/CoreTamer.dmg" "$OUTPUT_DIR/CoreTamer.app"
    codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$RUNNER_TEMP/CoreTamer.dmg"
    codesign --verify --strict "$RUNNER_TEMP/CoreTamer.dmg"
    ;;
  sign)
    : "${RUNNER_TEMP:?}" "${SPARKLE_VERSION:?}" "${SPARKLE_PRIVATE_KEY:?}"
    : "${VERSION:?}" "${TAG:?}" "${BUILD:?}" "${CHANNEL:?}"
    dmg="$RUNNER_TEMP/CoreTamer.dmg"
    [[ -f "$dmg" ]] || fail "Package $dmg first."
    # The signer must match the resolved framework, not just the SwiftPM minimum.
    pinned="$(/usr/bin/plutil -extract pins.0.state.version raw -o - \
      CoreTamer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)"
    [[ "$pinned" == "$SPARKLE_VERSION" ]] || fail "SPARKLE_VERSION $SPARKLE_VERSION differs from pin $pinned."
    curl --fail --location --silent --show-error \
      "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
      --output "$RUNNER_TEMP/sparkle.tar.xz"
    mkdir -p "$RUNNER_TEMP/sparkle"
    tar -xJf "$RUNNER_TEMP/sparkle.tar.xz" -C "$RUNNER_TEMP/sparkle"
    # Never put the private key in argv, logs, or the checkout; remove it even on failure.
    key_file="$(mktemp "$RUNNER_TEMP/sparkle-key.XXXXXX")"
    trap 'rm -f "$key_file"' EXIT
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" > "$key_file"
    if ! signature_output="$("$RUNNER_TEMP/sparkle/bin/sign_update" "$dmg" --ed-key-file "$key_file")"; then
      fail "Sparkle could not sign CoreTamer.dmg. Check SPARKLE_PRIVATE_KEY."
    fi
    signature="$(printf '%s\n' "$signature_output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
    [[ -n "$signature" ]] || fail "Sparkle did not return an EdDSA signature."
    # Work on a copy so local preparation never changes the canonical feed.
    cp appcast.xml "$RUNNER_TEMP/appcast.xml"
    python3 scripts/update_appcast.py \
      --appcast "$RUNNER_TEMP/appcast.xml" --changelog "$RUNNER_TEMP/changelog.txt" \
      --version "$VERSION" --tag "$TAG" --build "$BUILD" --channel "$CHANNEL" \
      --signature "$signature" --length "$(stat -f%z "$dmg")"
    xmllint --noout "$RUNNER_TEMP/appcast.xml"
    ;;
  notes)
    : "${RUNNER_TEMP:?}" "${PRERELEASE:?}"
    [[ -f "$RUNNER_TEMP/changelog.txt" ]] || fail "Run prepare before notes."
    {
      if [[ "$PRERELEASE" == true ]]; then
        printf '> [!WARNING]\n> **This is a beta release.** It may be unstable or incomplete.\n\n'
      fi
      printf '## Changelog\n\n'
      cat "$RUNNER_TEMP/changelog.txt"
      cat <<'INSTALLATION'

## Installation

This release is not notarized by Apple. After downloading `CoreTamer.dmg`,
macOS may require **System Settings > Privacy & Security > Open Anyway**
for both the disk image and the app. Copy CoreTamer to Applications and open it.
CoreTamer lives in the menu bar, not the Dock.
INSTALLATION
    } > "$RUNNER_TEMP/release_notes.md"
    ;;
  *)
    fail "Usage: bash scripts/release.sh {check|prepare|package|sign|notes}"
    ;;
esac
