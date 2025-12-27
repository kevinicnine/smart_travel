# smart_travel

Flutter app for experimenting with an itinerary planner UI and a lightweight backend used by the auth / registration screens.

## Frontend

```bash
flutter pub get
flutter run \
  --dart-define=SMART_TRAVEL_API_BASE=http://10.0.2.2:8080
```

The UI flow currently goes Start → Login → (Register / Forgot password) → Select interests → Home.

- `SMART_TRAVEL_API_BASE` defaults to `http://localhost:8080`. Override it (as shown above) when running on emulators/devices that cannot reach `localhost` directly.

## Backend API

A Dart `shelf` server that provides the missing registration/verification/password-reset functionality expected by the front-end forms lives in `backend/`.

### Run locally

```bash
cd backend
dart pub get        # already run but harmless
dart run bin/server.dart
```

Configuration (all optional):

| Variable | Description |
| --- | --- |
| `PORT` | Port to listen on (default `8080`). |
| `SMART_TRAVEL_DATA_DIR` | Directory that stores `db.json` (defaults to `backend/data`). |
| `SMART_TRAVEL_EXPOSE_CODES` | When `true` (default) responses include `debugCode` to make manual testing easier. Set to `false` in production. |
| `SENDGRID_API_KEY` / `SENDGRID_FROM_EMAIL` / `SENDGRID_FROM_NAME` | When set, verification/reset codes are emailed via SendGrid. |
| `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` / `TWILIO_FROM_NUMBER` | When set, verification codes are sent through Twilio SMS. |

User records are stored as JSON in `backend/data/db.json`. You can safely delete that file to reset the backend state; it will be recreated automatically.

> 若未設定 SendGrid / Twilio 相關環境變數，伺服器仍會產生驗證碼並可在回應 `debugCode` 看到，但實際郵件與簡訊不會送出；設好上述變數後就會真實寄送。

### API overview

| Method & Path | Description |
| --- | --- |
| `GET /health` | Health check. |
| `POST /api/auth/send-email-code` | Send verification code to email (register flow). |
| `POST /api/auth/verify-email-code` | Validate email verification code. |
| `POST /api/auth/send-sms-code` | Send SMS verification code. |
| `POST /api/auth/verify-sms-code` | Validate SMS verification code. |
| `POST /api/auth/register` | Create an account (requires the email + sms verification steps). |
| `POST /api/auth/login` | Login by username or email + password. |
| `POST /api/auth/reset-password/code` | Send password-reset verification code. |
| `POST /api/auth/reset-password/verify` | Validate the password-reset code. |
| `POST /api/auth/reset-password/complete` | Update password after successful verification. |

All responses are JSON with a `{ "success": bool, "message": "...", "data": {...} }` structure. For dev/testing the verification endpoints return the generated code under `data.debugCode`; hide this in production by setting `SMART_TRAVEL_EXPOSE_CODES=false`.

### Typical registration flow

1. `POST /api/auth/send-email-code` with `{ "email": "demo@mail.com" }`
2. `POST /api/auth/send-sms-code` with `{ "phone": "0911..." }`
3. User enters both codes → app calls the two `/verify-...` endpoints.
4. Submit the register form via `POST /api/auth/register` with `username`, `email`, `phone`, `password`.

Password reset works similarly: request a code, verify it, then call `/reset-password/complete` with `account`, `email`, `code`, and `newPassword`.
