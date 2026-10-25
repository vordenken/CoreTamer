---
name: coretamer-readiness
description: 'Check whether CoreTamer changes are ready to commit, push, open as a pull request, or release. Use for quick checks, full readiness, release preparation, pre-commit checks, PR preparation, or /coretamer-readiness.'
argument-hint: 'quick | full | release (default: full)'
user-invocable: true
disable-model-invocation: false
---

# CoreTamer Readiness

Assess the current worktree against CoreTamer's repository rules and return an
evidence-based readiness verdict. This workflow is read-only: do not edit,
stage, commit, push, create a pull request, change versions, or fetch remotes
unless the user separately asks for that action.

## Modes

Use the requested mode, or `full` when none is provided:

- `quick`: inspect the current worktree and run the smallest checks focused on
  its changes. Use this for fast feedback before a commit.
- `full`: inspect the worktree, commits, branch, upstream, and PR comparison;
  run all checks required by the affected paths; then report separate commit,
  push, and PR readiness verdicts.
- `release`: perform the full assessment plus release metadata, workflow, and
  appcast validation. Never publish or modify release artifacts.

## Procedure

### 1. Establish the comparison

Run:

```bash
git status --short --branch
git diff --check
git diff --stat
git diff --cached --stat
```

For `full` and `release`, also identify the current branch, upstream, and local
base without fetching:

```bash
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
git rev-list --left-right --count '@{upstream}...HEAD'
git merge-base HEAD origin/main
git log --oneline --decorate origin/main..HEAD
git diff --name-status origin/main...HEAD
```

Treat a missing upstream or `origin/main` as a warning and continue with the
best available local comparison. State explicitly that remote freshness was
not verified. A direct commit or push from `main` is a blocker unless the user
explicitly confirms that repository policy has changed.

Use both staged and unstaged changes in `quick` mode. Use the complete
`origin/main...HEAD` change set plus uncommitted changes in `full` and
`release` modes.

### 2. Classify the change

Classify changed paths into these groups:

- App and core: `CoreTamer/**`, `CoreTamerCore/**`, `CoreTamerController/**`,
  `ProcessControl/**`, `CoreTamer.xcodeproj/**`.
- Tests: `CoreTamerTests/**`, `tests/**`, `features/**`.
- Release or CI: `.github/workflows/**`, `.github/actionlint.yaml`, `scripts/**`,
  `semver.txt`, `appcast.xml`.
- Documentation or metadata: Markdown files, issue templates, funding,
  licenses, and repository metadata.

Review the diff for accidental build products (`dist/`, `build/`,
`DerivedData/`, `xcuserdata/`, `*.profraw`), secrets, certificates, private
keys, Sparkle keys, signing identities, tokens, unrelated changes, `print()`
diagnostics, new dependencies, and changed entitlements. Report weakened
process identity checks, protected-process lists, watchdog cleanup, privacy,
persisted settings, dependencies, or release/signing behavior as
approval-required according to `AGENTS.md`.

Behavior changes need a scenario in `features/cpu-limits.feature`; user-visible
changes need an entry in `semver.txt`. Report missing entries as blockers for PR
readiness.

### 3. Run validation

Always run the smallest relevant check first. Do not rerun a check that already
passed unchanged during this readiness assessment.

Before any Xcode test run, make sure no CoreTamer instance is running (the app
is the test host and prohibits multiple instances):

```bash
pgrep -lf 'CoreTamer.app/Contents/MacOS/CoreTamer' || true
```

If an instance is running, report it and ask the user to quit it (or press Stop
in Xcode if it is paused in the debugger). Never kill it automatically.

For documentation-only changes, no build is required.

For script, workflow, appcast, or Python test changes:

```bash
bash -n scripts/build.sh scripts/test.sh scripts/release.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests
```

For app, core, controller, project, or Swift test changes in `quick` mode:

```bash
bash scripts/test.sh --unit-only
```

In `full` and `release` mode, run the complete suite including the timing-based
workload tests and the production coverage gate (> 80 %):

```bash
bash scripts/test.sh
```

Timing-based tests need spare CPU capacity. If one fails, check the system load
before reporting a product regression, and rerun it once at most.

For workflow or release changes, also run:

```bash
actionlint
shellcheck scripts/build.sh scripts/test.sh scripts/release.sh
xmllint --noout appcast.xml
```

If `actionlint` or `shellcheck` is unavailable, report the missing executable as
a blocker for workflow/script changes and as a warning otherwise. Do not install
tools implicitly.

In `release` mode, also run the universal build in a non-synced folder and
verify it:

```bash
OUTPUT_DIR="$(mktemp -d)" bash scripts/build.sh
```

Then check with `lipo -archs` that the app and
`Contents/Helpers/CoreTamerController` contain `arm64` and `x86_64`, and that
`codesign --verify --deep --strict` succeeds. Also verify:

- Line 1 of `semver.txt` is strict `X.Y.Z` SemVer.
- Current release notes follow `---` and are non-empty.
- Historical release notes remain present.
- `MARKETING_VERSION` in the Xcode project matches `semver.txt`.
- `SPARKLE_VERSION` in `build-release.yml` matches `Package.resolved`.
- `main` has a `semver.txt` change; beta builds come from `feature/*`.
- `appcast.xml` was not edited manually.

### 4. Evaluate readiness

Use these verdicts:

- `READY`: every required check passed and no policy blocker exists.
- `READY WITH WARNINGS`: required checks passed, but non-blocking manual or
  remote verification remains.
- `NOT READY`: a required check failed, required tooling is unavailable, the
  branch violates policy, or the change needs maintainer approval first.

In `full` mode, report all three stages independently:

- Commit readiness covers worktree hygiene, policy checks, and change-focused
  validation.
- Push readiness additionally covers branch, upstream, commits, and all CI
  checks required by affected paths.
- PR readiness additionally covers the complete comparison with `main`, the PR
  checklist, required documentation, and maintainer-approval boundaries.

The overall `full` verdict is the strictest of the three stage verdicts. A
missing upstream can warn for commit readiness while blocking push readiness.

Do not claim the running app was smoke-tested unless it was actually exercised.
For behavior changes, list the applicable manual smoke tests from `AGENTS.md`
as remaining evidence. Smoke tests may only throttle disposable workloads.

## Report Format

Keep the result concise and use this order:

1. Overall verdict and requested mode.
2. Commit, push, and PR verdicts when running `full`; release verdict when
   running `release`.
3. Blockers.
4. Warnings and approval-required changes.
5. Checks run with pass, fail, or skipped status, including production coverage.
6. Branch, comparison base, and changed-path summary.
7. Exact next actions needed to reach `READY`.

Never conceal failing or skipped checks, and never use `--no-verify` to obtain a
passing result.
