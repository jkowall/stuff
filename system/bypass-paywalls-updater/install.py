#!/usr/bin/python3
"""Install or remove the current user's daily macOS LaunchAgent."""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

from update import DEFAULT_STATE, read_manifest

LABEL = "local.bypass-paywalls-updater"
HERE = Path(__file__).resolve().parent
STATE = DEFAULT_STATE
TARGET = STATE / "extension"
PLIST = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
DOMAIN = f"gui/{os.getuid()}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    present = subprocess.run(["/bin/launchctl", "print", f"{DOMAIN}/{LABEL}"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if args.uninstall:
        if present:
            subprocess.run(["/bin/launchctl", "bootout", f"{DOMAIN}/{LABEL}"], check=True)
        PLIST.unlink(missing_ok=True)
        print("Daily updater removed. Extension files and backups retained.")
        return
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    if TARGET.exists():
        read_manifest(TARGET)
    # launchd cannot read this Mac's OneDrive folder, so keep all runtime files local.
    runtime = STATE / "update.py"
    shutil.copyfile(HERE / "update.py", runtime)
    if not TARGET.exists():
        subprocess.run(["/usr/bin/python3", str(runtime), "--initialize",
                        "--extension-dir", str(TARGET), "--state-dir", str(STATE)], check=True)
    if present:
        subprocess.run(["/bin/launchctl", "bootout", f"{DOMAIN}/{LABEL}"], check=True)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    config = {
        "Label": LABEL,
        "ProgramArguments": ["/usr/bin/python3", str(runtime),
                             "--extension-dir", str(TARGET), "--state-dir", str(STATE)],
        "RunAtLoad": True,
        "StartInterval": 86400,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "StandardOutPath": str(STATE / "updater.log"),
        "StandardErrorPath": str(STATE / "updater.log"),
    }
    with PLIST.open("wb") as output:
        plistlib.dump(config, output)
    PLIST.chmod(0o644)
    subprocess.run(["/bin/launchctl", "bootstrap", DOMAIN, str(PLIST)], check=True)
    print(f"Installed {PLIST}")
    print("Checks at login and every 24 hours while logged in.")
    print(f"Load unpacked in Chrome once: {TARGET}")
    print(f"Log: {STATE / 'updater.log'}")


if __name__ == "__main__":
    main()
