#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# ///
"""
session-map.py - Map iOS device sessions to server sessions
Usage: ./scripts/session-map.py [ssh-host]
"""

import subprocess
import plistlib
import json
import sys
import tempfile
from pathlib import Path


def run(cmd: list[str], capture=True) -> str:
    """Run a command and return stdout."""
    result = subprocess.run(cmd, capture_output=capture, text=True)
    return result.stdout.strip() if capture else ""


def pull_ios_prefs(temp_dir: Path) -> dict:
    """Pull preferences plist from connected iPhone."""
    plist_path = temp_dir / "prefs.plist"

    subprocess.run([
        "xcrun", "devicectl", "device", "copy", "from",
        "--device", "iPhone 16",
        "--source", "Library/Preferences/com.clauntty.app.plist",
        "--domain-type", "appDataContainer",
        "--domain-identifier", "com.clauntty.app",
        "--destination", str(plist_path)
    ], capture_output=True)

    if not plist_path.exists():
        print("Failed to pull iOS preferences")
        return {}

    with open(plist_path, "rb") as f:
        return plistlib.load(f)


def get_server_sessions(ssh_host: str) -> tuple[dict[str, str], dict[str, tuple[str, str]]]:
    """Get session titles and active sockets from server."""
    # Get titles
    titles_cmd = '''for f in ~/.clauntty/sessions/*.title; do
        id=$(basename "$f" .title)
        title=$(cat "$f" 2>/dev/null || echo "")
        echo "$id|$title"
    done'''

    result = subprocess.run(["ssh", ssh_host, titles_cmd], capture_output=True, text=True)

    titles = {}
    for line in result.stdout.strip().split("\n"):
        if "|" in line:
            sid, title = line.split("|", 1)
            titles[sid] = title

    # Get sockets and check if they have a listening process
    sockets_cmd = '''for f in ~/.clauntty/sessions/*; do
        if [ -S "$f" ]; then
            name=$(basename "$f")
            pid=$(lsof -t "$f" 2>/dev/null | head -1)
            if [ -n "$pid" ]; then
                echo "$name|live|$pid"
            else
                echo "$name|stale|"
            fi
        fi
    done'''

    result = subprocess.run(["ssh", ssh_host, sockets_cmd], capture_output=True, text=True)

    sockets = {}  # sid -> (status, pid)
    for line in result.stdout.strip().split("\n"):
        if "|" in line:
            parts = line.strip().split("|")
            if len(parts) >= 2:
                sid, status = parts[0], parts[1]
                pid = parts[2] if len(parts) > 2 else ""
                sockets[sid] = (status, pid)

    return titles, sockets


def main():
    ssh_host = sys.argv[1] if len(sys.argv) > 1 else "devbox"

    print("=== Clauntty Session Mapper ===")
    print()

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        print("Pulling iOS device preferences...")
        prefs = pull_ios_prefs(temp_path)

        if not prefs:
            print("No preferences found")
            return 1

        print(f"Fetching server sessions from {ssh_host}...")
        server_titles, active_sockets = get_server_sessions(ssh_host)

        # Parse persisted tabs (stored as bytes containing JSON)
        tabs_data = prefs.get("clauntty_persisted_tabs", b"[]")
        if isinstance(tabs_data, bytes):
            tabs = json.loads(tabs_data.decode("utf-8"))
        else:
            tabs = []

        print()
        print("=== iOS Device Tabs ===")
        print()
        print(f"{'Tab':<4} {'Session ID':<38} {'iOS Cached Title':<30} {'Server Title':<30} {'Status'}")
        print(f"{'---':<4} {'-'*38:<38} {'-'*30:<30} {'-'*30:<30} {'------'}")

        for i, tab in enumerate(tabs):
            sid = tab.get("rtachSessionId", "N/A")
            ios_title = (tab.get("cachedDynamicTitle") or tab.get("cachedTitle", "N/A"))[:28]
            server_title = server_titles.get(sid, "(not found)")[:28]

            if sid in active_sockets:
                sock_status, pid = active_sockets[sid]
                if sock_status == "live":
                    status = f"✓ live (pid {pid})"
                else:
                    status = "⚠ STALE socket"
            else:
                status = "✗ no socket"

            print(f"{i:<4} {sid:<38} {ios_title:<30} {server_title:<30} {status}")

        print()
        print("=== All Server Sessions ===")
        print()
        print(f"{'Session ID':<38} {'Title':<30} {'Status'}")
        print(f"{'-'*38:<38} {'-'*30:<30} {'------'}")

        for sid, title in sorted(server_titles.items()):
            if sid in active_sockets:
                sock_status, pid = active_sockets[sid]
                if sock_status == "live":
                    status = f"✓ live (pid {pid})"
                else:
                    status = "⚠ STALE socket"
            else:
                status = "✗ no socket"
            print(f"{sid:<38} {title[:28]:<30} {status}")

        print()
        print("=== Summary ===")
        live_count = sum(1 for s, p in active_sockets.values() if s == "live")
        stale_count = sum(1 for s, p in active_sockets.values() if s == "stale")
        print(f"iOS tabs: {len(tabs)}")
        print(f"Server sessions with titles: {len(server_titles)}")
        print(f"Server live sockets: {live_count}")
        if stale_count > 0:
            print(f"Server STALE sockets: {stale_count} (need cleanup)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
