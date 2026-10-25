# Privacy Policy

CoreTamer respects your privacy.

## Data Collection

- **No personal data** is collected
- **No analytics** or tracking
- **No network connections** except update checks via Sparkle (see below)
- **No data** is shared with third parties

## Local Data

CoreTamer reads the name, PID, owner, path and CPU usage of running processes
locally via macOS system APIs to display them and apply limits. This information
never leaves your Mac.

The following settings are stored locally in the macOS preferences domain
`com.vd.CoreTamer`:

- Whether background processes are shown
- Whether the first-launch welcome has been completed
- Update preferences (automatic checks, automatic downloads, beta versions)
- Whether limits are restored, and — only if enabled — the executable paths and CPU limits of limited apps

Disabling restoration deletes the saved limits. Launch at login is managed by
macOS (`SMAppService`) and can be changed in System Settings.

## Software Updates

- CoreTamer uses the open-source [Sparkle](https://sparkle-project.org) framework to check for and download updates.
- Automatic update checks are enabled by default and can be disabled in CoreTamer's settings. Automatic downloads and beta updates are also configurable.
- Sparkle retrieves the update feed from `raw.githubusercontent.com` and update packages from CoreTamer releases hosted by GitHub.
- These requests disclose standard connection information to GitHub, such as the IP address, request time, requested URL and HTTP metadata required to deliver the update.
- CoreTamer does not enable Sparkle system profiling and does not attach process lists, limits or other local data to update requests.

GitHub processes connection data under its own privacy policy.

## Permissions

CoreTamer requires no administrator rights, Accessibility, Screen Recording or
other special permissions.

## Contact

Questions? Open an [issue](https://github.com/vordenken/CoreTamer/issues).
