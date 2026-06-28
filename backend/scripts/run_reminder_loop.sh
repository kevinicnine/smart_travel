#!/bin/sh
set -eu

interval="${REMINDER_INTERVAL_SECONDS:-300}"

if [ "${interval}" -lt 30 ] 2>/dev/null; then
  echo "[reminder-loop] REMINDER_INTERVAL_SECONDS must be >= 30" >&2
  exit 2
fi

echo "[reminder-loop] starting interval=${interval}s api=${REMINDER_API_BASE:-unset}"

while true; do
  if python3 scripts/run_reminder_cron.py; then
    echo "[reminder-loop] run completed"
  else
    echo "[reminder-loop] run failed but service will keep retrying" >&2
  fi

  sleep "${interval}" &
  wait $!
done
