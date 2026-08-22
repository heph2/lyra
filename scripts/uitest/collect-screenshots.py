#!/usr/bin/env python3
"""Exports the screenshots a LyraUITests run attached, under readable names."""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

bundle, dest = Path(sys.argv[1]), Path(sys.argv[2])
dest.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as staging:
    subprocess.run(
        ["xcrun", "xcresulttool", "export", "attachments",
         "--path", str(bundle), "--output-path", staging],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    manifest = Path(staging) / "manifest.json"
    if not manifest.exists():
        sys.exit(0)
    for test in json.load(open(manifest)):
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName") or attachment["exportedFileName"]
            if not name.endswith(".png"):
                continue
            # Strip the "_0_<UUID>" xcresult adds to every attachment name.
            clean = re.sub(r"_\d+_[0-9A-F-]{36}", "", name)
            shutil.copy(Path(staging) / attachment["exportedFileName"], dest / clean)
            print(f"  {clean}")
