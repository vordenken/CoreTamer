"""Diagnose CI signing on disposable files without changing keychain settings."""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    identity = os.environ.get("CODE_SIGN_IDENTITY", "")
    if not identity or identity == "-":
        print("ERROR: Signing diagnostics require CODE_SIGN_IDENTITY from the certificate import.",
              file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="CoreTamer-signing-check-") as directory:
        for label, timestamp in (
            ("without timestamp", "--timestamp=none"),
            ("with timestamp", "--timestamp"),
        ):
            probe = Path(directory) / "signing-probe"
            shutil.copyfile("/usr/bin/true", probe)
            probe.chmod(0o700)
            print(f"==> Signing diagnostic {label} (90-second timeout)", flush=True)
            commands = (
                (["codesign", "--force", "--options", "runtime", "--sign", identity,
                  timestamp, str(probe)], 90),
                (["codesign", "--verify", "--strict", str(probe)], 30),
            )
            for command, timeout in commands:
                operation = "verification" if "--verify" in command else "signing"
                print(f"==> Probe {operation} {label}", flush=True)
                try:
                    subprocess.run(command, check=True, timeout=timeout)
                except subprocess.TimeoutExpired:
                    print(f"ERROR: Probe {operation} {label} timed out after {timeout} seconds.",
                          file=sys.stderr)
                    return 1
                except subprocess.CalledProcessError as error:
                    print(f"ERROR: Probe {operation} {label} failed (exit {error.returncode}). "
                          "See codesign diagnostics above.", file=sys.stderr)
                    return 1
                except OSError as error:
                    print(f"ERROR: Cannot run codesign for probe {operation}: {error}",
                          file=sys.stderr)
                    return 1
            print(f"==> Signing and verification {label} passed", flush=True)

    return 0


if __name__ == "__main__":
    sys.exit(main())
