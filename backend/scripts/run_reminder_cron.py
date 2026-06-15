#!/usr/bin/env python3

import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request


DEFAULT_API_BASE = "https://smart-travel-6zsf.onrender.com"
RETRYABLE_STATUS_CODES = {429, 502, 503, 504}
RETRY_DELAYS_SECONDS = (0, 10, 30)


def token_fingerprint(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:12]


def main() -> int:
    api_base = os.environ.get("REMINDER_API_BASE", DEFAULT_API_BASE).strip().rstrip("/")
    token = os.environ.get("REMINDER_CRON_TOKEN", "").strip()
    if not token:
        print("[reminder-cron] REMINDER_CRON_TOKEN is missing", flush=True)
        return 2

    url = f"{api_base}/api/line/run-upcoming-reminders"
    fingerprint = token_fingerprint(token)
    print(
        f"[reminder-cron] calling {url} tokenFingerprint={fingerprint}",
        flush=True,
    )

    for attempt, delay in enumerate(RETRY_DELAYS_SECONDS, start=1):
        if delay:
            print(
                f"[reminder-cron] retrying in {delay}s attempt={attempt}",
                flush=True,
            )
            time.sleep(delay)

        request = urllib.request.Request(
            url,
            data=b"",
            headers={
                "x-reminder-token": token,
                "User-Agent": "smart-travel-reminder-cron/1.0",
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                body = response.read().decode("utf-8")
                print(f"[reminder-cron] HTTP {response.status}", flush=True)
                try:
                    payload = json.loads(body)
                    result = payload.get("data", payload)
                    print(
                        "[reminder-cron] result "
                        + json.dumps(
                            result,
                            ensure_ascii=False,
                            separators=(",", ":"),
                        ),
                        flush=True,
                    )
                except json.JSONDecodeError:
                    print(f"[reminder-cron] response {body}", flush=True)
            return 0
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            print(
                f"[reminder-cron] HTTP {error.code}: {body} attempt={attempt}",
                flush=True,
            )
            if (
                error.code not in RETRYABLE_STATUS_CODES
                or attempt == len(RETRY_DELAYS_SECONDS)
            ):
                return 1
        except Exception as error:
            print(f"[reminder-cron] failed: {error} attempt={attempt}", flush=True)
            if attempt == len(RETRY_DELAYS_SECONDS):
                return 1

    return 1


if __name__ == "__main__":
    sys.exit(main())
