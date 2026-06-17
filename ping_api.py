#!/usr/bin/env python3
"""
ping_api.py - OPTIONAL API-billing ping (advanced; usually NOT what you want).

This sends one minimal message to Claude via the official Messages API using an
API key. It uses pay-as-you-go API credits, which are a SEPARATE billing pool
from your Claude Code / Claude.ai subscription. As a result this generally does
NOT start or affect your Claude Code subscription's 5-hour session window.

If your goal is to align the Claude Code subscription window, use ./aligner.sh
(which calls ping.sh -> `claude -p`) instead.

Usage:
    export ANTHROPIC_API_KEY="sk-ant-..."
    python3 ping_api.py

No third-party packages required (uses the Python standard library only).
"""

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime

API_URL = "https://api.anthropic.com/v1/messages"
API_VERSION = "2023-06-01"
MODEL = "claude-haiku-4-5"  # a small, cheap model; adjust if needed
MAX_TOKENS = 16
PROMPT = "ping to start session"


def log(message: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{stamp}  {message}")


def main() -> int:
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        log("FAILURE: ANTHROPIC_API_KEY is not set. "
            'Run: export ANTHROPIC_API_KEY="sk-ant-..."')
        return 1

    payload = json.dumps({
        "model": MODEL,
        "max_tokens": MAX_TOKENS,
        "messages": [{"role": "user", "content": PROMPT}],
    }).encode("utf-8")

    request = urllib.request.Request(
        API_URL,
        data=payload,
        method="POST",
        headers={
            "x-api-key": api_key,
            "anthropic-version": API_VERSION,
            "content-type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace")[:200]
        log(f"FAILURE: API returned HTTP {err.code}. {detail}")
        return 1
    except urllib.error.URLError as err:
        log(f"FAILURE: network error ({err.reason}). Check your connection.")
        return 1
    except Exception as err:  # noqa: BLE001 - last-resort guard for a tiny script
        log(f"FAILURE: unexpected error: {err}")
        return 1

    # Pull the first bit of text out of the reply, if any.
    reply = ""
    for block in body.get("content", []):
        if block.get("type") == "text":
            reply = block.get("text", "")
            break
    log(f"SUCCESS: API ping sent (separate from subscription window). "
        f"Reply: {reply[:120] or '(empty)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
