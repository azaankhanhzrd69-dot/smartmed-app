# SmartMed Patient App

This folder contains only the Flutter patient application source and its package configuration. The doctor website lives separately in `doctor-portal/`. Both clients use the shared Supabase Auth project and FastAPI backend.

## Build

Flutter Android and web runners are already generated. With Flutter, Java 17, and the Android SDK installed, from this folder resolve dependencies and analyze:

```powershell
flutter pub get
flutter analyze
```

The source scaffold includes Supabase email/password sign-in and a bearer-authenticated request to `GET /api/v1/me`. No database or service-role credentials are stored in the app.

## Run

Create a local Dart define file from the template and set it to the same Supabase project as the backend:

```powershell
Copy-Item .\.env.example .\.env.local.json
```

Update `.env.local.json` with the project URL and public publishable key from Supabase (the backend `.env` contains the same client configuration under `SUPABASE_ANON_KEY`). This local file is git-ignored. For an Android emulator, run:

```powershell
flutter run --dart-define-from-file=.env.local.json
```

To build a debug Android APK:

```powershell
flutter build apk --debug --dart-define-from-file=.env.local.json
```

The APK is written to `build\app\outputs\flutter-apk\app-debug.apk`. The API defaults to `http://10.0.2.2:8000` for Android emulators. Debug Android builds allow HTTP for this local API; use HTTPS for non-local/release deployments. Set `--dart-define=API_BASE_URL=...` to use another host (for example, `http://127.0.0.1:8000` for iOS simulator or web).

For a local Windows development backend, `10.0.2.2` is the Android emulator's host-machine alias. Use the host's reachable LAN address for a physical device, and `http://127.0.0.1:8000` for desktop/web. Do not include the Supabase service-role key in the app.

The production web build can be created with `flutter build web --dart-define-from-file=.env.local.json`. For web, set `API_BASE_URL` to a reachable HTTPS API URL and allow the deployed web origin in the backend CORS configuration.
