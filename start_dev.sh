#!/usr/bin/env bash
set -euo pipefail

# Optional: put your secrets in .env.local (same folder as this script)
# Example .env.local:
#   SENDGRID_API_KEY=YOUR_SENDGRID_API_KEY
#   SENDGRID_FROM_EMAIL=smarttravel338@gmail.com
#   SENDGRID_FROM_NAME="Smart Travel"
#   PORT=8080
#   BACKEND_HOST=127.0.0.1
#   SMART_TRAVEL_EXPOSE_CODES=false
#   GOOGLE_MAPS_API_KEY=your-key
#   ADMIN_TOKEN=your-admin-token
#   ADMIN_USERNAME=admin
#   ADMIN_PASSWORD=admin123

ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$ROOT/.env.local" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env.local"
  set +a
fi

export PORT="${PORT:-8080}"
export SMART_TRAVEL_EXPOSE_CODES="${SMART_TRAVEL_EXPOSE_CODES:-false}"
export SENDGRID_API_KEY
export SENDGRID_FROM_EMAIL
export SENDGRID_FROM_NAME
export TWILIO_ACCOUNT_SID
export TWILIO_AUTH_TOKEN
export TWILIO_FROM_NUMBER
export ADMIN_TOKEN
export ADMIN_USERNAME
export ADMIN_PASSWORD

BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"

echo "Starting backend on port ${PORT}..."
cd "$ROOT/backend"
dart run bin/server.dart > "$ROOT/backend.log" 2>&1 &
BACKEND_PID=$!
echo "Backend started (PID=${BACKEND_PID}), logs: $ROOT/backend.log"

cleanup() {
  echo "Stopping backend (PID=${BACKEND_PID})..."
  kill "${BACKEND_PID}" 2>/dev/null || true
}
trap cleanup EXIT

cd "$ROOT"
flutter run \
  --dart-define=SMART_TRAVEL_API_BASE="http://${BACKEND_HOST}:${PORT}" \
  --dart-define=GOOGLE_MAPS_API_KEY="${GOOGLE_MAPS_API_KEY:-}"
