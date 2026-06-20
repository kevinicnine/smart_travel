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
#   GOOGLE_PLACES_SERVER_API_KEY=your-server-key
#   ADMIN_TOKEN=your-admin-token
#   ADMIN_USERNAME=admin
#   ADMIN_PASSWORD=admin123
#   OPENAI_API_KEY=sk-...
#   OPENAI_MODEL=gpt-4o-mini
#   USE_RENDER=true
#   RENDER_API_BASE=https://smart-travel-backend-6ant.onrender.com

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
export LINE_CHANNEL_SECRET
export LINE_CHANNEL_ACCESS_TOKEN
export LINE_ADD_FRIEND_URL
export ADMIN_TOKEN
export ADMIN_USERNAME
export ADMIN_PASSWORD
export OPENAI_API_KEY
export OPENAI_MODEL
export OPENAI_BASE_URL
export FLUTTER_DEVICE

BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
FLUTTER_DEVICE="${FLUTTER_DEVICE:-iPhone 16e}"
USE_RENDER="${USE_RENDER:-true}"
RENDER_API_BASE="${RENDER_API_BASE:-https://smart-travel-backend-6ant.onrender.com}"

if [[ "${USE_RENDER}" != "true" ]]; then
  EXISTING_BACKEND_PID="$(lsof -tiTCP:"${PORT}" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
  if [[ -n "${EXISTING_BACKEND_PID}" ]]; then
    EXISTING_BACKEND_COMMAND="$(ps -p "${EXISTING_BACKEND_PID}" -o command= 2>/dev/null || true)"
    if [[ "${EXISTING_BACKEND_COMMAND}" == *dart* && "${EXISTING_BACKEND_COMMAND}" == *server.dart* ]]; then
      echo "Stopping stale backend on port ${PORT} (PID=${EXISTING_BACKEND_PID})..."
      kill "${EXISTING_BACKEND_PID}" 2>/dev/null || true
      for _ in {1..20}; do
        if ! lsof -tiTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
          break
        fi
        sleep 0.25
      done
    else
      echo "Port ${PORT} is already used by another process: ${EXISTING_BACKEND_COMMAND}" >&2
      exit 1
    fi
  fi

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
else
  echo "Using Render backend: ${RENDER_API_BASE}"
fi

cd "$ROOT"
API_BASE="http://${BACKEND_HOST}:${PORT}"
if [[ "${USE_RENDER}" == "true" ]]; then
  API_BASE="${RENDER_API_BASE}"
fi
flutter run \
  -d "${FLUTTER_DEVICE}" \
  --dart-define=SMART_TRAVEL_API_BASE="${API_BASE}" \
  --dart-define=GOOGLE_MAPS_API_KEY="${GOOGLE_MAPS_API_KEY:-}"
