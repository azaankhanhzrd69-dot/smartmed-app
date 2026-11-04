# SmartMed Doctor Portal

The doctor website is a separate React/Vite app. It authenticates with Supabase Auth and calls the shared FastAPI backend; it never queries Supabase clinical tables directly.

## Run locally

From the repository root:

```powershell
Copy-Item .\doctor-portal\.env.example .\doctor-portal\.env.local
Set-Location .\doctor-portal
npm install
npm run dev
```

Set the Supabase project URL, public anon key, and API base URL in `.env.local`. The public anon key is safe for client use; do not use a service-role key. The API CORS allowlist must include `http://localhost:5173`.

## Available interface

- Overview with active patient, upcoming appointment, and symptom-report counts.
- Assigned-patient directory and patient chart with active medications and reported symptoms.
- Upcoming appointments and recent appointment history.
- Secure sign-in, persisted Supabase session, and sign-out.

Every doctor API route requires a verified doctor profile. Patient data is returned only where the authenticated doctor has an active care-team assignment, with PostgreSQL RLS applied in the API transaction. Clinical writes and appointment scheduling are not available in this read-only release.
