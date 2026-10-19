#!/usr/bin/env python3
"""Register an explicitly supplied companion extension ID with a browser."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sys

BROWSERS = {
    "chrome": "Google/Chrome",
    "chromium": "Chromium",
    "brave": "BraveSoftware/Brave-Browser",
    "edge": "Microsoft Edge",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("extension_id", help="32-letter ID from the browser's extensions page")
    parser.add_argument("--browser", choices=BROWSERS, default="chrome")
    parser.add_argument("--uninstall", action="store_true", help="Remove this browser's native host registration")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-p]{32}", args.extension_id):
        parser.error("Expected a Chrome extension ID: 32 lowercase letters a–p")
    support = Path.home() / "Library/Application Support"
    registration = support / BROWSERS[args.browser] / "NativeMessagingHosts/com.soundshelf.bridge.json"
    if args.uninstall:
        registration.unlink(missing_ok=True)
        print(f"Removed registration: {registration}")
        return
    install = support / "SoundShelf/NativeHost"
    install.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(install, 0o700)
    source = Path(__file__).resolve().parents[1] / "Bridge/host.py"
    shutil.copyfile(source, install / "host.py")
    launcher = install / "launch-host"
    launcher.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(install / 'host.py'))} \"$@\"\n")
    launcher.chmod(0o700)
    origins = {f"chrome-extension://{args.extension_id}/"}
    if registration.exists():
        previous = json.loads(registration.read_text())
        origins.update(previous.get("allowed_origins", []))
    manifest = {
        "name": "com.soundshelf.bridge",
        "description": "SoundShelf local media bridge",
        "path": str(launcher),
        "type": "stdio",
        "allowed_origins": sorted(origins),
    }
    registration.parent.mkdir(parents=True, exist_ok=True)
    registration.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Registered for {args.browser}: {registration}")
    print("Click the SoundShelf extension icon, then Reconnect.")


if __name__ == "__main__":
    main()
