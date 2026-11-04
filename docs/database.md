# Database and access-control foundation

`supabase/migrations/20261019205513_initial.sql` is the canonical initial Supabase/PostgreSQL schema. It defines the requested clinical entities, append-only prescription and audit history, outbox delivery attempts, constraints, indexes, triggers, and RLS policies.

## Apply locally

With Supabase CLI installed and a local stack running:

```powershell
supabase start
supabase db reset
```

The initial migration is designed to be applied to a fresh Supabase database. Do not edit an applied migration in a shared environment; create a later forward migration instead.

## Rollback

There is deliberately no destructive `DROP TABLE` rollback for this clinical-data schema. For a disposable local database, `supabase db reset` recreates the local database from migrations and seed files. For deployed environments, add a reviewed forward migration and preserve clinical records; restoring a backup is the recovery path for an accidental destructive change.

## Important invariants

- Schedule weekday values use ISO numbering adjusted to zero-based arrays: Monday `0` through Sunday `6`.
- `local_times` represent wall-clock times in the patient's IANA timezone. Convert each scheduled local date/time to an instant with timezone-aware rules before inserting an occurrence; do not assume UTC.
- A prescription version interval is half-open `[effective_from, effective_until)` and may not overlap another version for the same medication. Versions are immutable except that an open version may be closed once when superseded.
- Scheduled dose uniqueness is `(schedule_id, scheduled_for)`. Idempotency keys are unique per patient when non-null.
- Dose and clinical audit history are append-only. RLS has no ordinary-client write policies for prescriptions, role grants, audit entries, voice confirmations, or appointment changes.
- Doctor access depends on a verified doctor profile and an active patient-approved assignment. Caregiver permission flags are independent; appointment access uses a projection that omits private clinician notes.
- Authorization predicates live in the non-API `smartmed_private` schema. Keep that schema out of Supabase's exposed schemas; do not publish it through PostgREST.
- RLS helpers are narrowly scoped authorization predicates; they are not a replacement for endpoint authorization.
- A `taken` dose is a patient/caregiver report, not proof of ingestion.

## Remaining production hardening

Privileged workflows (doctor verification, assignment activation/revocation, prescription changes, appointment writes, and voice confirmation) must be exposed only through authenticated backend transactions that verify actor, patient, active relationship, state transitions, and audit writes together. Do not expose a Supabase service-role key to either client or use it as a substitute for these checks. Appointment and prescription exclusion constraints provide concurrency-safe overlap protection.
