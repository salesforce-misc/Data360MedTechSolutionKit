#!/usr/bin/env python3
"""
All-MCP-server credentials sentinel — permanent fix for the recurring
"Needs Auth" bug where VSCode's Claude Code extension shows a Salesforce
Standard MCP server (salesforce-sobject-all, salesforce-data-cloud-queries,
salesforce-data360, or any future one) as needing authentication even though
the auth script has already written valid tokens to ~/.claude/.credentials.json.

Why this exists: 

  Claude Code stores OAuth tokens in ~/.claude/.credentials.json under a
  key like `<server-name>|<16-hex-hash>`. The hash formula folds in the
  server URL, the client_id, the callback port, and possibly other fields
  — the exact recipe is not public and cannot be reliably reconstructed
  from Python. Our authenticate-mcp-server.sh writes tokens under a
  URL-only hash. If VSCode's extension is watching a different key (which
  it always is when the client_id is new for this org), the token exists
  on disk but the UI reports "Needs Auth" forever.

  Restarting VSCode used to be a workaround, because on startup the
  extension recreates its correctly-hashed empty stub entry, which our
  legacy script then couldn't populate without manual mirroring anyway.

What this script does (server-agnostic — one instance per server):

  1. Detaches from the parent shell and polls ~/.claude/.credentials.json
     every 2 seconds for up to 5 minutes.

  2. On each poll, looks for a fresh `<server-name>|<hash>` entry
     whose `accessToken` field is empty. That is the stub Claude Code
     creates on startup for a server it hasn't authenticated yet.

  3. As soon as it appears, copies the tokens from the source key (written
     by the auth script) into the freshly-created stub. Removes the legacy
     URL-only-hash entry so the credentials file doesn't accumulate dead
     keys across orgs.

  4. Also clears the server's entry from ~/.claude/mcp-needs-auth-cache.json
     so the MCP panel refreshes to ✓ Connected on the next check.

  5. Exits cleanly and logs to ~/.claude/<server-name>-sentinel.log.

Result: after VSCode is reloaded (once), Claude Code creates its stub,
this sentinel populates it within seconds, and the MCP panel flips to
✓ Connected — no further human action.

Usage (invoked automatically by authenticate-mcp-server.sh, but can
be run standalone):

    python3 all-mcp-server-sentinel.py \
        --server-name salesforce-data360 \
        --source-key salesforce-data360|49844e8d7b5a5770 \
        --timeout-sec 300

If --server-name is omitted, defaults to 'salesforce-sobject-all'.
If --source-key is omitted, uses the URL-only-hashed key derived from the
SERVER_URL (or legacy SOBJECT_ALL_URL) env var.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import sys
import time
from typing import Optional

DEFAULT_URL = "https://api.salesforce.com/platform/mcp/v1/platform/sobject-all"
DEFAULT_SERVER_NAME = "salesforce-sobject-all"
CRED_PATH = pathlib.Path.home() / ".claude" / ".credentials.json"
# Log path is set in main() once --server-name is known so each server has its own log.
LOG_PATH = pathlib.Path.home() / ".claude" / "sobject-all-sentinel.log"


def log(msg: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {msg}"
    print(line, flush=True)
    with LOG_PATH.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def read_creds() -> Optional[dict]:
    if not CRED_PATH.exists():
        return None
    try:
        return json.loads(CRED_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def write_creds(cred: dict) -> None:
    CRED_PATH.write_text(json.dumps(cred, indent=2), encoding="utf-8")


def url_only_key(url: str, server_name: str) -> str:
    h = hashlib.sha256(url.encode()).hexdigest()[:16]
    return f"{server_name}|{h}"


def is_valid_token(entry: dict) -> bool:
    return bool(entry.get("accessToken")) and bool(entry.get("refreshToken"))


def is_empty_stub(entry: dict) -> bool:
    return not entry.get("accessToken")


def server_entries(cred: dict, server_name: str) -> dict[str, dict]:
    return {
        k: v
        for k, v in cred.get("mcpOAuth", {}).items()
        if k.startswith(f"{server_name}|")
    }


def promote(source_key: str, target_key: str, cred: dict, server_name: str) -> None:
    """Copy tokens from source_key into target_key and drop source_key."""
    mcp = cred["mcpOAuth"]
    src = mcp[source_key]
    tgt = mcp.get(target_key, {})
    tgt.update(
        {
            "serverName": server_name,
            "serverUrl": tgt.get("serverUrl") or src.get("serverUrl"),
            "accessToken": src["accessToken"],
            "refreshToken": src["refreshToken"],
            "scope": src.get("scope", "refresh_token mcp_api"),
            "discoveryState": tgt.get("discoveryState")
            or src.get("discoveryState")
            or {
                "authorizationServerUrl": src.get("serverUrl"),
                "oauthMetadataFound": True,
            },
        }
    )
    mcp[target_key] = tgt
    del mcp[source_key]


def clear_needs_auth_cache(server_name: str) -> None:
    """Remove this server from Claude Code's 'Needs Auth' verdict cache.

    Claude Code writes an entry here whenever it sees an empty credential stub
    for a server. On subsequent MCP panel refreshes, it trusts this cache and
    shows "Needs Auth" until either the cache entry is removed OR the entry's
    timestamp is much older than the credentials-file mtime. Removing the
    entry unconditionally is the more reliable path — the next refresh will
    re-inspect credentials and flip to ✓ Connected.
    """
    cache = pathlib.Path.home() / ".claude" / "mcp-needs-auth-cache.json"
    if not cache.exists():
        return
    try:
        d = json.loads(cache.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return
    if server_name in d:
        del d[server_name]
        cache.write_text(json.dumps(d, indent=2), encoding="utf-8")
        log(f"Cleared '{server_name}' from mcp-needs-auth-cache.json")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--server-name",
        default=None,
        help="MCP server name to watch (e.g. 'salesforce-data360'). "
        "If omitted, defaults to 'salesforce-sobject-all' for backwards compat.",
    )
    parser.add_argument(
        "--source-key",
        default=None,
        help="Credentials-file key that already holds valid tokens. If omitted, "
        "derived from SERVER_URL env var (URL-only hash).",
    )
    parser.add_argument(
        "--timeout-sec",
        type=int,
        default=300,
        help="How long to wait for a Claude Code-created stub to appear (default 300).",
    )
    parser.add_argument(
        "--poll-interval-sec",
        type=float,
        default=2.0,
        help="How often to re-read the credentials file (default 2.0).",
    )
    args = parser.parse_args()

    server_name = args.server_name or os.environ.get("SERVER_NAME", DEFAULT_SERVER_NAME)
    url = os.environ.get("SERVER_URL", os.environ.get("SOBJECT_ALL_URL", DEFAULT_URL))
    source_key = args.source_key or url_only_key(url, server_name)

    # Per-server log path — must set before first log() call.
    global LOG_PATH
    LOG_PATH = pathlib.Path.home() / ".claude" / f"{server_name}-sentinel.log"

    log(f"Sentinel started. server={server_name}, source_key={source_key}, timeout={args.timeout_sec}s")

    cred = read_creds()
    if not cred:
        log("credentials file is missing or unreadable — exiting.")
        return 1

    entries = server_entries(cred, server_name)
    if source_key not in entries:
        log(f"source_key {source_key} not found — nothing to promote. Exiting.")
        return 1
    if not is_valid_token(entries[source_key]):
        log(f"source_key {source_key} has no valid token — exiting.")
        return 1

    # Fast path: if a Claude-Code-created stub is already present, promote immediately.
    for key, entry in entries.items():
        if key != source_key and is_empty_stub(entry):
            log(f"Fast path: promoting tokens from {source_key} to existing stub {key}")
            promote(source_key, key, cred, server_name)
            write_creds(cred)
            clear_needs_auth_cache(server_name)
            log("Done. MCP should show Connected on next panel refresh.")
            return 0

    # Otherwise, poll and wait for Claude Code to create its own stub.
    deadline = time.time() + args.timeout_sec
    while time.time() < deadline:
        time.sleep(args.poll_interval_sec)
        cred = read_creds()
        if not cred:
            continue
        entries = server_entries(cred, server_name)
        if source_key not in entries:
            log("source_key vanished between polls — exiting.")
            return 1

        # Look for a NEW stub (a key we haven't seen before, or an empty one).
        for key, entry in entries.items():
            if key == source_key:
                continue
            if is_empty_stub(entry):
                log(f"Detected Claude-Code-created stub: {key}. Promoting.")
                promote(source_key, key, cred, server_name)
                write_creds(cred)
                clear_needs_auth_cache(server_name)
                log("Done. MCP should show Connected on next panel refresh.")
                return 0

    log(
        f"Timed out after {args.timeout_sec}s — no Claude Code stub appeared. "
        "The URL-only-hash entry still holds valid tokens; a manual VSCode "
        "reload will trigger stub creation and the sentinel can be re-run."
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
