#!/usr/bin/env python3
"""Bounded pi RPC + builtin-MCP injector contract check.

Pi has no generate-json-schema CLI. This gate only asserts:
- a local `pi` binary is at least the contract floor, when present
- `pi --help` still advertises RPC mode and `-e`
- the checked-in fixture still names the fields RPCE sends/consumes

Missing `pi` is a skip (exit 0) so developer machines without the CLI stay usable.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Scripts" / "Fixtures" / "pi-rpc-contract.json"


def parse_version(raw: str) -> tuple[int, ...]:
    digits = []
    for part in raw.strip().split("."):
        token = ""
        for char in part:
            if char.isdigit():
                token += char
            else:
                break
        digits.append(int(token or "0"))
    return tuple(digits or (0,))


def main() -> int:
    fixture = json.loads(FIXTURE.read_text())
    floor = str(fixture["floorVersion"])
    required_commands = set(fixture["commands"])
    required_events = set(fixture["events"])
    if fixture.get("clientName") != "pi":
        print("ERROR: pi-rpc-contract clientName must be 'pi'", file=sys.stderr)
        return 1
    if not required_commands or not required_events:
        print("ERROR: pi-rpc-contract commands/events must be non-empty", file=sys.stderr)
        return 1
    injector = fixture.get("injector") or {}
    if injector.get("exposure") != "direct" or injector.get("timeoutUnit") != "seconds":
        print("ERROR: injector contract must keep exposure=direct and timeout seconds", file=sys.stderr)
        return 1

    pi = shutil.which("pi")
    if pi is None:
        print("SKIP: pi CLI not on PATH; contract fixture is still valid")
        return 0

    version_proc = subprocess.run([pi, "--version"], capture_output=True, text=True, check=False)
    version_text = (version_proc.stdout or version_proc.stderr or "").strip().splitlines()
    version = version_text[0].strip() if version_text else ""
    if parse_version(version) < parse_version(floor):
        print(f"ERROR: pi {version or 'unknown'} is older than contract floor {floor}", file=sys.stderr)
        return 1

    help_proc = subprocess.run([pi, "--help"], capture_output=True, text=True, check=False)
    help_text = f"{help_proc.stdout}\n{help_proc.stderr}"
    if "--mode" not in help_text or "rpc" not in help_text.lower():
        print("ERROR: pi --help no longer advertises RPC mode", file=sys.stderr)
        return 1
    if "-e" not in help_text and "--extension" not in help_text:
        print("ERROR: pi --help no longer advertises -e/--extension", file=sys.stderr)
        return 1

    print(f"OK: pi {version} >= {floor}; RPC contract fixture accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
