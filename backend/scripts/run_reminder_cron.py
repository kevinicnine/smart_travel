#!/usr/bin/env python3

import json
import os
import sys
import urllib.error
import urllib.request


DEFAULT_API_BASE = "https://smart-travel-6zsf.onrender.com"


def main() -> int:
    api_base = os.environ.get("REMINDER_API_BASE", DEFAULT_API_BASE).strip().rstrip("/")
    token = os.environ.get("REMINDER_CRON_TOKEN", "").strip()
    if not token:
        print("[reminder-cron] REMINDER_CRON_TOKEN is missing", flush=True)
        return 2

    url = f"{api_base}/api/line/run-upcoming-reminders"
    print(f"[reminder-cron] calling {url}", flush=True)
    request = urllib.request.Request(
        url,
        data=b"",
        headers={"x-reminder-token": token},
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
                    + json.dumps(result, ensure_ascii=False, separators=(",", ":")),
                    flush=True,
                )
            except json.JSONDecodeError:
                print(f"[reminder-cron] response {body}", flush=True)
        return 0
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        print(f"[reminder-cron] HTTP {error.code}: {body}", flush=True)
        return 1
    except Exception as error:
        print(f"[reminder-cron] failed: {error}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
