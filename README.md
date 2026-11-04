# SmartMed

SmartMed keeps the doctor website, patient Flutter app, and FastAPI backend in separate folders while sharing one Supabase PostgreSQL database and authentication project.

## Current implementation

- Versioned Supabase/PostgreSQL schema with clinical tables, RLS, indexes, consistency constraints, audit/event history, and notification outbox.
- FastAPI health, profile, role, patient profile, doctor roster, appointment, and patient-chart endpoints under `/api/v1`.
- Backend access-token verification against configured Supabase JWKS, issuer, and audience.
- Per-request PostgreSQL transaction context carrying verified JWT claims so RLS can evaluate `auth.uid()`.
- A React doctor portal in `doctor-portal/` for assigned-patient, appointment, medication, and symptom review. Patient access is limited to verified doctors with active patient-approved assignments.
- A Flutter patient app scaffold in `patient-app/` with Supabase sign-in and an authenticated request to the shared FastAPI profile endpoint.
- Authenticated MP3 validation and direct Gemini audio interpretation; the interpretation endpoint never mutates clinical records.
- No client-side role granting or service-role key in either client configuration.

The doctor website currently provides read-only clinical review. Appointment scheduling, prescription changes, symptom-response writes, and patient dose workflows remain unavailable until their audited backend transactions are implemented; the UI does not pretend those writes succeeded.

## Requirements

- Python 3.12 or newer.
- A Supabase project (local Supabase CLI is recommended for development).
- Flutter SDK for the patient app.
- Node.js LTS for the doctor portal.
- Gemini API key only for live direct-audio voice processing; the core backend does not require it to start.

## Backend setup (Windows PowerShell)

From the repository root:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -e ".\backend[dev]"
Copy-Item .\backend\.env.example .\backend\.env
```

Set `DATABASE_URL`, `JWT_ISSUER`, and `JWT_JWKS_URL` in `backend\.env` for the local Supabase project. The JWT issuer is the project's Auth issuer, and the JWKS endpoint is the issuer's `/.well-known/jwks.json`. Never put service-role credentials in a client or commit `.env`.

Apply the SQL migration to a fresh local Supabase database:

```powershell
supabase start
supabase db reset
```

Start the backend:

```powershell
python -m uvicorn app.main:app --app-dir backend --reload --host 127.0.0.1 --port 8000
```

- Health: <http://127.0.0.1:8000/health>
- Swagger UI: <http://127.0.0.1:8000/docs>
- OpenAPI: <http://127.0.0.1:8000/api/v1/openapi.json>

Run backend checks:

```powershell
python -m pytest .\backend\tests
python -m compileall .\backend\app
```

Use the project's `DATABASE_URL` format `postgresql+asyncpg://...`. API database transactions explicitly assume the PostgreSQL `authenticated` role before executing statements, so RLS applies even when a local connection is established as the Supabase `postgres` user. A verified Supabase access token is required for `/api/v1` endpoints. Development mode starts without external credentials and returns explicit unavailable errors for unconfigured services; production startup requires database, JWT issuer/JWKS, and Gemini model/key settings. Database connectivity and a live Supabase JWT were not verified as part of this initial foundation.

## Doctor website

From the repository root:

```powershell
Copy-Item .\doctor-portal\.env.example .\doctor-portal\.env.local
```

Set `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, and `VITE_API_BASE_URL` in `doctor-portal\.env.local`. The anon key is public client configuration; never place a Supabase service-role key in the website. The portal uses Supabase Auth for sign-in and sends the access token to the FastAPI backend for all clinical data.

```powershell
Set-Location .\doctor-portal
npm install
npm run dev
```

Open <http://localhost:5173>. The API's `CORS_ALLOWED_ORIGINS` must include this origin. A verified doctor profile and an active care-team assignment are required for patient data.

## Flutter patient app scaffold

The Flutter source app and generated Android/web runners are isolated under `patient-app/`. From that folder, resolve packages and run static analysis:

```powershell
Set-Location .\patient-app
flutter pub get
flutter analyze
```

Copy `patient-app\.env.example` to `patient-app\.env.local.json`, set the same Supabase URL/public publishable key used by the backend, then run `flutter run --dart-define-from-file=.env.local.json`. The default API URL is `http://10.0.2.2:8000` for the Android emulator. Override `API_BASE_URL` for other targets (for example, `http://127.0.0.1:8000` on iOS simulator or web). The app signs in with Supabase Auth and uses the authenticated FastAPI profile endpoint; patient workflows can be added without mixing app files into the website.

Build a debug Android APK with `flutter build apk --debug --dart-define-from-file=.env.local.json`; output is `patient-app\build\app\outputs\flutter-apk\app-debug.apk`.

## Architecture and safety

Configure `GEMINI_API_KEY` and `GEMINI_MODEL` for live voice interpretation. See [docs/database.md](docs/database.md), [docs/voice-flow.md](docs/voice-flow.md), [doctor-portal/README.md](doctor-portal/README.md), and [patient-app/README.md](patient-app/README.md). Clinical writes are not exposed as placeholder endpoints. Doctor portal data is read through authenticated FastAPI routes and PostgreSQL row-level security; neither client connects to PostgreSQL directly.
