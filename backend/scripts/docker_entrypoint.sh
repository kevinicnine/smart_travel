#!/bin/sh
set -eu

if [ "${SERVICE_MODE:-web}" = "reminder-cron" ]; then
  echo "[entrypoint] starting reminder cron runner"
  exec python3 scripts/run_reminder_cron.py
fi

echo "[entrypoint] starting web backend"
exec dart run bin/server.dart
