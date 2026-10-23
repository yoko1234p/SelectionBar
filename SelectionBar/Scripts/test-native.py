#!/usr/bin/env python3
"""Run only SelectionBar's owned native fixtures, preserving its live profile."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, default=Path("/Applications/SelectionBar.app"))
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
profile = Path.home() / "Library/Application Support/SelectionBar/library.json"
before = hashlib.sha256(profile.read_bytes()).hexdigest() if profile.exists() else None


def quit_app():
    subprocess.run(["osascript", "-e", 'if application id "local.pakwingho.selectionbar" is running then tell application id "local.pakwingho.selectionbar" to quit'], check=True)
    for _ in range(50):
        if subprocess.run(["pgrep", "-x", "SelectionBar"], capture_output=True).returncode != 0:
            return
        time.sleep(.1)
    raise RuntimeError("SelectionBar refused to quit; no fixture was started.")


results = {}
try:
    quit_app()
    for mode in ["actions", "spelling"]:
        root = Path(tempfile.mkdtemp(prefix="SelectionBar-native-"))
        root.chmod(0o700)
        report = root / "report.json"
        flags = ["--ui-smoke", "--data-directory", str(root), "--smoke-report", str(report)]
        if mode == "spelling":
            flags.append("--spelling-smoke")
        subprocess.run(["open", "-n", "-a", str(args.app), "--args", *flags], check=True)
        try:
            deadline = time.monotonic() + 60
            while not report.exists() and time.monotonic() < deadline:
                time.sleep(.2)
            if not report.exists():
                raise RuntimeError(f"{mode}: native fixture timed out")
            result = json.loads(report.read_text())
            (args.output / (mode + ".json")).write_text(json.dumps(result, indent=2) + "\n")
            results[mode] = result.get("complete") is True and result.get("allChecksPassed") is True
        finally:
            quit_app()
            shutil.rmtree(root)
        if not results[mode]:
            raise RuntimeError(f"{mode}: see native report for the failed check")
    after = hashlib.sha256(profile.read_bytes()).hexdigest() if profile.exists() else None
    assert before == after, "Native tests modified the live SelectionBar profile"
    (args.output / "summary.json").write_text(json.dumps({"checks": results, "live_profile_unchanged": True, "private_extensions_executed": False}, indent=2) + "\n")
    print("PASS: SelectionBar actions and spelling; live profile unchanged")
finally:
    subprocess.run(["open", "-g", "-j", str(args.app)], check=True)
