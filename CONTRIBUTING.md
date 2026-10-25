# Contributing to CoreTamer

Thanks for your interest in contributing! 🎉

## How to Contribute

1. Fork the repository
2. Create a branch (`feature/my-feature`, `bugfix/my-fix` or `hotfix/my-patch`)
3. Make your changes
4. Run the tests: `bash scripts/test.sh`
5. Update [semver.txt](semver.txt) for user-visible changes
6. Open a pull request

Open pull requests against `main`. Once automated releases are configured,
release-relevant pushes to `feature/*` create beta releases. Use a `feature/*`
branch when you need a beta build, including for bug fixes. The `bugfix/*` and
`hotfix/*` prefixes remain valid but do not trigger beta releases. Stable releases
are created from `main` when `semver.txt` changes.

New to pull requests? Check out [How to Contribute to an Open Source Project on GitHub](https://kcd.im/pull-request).

## Guidelines

- Keep changes focused and explain behavior changes in the pull request.
- Follow the existing Swift and C style; format Swift with `xcrun swift-format`.
- Add tests for changed code paths; production line coverage must stay above 80%.
- Update the behavior specification in [features/cpu-limits.feature](features/cpu-limits.feature) when behavior changes.
- Keep both architectures (arm64 and x86_64), process identity checks, protected targets and watchdog cleanup intact.
- Never commit build products, credentials, signing material or logs with personal data.

CPU measurement tests start disposable workloads. Run them on a Mac with spare CPU
capacity and never point them at important apps or system services.

See [BUILD.md](BUILD.md) for build and release details. Contributions are made
under the [GNU GPL v3](LICENSE).
