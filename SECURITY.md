# Security Policy

## Supported Versions

| Version | Supported |
| ------- | ------------------ |
| 1.0.x   | ✅ |
| < 1.0   | ❌ |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately:

1. **Do not** open a public issue
2. Use [GitHub's private vulnerability reporting](https://github.com/vordenken/CoreTamer/security/advisories/new)
3. Include the CoreTamer version, macOS version, Mac architecture, steps to reproduce (using disposable processes) and the impact

Please remove usernames, private file paths and other personal data from logs.
You can expect a response within 48 hours.

## Scope

CoreTamer only controls eligible processes owned by the current user and needs no
administrator rights. Throttling works by suspending and resuming processes
(`SIGSTOP`/`SIGCONT`). PID and start-time checks mitigate, but cannot fully
eliminate, process-identity races. The watchdog cannot guarantee recovery if it
is itself terminated or prevented from running.
