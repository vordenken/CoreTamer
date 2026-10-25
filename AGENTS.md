# AGENTS.md

Operational guidance for coding agents working on **CoreTamer**. This file
complements `README.md`, `BUILD.md`, and `CONTRIBUTING.md`. Read it before
changing code, process control, release automation, or persistent settings.

> **Language:** Write code, identifiers, comments, feature scenarios, commit
> messages, issues, and pull requests in English. Maintainer-facing conversation
> may use the language chosen by the maintainer.

---

## 1. Project Overview

CoreTamer is a native **macOS menu-bar app** that limits the CPU usage of
individual processes. It ships as a universal app (arm64 + x86_64), targets
macOS 14 and later, and uses the bundle identifier `com.vd.CoreTamer`.

The Xcode project contains the app, a static core library, a C helper, and a
hosted test target. The shared scheme `CoreTamer` builds, runs, and tests
everything:

```text
CoreTamer/                                # SwiftUI/AppKit menu-bar app
  App/CoreTamerApp.swift                  # App, AppDelegate, AppModel (state, limits, persistence)
  App/MenuBarGlyph.swift                  # Menu-bar icon drawing
  App/UpdateController.swift              # Sparkle wrapper and beta channel
  Views/TamerView.swift                   # Process table, limit controls, settings
  Resources/Info.plist                    # Bundle and Sparkle keys
  Assets.xcassets                         # App icon (scripts/generate-icon.swift)

CoreTamerCore/                            # Static library
  Processes.swift                         # Process listing, sampling, grouping, sorting
  Limiter.swift                           # Launches and drives CoreTamerController

CoreTamerController/main.c                # Helper: SIGSTOP/SIGCONT duty cycle and watchdog
ProcessControl/                           # C module: libproc, identity checks, timebase
CoreTamerTests/                           # Swift Testing unit, view, and controller tests
CoreTamerTests/Fixtures/BusyThreads.c     # Disposable CPU workload for integration tests
tests/                                    # Python release-pipeline tests
features/cpu-limits.feature               # Gherkin behavior specification
scripts/build.sh                          # Universal build, signing, and ZIP
scripts/test.sh                           # Lint, analysis, tests, coverage gate
scripts/release.sh                        # Release steps used by the workflow (DMG)
scripts/update_appcast.py                 # Structured Sparkle feed updater
.github/workflows/tests.yml               # Pull-request and branch tests
.github/workflows/build-release.yml       # Beta and stable publishing
```

Important constraints:

- Both architectures must keep working; never add Intel-only or arm64-only code
  without a fallback.
- CoreTamer only throttles processes of the current user. Root, PID 1, itself,
  and its parent are never limited.
- The app makes no network requests except Sparkle update checks and downloads
  from GitHub. There is no telemetry.
- Sparkle is the only Swift package dependency and is resolved through SwiftPM.
- See `PRIVACY.md` before changing data handling or persisted settings.

---

## 2. Local Setup and Commands

| Purpose | Command |
| ------- | ------- |
| Clone and open | `git clone https://github.com/vordenken/CoreTamer.git && cd CoreTamer && open CoreTamer.xcodeproj` |
| Resolve Swift packages | `xcodebuild -resolvePackageDependencies -project CoreTamer.xcodeproj -scheme CoreTamer` |
| Full validation | `bash scripts/test.sh` (lint, analyzer, Python and Xcode tests, coverage > 80 %) |
| CI validation | `bash scripts/test.sh --unit-only` (skips CPU workload tests and the coverage gate) |
| Python release tests | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests` |
| Format Swift | `xcrun swift-format format --in-place --recursive CoreTamer CoreTamerCore CoreTamerTests` |
| Validate workflows | `actionlint` |
| Validate the appcast | `xmllint --noout appcast.xml` |
| Universal build | `bash scripts/build.sh` (app and ZIP in `dist/`, override with `OUTPUT_DIR`) |
| Regenerate the app icon | `swift scripts/generate-icon.swift` |
| Encode a signing certificate | `base64 -i certificate.p12 \| pbcopy` |

In Xcode: open `CoreTamer.xcodeproj`, scheme `CoreTamer`, Run (⌘R) or Test (⌘U).
Scripts are not executable; always run them with `bash`. New source files in the
synchronized folders are picked up automatically; `ProcessControl/` is a regular
group compiled into both `CoreTamerCore` and `CoreTamerController`.

---

## 3. Architecture and State

- `AppModel` in `CoreTamerApp.swift` owns the process list, selection, limits,
  and settings, and starts one `Limiter` per limited process or group.
- `Limiter` launches the embedded `CoreTamerController` helper with the target
  PID and percentage. With `--group`, one shared budget covers an app and its
  helper processes; members are updated over the controller's pipe.
- `CoreTamerController` validates the target identity (`ap_validate_target`),
  runs the `SIGSTOP`/`SIGCONT` duty cycle, and forks a watchdog that resumes all
  targets when the app or helper exits unexpectedly.
- `ProcessControl` wraps `libproc`, process identity (PID plus start time),
  responsibility lookup, and the kernel timebase for both architectures.
- `UpdateController.swift` owns Sparkle preferences and allowed beta channels.
- Settings are stored in `UserDefaults` under `com.vd.CoreTamer`:
  `showBackground`, `groupByType`, `pauseListOnHover`, `updateSpeed`,
  `restoreLimits`, `savedLimits`, `savedGroupLimits`, `hasCompletedOnboarding`, and
  `BetaUpdatesEnabled`.

Treat `UserDefaults` keys and the controller's command-line and pipe protocol as
contracts. Changes may require migration logic and coordinated edits on both
sides.

---

## 4. Branches, Commits, and Releases

### Branches

- `main` is stable. A push releases only when `semver.txt` changed.
- A release-relevant push to `feature/*` creates the next immutable beta tag,
  `vX.Y.Z-betaN`.
- Documentation-only, repository-metadata, test-only, and generated appcast
  changes do not trigger a release.
- Other branch names (`bugfix/*`, `hotfix/*`) do not trigger the release
  workflow. Use `feature/*` when a beta build is required.
- Long-lived branches should fetch and merge `origin/main` regularly because the
  release bot advances `main` with appcast commits.

### Commits and Pull Requests

- Use a short imperative subject, preferably no longer than 72 characters.
- Conventional Commits are welcome but not required.
- Keep each commit focused on one logical change.
- Open pull requests against `main`; do not commit directly to `main`.
- Explain what changed and why. Include screenshots or recordings for UI work.
- Obtain maintainer review before merging.

### Version Source of Truth

`semver.txt` contains the release version and changelog:

```text
X.Y.Z
---
### Section
- Current release entry

## X.Y.(Z-1)
- Previous release history
```

- Line 1 must be strict `X.Y.Z` SemVer.
- `---` starts the current release notes.
- A heading matching `## X.Y.Z` starts historical notes.
- Preserve all historical sections; do not add a separate changelog.
- User-visible changes need an entry in `semver.txt`.
- Keep `MARKETING_VERSION` in the Xcode project in sync with `semver.txt`.
- Do not edit build numbers for individual CI runs; the workflow injects them.
  Keep the checked-in `CURRENT_PROJECT_VERSION` aligned with the latest
  published build so local development builds are not offered older updates.
- Do not edit `appcast.xml` manually. `scripts/update_appcast.py` updates the
  canonical feed on `main`, keeps all stable entries, and retains five betas.
- Do not create, move, or force-push release tags unless explicitly requested.
  Published releases are never overwritten.

### Release Pipeline

The release workflow:

1. Selects the stable or beta channel from the branch name.
2. Reads version and release notes from `semver.txt`.
3. Runs `bash scripts/test.sh --unit-only`.
4. Builds and signs the universal app, then creates the DMG.
5. Signs the DMG with Sparkle's EdDSA tool.
6. Publishes the GitHub Release.
7. Updates the canonical appcast on `main`.

Release jobs are globally serialized because all branches share tags and one
appcast. Running releases are not cancelled. GitHub Actions use floating major
tags, and the Sparkle tools use `SPARKLE_VERSION`, which tests require to match
`Package.resolved`. Keep the workflow logic in `scripts/` so local runs and CI
behave the same. See `BUILD.md` for secrets and branch-protection setup.

---

## 5. Code Conventions

### Swift

- Use Swift 6 language mode and complete concurrency checking in every target.
  The app uses MainActor default isolation and Approachable Concurrency.
- Use four-space indentation. Format with `xcrun swift-format` and the
  repository's `.swift-format`; `scripts/test.sh` lints in strict mode.
- Keep identifiers, comments, and user-facing strings in English.
- Prefer the narrowest practical access level (`private` or `fileprivate`).
- Use `Logger` (`os`) for diagnostics; do not add `print()` or `NSLog()` calls.
- Prefer `guard let`; force unwrap only compile-time-guaranteed resources.
- Guard versioned macOS APIs with `if #available` and provide a fallback where
  the deployment target requires one.
- Prefer recoverable errors and diagnostic logging over fatal termination.

### C

- Keep the existing compact style in `CoreTamerController/` and `ProcessControl/`.
- Code must compile without warnings with `-Wall -Wextra` and pass the clang
  static analyzer run by `scripts/test.sh`.
- Check every system call result and report failures with the PID and `errno`.
- Every code path that stops a process must guarantee that it is resumed.

### Bash

- Use `set -euo pipefail`, quote variables, and keep scripts shellcheck-clean.
- Print errors to stderr with actionable context and exit non-zero.
- Comment advanced commands with their intent and safety implications.

### Python

- Use the standard library only; tests use `unittest` under `tests/`.

### Behavior Specification

- Business behavior changes need an English scenario in
  `features/cpu-limits.feature` that uses the real UI strings.

---

## 6. Validation Before a Pull Request

Quit any running CoreTamer instance first (press Stop in Xcode if it is paused in
the debugger). The app hosts the tests and prohibits multiple instances.

Run the automated checks relevant to the change:

```bash
bash scripts/test.sh
```

Add tests for every changed code path and keep production line coverage above
80 %. For workflow or release changes, also run:

```bash
actionlint
shellcheck scripts/build.sh scripts/test.sh scripts/release.sh
xmllint --noout appcast.xml
```

The automated suite covers process listing and grouping, the model and views,
the update controller, the appcast updater, the release pipeline, and real
throttling of the disposable `BusyThreads` fixture. It does not replace manual
testing of the running app.

Tests and smoke tests may only throttle disposable workloads (for example the
compiled `BusyThreads` fixture or `yes > /dev/null`), never real apps or system
services. Perform the applicable smoke tests before release:

1. Build and run in Xcode with no build warnings.
2. Start a disposable workload, find it by name and by PID, and sort by each
   column.
3. Limit the workload to 50 % and verify in Activity Monitor that it settles
   near the limit; remove the limit and verify full speed returns.
4. Limit an app with helpers as a group and verify the shared budget.
5. Quit CoreTamer while a limit is active; the workload must keep running and
   must not stay stopped.
6. Enable "Restore app limits when apps restart", limit a disposable app, quit
   and relaunch it, and verify the limit returns.
7. Verify grouping, background visibility, update speed, and pause-on-hover.
8. Exercise stable and beta Sparkle update checks.
9. Confirm the unified log for `com.vd.CoreTamer` has no unexpected errors.

---

## 7. High-Value Code Anchors

- App state, limits, and persistence: `AppModel` in `CoreTamer/App/CoreTamerApp.swift`
- Process table and settings UI: `CoreTamer/Views/TamerView.swift`
- Which processes may be limited: `ProcessSnapshot` in `CoreTamerCore/Processes.swift`
- Grouping and sorting: `groupedProcesses` and `ProcessListOrder` in `Processes.swift`
- Helper launch and group members: `CoreTamerCore/Limiter.swift`
- Duty cycle and watchdog: `CoreTamerController/main.c`
- Identity checks and timebase: `ProcessControl/ProcessControl.c`
- Sparkle preferences and channels: `CoreTamer/App/UpdateController.swift`
- Release source of truth: `semver.txt`
- Release orchestration: `.github/workflows/build-release.yml` and `scripts/release.sh`
- Appcast transformation: `scripts/update_appcast.py`
- Automated checks: `.github/workflows/tests.yml`, `scripts/test.sh`,
  `tests/`, and `CoreTamerTests/`

---

## 8. Change Boundaries for Agents

### Allowed Without Prior Approval

- Focused bug fixes and behavior-preserving refactors with passing tests.
- Performance improvements to process sampling and list updates.
- Tests and documentation that reflect verified behavior.
- UI polish that keeps the established compact menu-bar layout.

### Ask the Maintainer First

- Changes to process identity checks, the set of limitable processes, or the
  controller's duty cycle and watchdog.
- `UserDefaults` schema or controller protocol changes that need migration.
- Substantial UI redesigns.
- New Swift packages, other dependencies, or external services.
- Release workflow, version parser, signing, or appcast behavior changes.
- Deleting releases, moving tags, or changing branch-protection behavior.

### Never Do

- Weaken process identity checks, protected-process rules, or watchdog cleanup.
- Throttle real apps or system services in tests.
- Add tracking, telemetry, analytics, or unrelated network calls.
- Commit `dist/`, `build/`, `DerivedData/`, `xcuserdata/`, secrets, tokens,
  certificates, private keys, Sparkle keys, or Apple IDs.
- Add `print()` or `NSLog()` diagnostics to shipped Swift code.
- Remove `semver.txt` history or edit generated appcast entries by hand.
- Force-push release tags or commit directly to `main`.
- Introduce large unrelated formatting changes.
- Change or remove copyright or license headers without explicit instruction.

---

## 9. Common Failure Modes

- **Tests hang or fail to launch:** A running CoreTamer instance blocks the test
  host. Quit it, or press Stop in Xcode if it is paused in the debugger.
- **Timing-based workload test fails:** These tests need spare CPU capacity.
  Check the system load before treating it as a regression; CI uses
  `--unit-only` for this reason.
- **`codesign` fails with "resource fork, Finder information, or similar
  detritus":** Cloud-synced folders (for example iCloud Drive) add extended
  attributes. Build outside the checkout with `OUTPUT_DIR`; `scripts/test.sh`
  already uses a temporary folder.
- **No signing certificate:** Configure the development team in Xcode, or pass
  `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` to `scripts/build.sh`.
- **Release skipped:** Test-only/documentation-only changes are intentionally
  ignored. On `main`, `semver.txt` must change. Other branches must use the
  `feature/*` naming convention or `workflow_dispatch`.
- **Appcast push rejected:** Verify the GitHub App credentials, Contents write
  permission, installation, and branch-protection bypass described in `BUILD.md`.
- **Sparkle version mismatch:** Keep `SPARKLE_VERSION` in the release workflow in
  sync with `Package.resolved`; the release tests enforce this.
- **Sparkle update not visible:** Check channel selection, appcast caching, build
  numbers, and the enclosure URL before republishing.
- **Actionlint reports `app-id`/`client-id`:** `.github/actionlint.yaml` suppresses
  only the stale schema warning for the current floating v3 action.

---

## 10. Escalation Checklist

Ask before proceeding when a change affects process control safety, privacy,
persisted settings, the controller protocol, release/signing behavior,
dependencies, or the product's UI structure. For ordinary focused fixes, tests,
and small refactors, proceed on a feature branch and open a pull request. Use
the `coretamer-readiness` skill (`.github/skills/`) before committing or
opening a pull request.

---

*Last updated: 2026-10-25. Keep this file synchronized with architecture,
testing, and release-workflow changes.*
