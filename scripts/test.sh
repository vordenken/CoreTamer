#!/bin/bash
set -euo pipefail
trap 'echo "ERROR: Validation failed at line $LINENO. Check the diagnostic above." >&2' ERR
cd "$(dirname "$0")/.."

# --unit-only skips the timing-based CPU workload tests and the coverage gate, which
# depend on spare CPU capacity that shared CI runners cannot guarantee.
unit_only=false
case "${1:-}" in
  "") ;;
  --unit-only) unit_only=true ;;
  *)
    echo "ERROR: Unknown option '$1'. Usage: bash scripts/test.sh [--unit-only]" >&2
    exit 2
    ;;
esac

xcrun swift-format lint --strict --recursive CoreTamer CoreTamerCore CoreTamerTests \
  scripts/generate-icon.swift
bash -n scripts/build.sh scripts/test.sh scripts/release.sh
xmllint --noout appcast.xml
# Release pipeline: the appcast updater must keep stable entries and prune old betas.
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests

# Keep build products outside the checkout: cloud-synced folders break codesign.
work="$(mktemp -d "${TMPDIR:-/tmp}/CoreTamer-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# The analyzer writes one report file per input, so run it inside the scratch folder.
(cd "$work" && xcrun clang --analyze -I "$OLDPWD/ProcessControl/include" \
  "$OLDPWD/ProcessControl/ProcessControl.c" "$OLDPWD/CoreTamerController/main.c" \
  -Xanalyzer -analyzer-output=text)
# A busy multi-threaded workload enables the real CPU-limiting integration tests.
xcrun clang -Wall -Wextra -Werror -O2 -pthread CoreTamerTests/Fixtures/BusyThreads.c \
  -o "$work/BusyThreads"

arch="$(uname -m)"
xcodebuild -project CoreTamer.xcodeproj -scheme CoreTamer -configuration Debug \
  -destination "platform=macOS,arch=$arch" -derivedDataPath "$work/DerivedData" \
  -enableCodeCoverage YES -quiet build-for-testing
xctestrun="$(find "$work/DerivedData/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -n 1)"
if [[ -z "$xctestrun" ]]; then
  echo "ERROR: build-for-testing produced no .xctestrun file in $work/DerivedData." >&2
  exit 1
fi
if [[ "$unit_only" == false ]]; then
  # Hosted tests only see variables from the test run description, so add the workload there.
  /usr/bin/plutil -insert CoreTamerTests.EnvironmentVariables.CORE_TAMER_TEST_WORKLOAD \
    -string "$work/BusyThreads" "$xctestrun"
fi
# Pin the host app's language so local machines and CI runners resolve the same UI strings.
/usr/bin/plutil -replace CoreTamerTests.CommandLineArguments \
  -json '["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]' "$xctestrun"
if ! xcodebuild -xctestrun "$xctestrun" -destination "platform=macOS,arch=$arch" \
  -resultBundlePath "$work/TestResults.xcresult" -quiet test-without-building; then
  # -quiet hides Swift Testing issues; print them from the result bundle for CI logs.
  xcrun xcresulttool get test-results summary --path "$work/TestResults.xcresult" \
    | /usr/bin/python3 -c '
import json
import sys

for failure in json.load(sys.stdin).get("testFailures", []):
    name = failure.get("testName")
    text = failure.get("failureText")
    print(f"FAILED {name}: {text}", file=sys.stderr)
' || true
  echo "ERROR: Xcode tests failed. See the failures above." >&2
  exit 1
fi

if [[ "$unit_only" == true ]]; then
  echo "Unit tests passed. Workload tests and the coverage gate were skipped (--unit-only)."
  exit 0
fi

# Production code: the app, its static core library, and the embedded controller helper.
xcrun xccov view --report --json "$work/TestResults.xcresult" > "$work/coverage.json"
/usr/bin/python3 - "$work/coverage.json" <<'PY'
import json
import sys

targets = json.load(open(sys.argv[1]))["targets"]
production = [t for t in targets if not t["name"].endswith(".xctest")]
for target in production:
    print(f'{target["name"]}: {100 * target["lineCoverage"]:.2f}%')
covered = sum(t["coveredLines"] for t in production)
executable = sum(t["executableLines"] for t in production)
percent = 100 * covered / executable
print(f"Production line coverage: {percent:.2f}% ({covered}/{executable} lines)")
if percent <= 80:
    sys.exit("ERROR: Production line coverage must exceed 80%.")
PY
