-- SmartMed's initial Supabase/PostgreSQL schema. Apply with:
--   supabase db push
-- Rollback guidance is in docs/database.md; clinical data is intentionally retained.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA IF NOT EXISTS smartmed_private;
REVOKE ALL ON SCHEMA smartmed_private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA smartmed_private TO authenticated;

CREATE TYPE public.app_role AS ENUM ('patient', 'doctor', 'caregiver', 'clinic_admin');
CREATE TYPE public.verification_status AS ENUM ('pending', 'verified', 'rejected', 'suspended');
CREATE TYPE public.assignment_status AS ENUM ('pending', 'active', 'revoked');
CREATE TYPE public.medication_status AS ENUM ('active', 'paused', 'completed', 'discontinued');
CREATE TYPE public.dose_status AS ENUM ('pending', 'taken', 'missed', 'skipped', 'cancelled');
CREATE TYPE public.dose_source AS ENUM ('manual', 'voice', 'caregiver', 'system');
CREATE TYPE public.appointment_status AS ENUM ('scheduled', 'confirmed', 'completed', 'cancelled', 'no_show', 'rescheduled');
CREATE TYPE public.appointment_type AS ENUM ('in_person', 'video', 'phone');
CREATE TYPE public.voice_request_status AS ENUM ('pending', 'confirmed', 'rejected', 'expired', 'consumed');
CREATE TYPE public.notification_status AS ENUM ('pending', 'processing', 'delivered', 'failed', 'cancelled');

CREATE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.has_unique_smallints(input_values smallint[])
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT cardinality(input_values) = (
    SELECT count(DISTINCT item) FROM unnest(input_values) AS items(item)
  );
$$;

CREATE FUNCTION public.reject_immutable_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME USING ERRCODE = '55000';
END;
$$;

CREATE FUNCTION public.protect_prescription_version()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'prescription versions cannot be deleted' USING ERRCODE = '55000';
  END IF;
  IF OLD.effective_until IS NOT NULL
     OR NEW.effective_until IS NULL
     OR (to_jsonb(NEW) - 'effective_until') IS DISTINCT FROM (to_jsonb(OLD) - 'effective_until') THEN
    RAISE EXCEPTION 'prescription versions are immutable except for closing an open interval'
      USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TABLE public.user_profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  full_name text NOT NULL CHECK (length(trim(full_name)) > 0),
  phone text,
  preferred_language text NOT NULL DEFAULT 'en' CHECK (preferred_language IN ('en', 'hi', 'te')),
  timezone text NOT NULL DEFAULT 'Asia/Kolkata',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.user_roles (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  role public.app_role NOT NULL,
  granted_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role)
);
CREATE INDEX user_roles_role_idx ON public.user_roles(role, user_id);

CREATE TABLE public.doctor_profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  registration_number text NOT NULL,
  registration_region text NOT NULL,
  specialization text,
  verification public.verification_status NOT NULL DEFAULT 'pending',
  verified_at timestamptz,
  verified_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (registration_region, registration_number),
  CHECK ((verification = 'verified') = (verified_at IS NOT NULL AND verified_by IS NOT NULL))
);

CREATE TABLE public.patient_profiles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  date_of_birth date,
  emergency_contact_name text,
  emergency_contact_phone text,
  accessibility_notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.clinics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(trim(name)) > 0),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.clinic_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id uuid NOT NULL REFERENCES public.clinics(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  role public.app_role NOT NULL CHECK (role IN ('doctor', 'clinic_admin')),
  active boolean NOT NULL DEFAULT true,
  granted_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (clinic_id, user_id)
);
CREATE INDEX clinic_memberships_user_idx ON public.clinic_memberships(user_id, active);

CREATE TABLE public.care_team_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES public.patient_profiles(user_id) ON DELETE RESTRICT,
  doctor_id uuid NOT NULL REFERENCES public.doctor_profiles(user_id) ON DELETE RESTRICT,
  status public.assignment_status NOT NULL DEFAULT 'pending',
  requested_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  approved_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (patient_id, doctor_id),
  CHECK ((status = 'active') = (approved_at IS NOT NULL AND revoked_at IS NULL)),
  CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);
CREATE INDEX care_team_patient_status_idx ON public.care_team_assignments(patient_id, status);
CREATE INDEX care_team_doctor_status_idx ON public.care_team_assignments(doctor_id, status);

CREATE TABLE public.caregiver_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES public.patient_profiles(user_id) ON DELETE RESTRICT,
  caregiver_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  status public.assignment_status NOT NULL DEFAULT 'pending',
  can_log_doses boolean NOT NULL DEFAULT false,
  can_view_medications boolean NOT NULL DEFAULT true,
  can_view_appointments boolean NOT NULL DEFAULT false,
  requested_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  approved_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (patient_id, caregiver_id),
  CHECK ((status = 'active') = (approved_at IS NOT NULL AND revoked_at IS NULL)),
  CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);
CREATE INDEX caregiver_assignments_patient_idx ON public.caregiver_assignments(patient_id, status);
CREATE INDEX caregiver_assignments_user_idx ON public.caregiver_assignments(caregiver_id, status);

CREATE TABLE public.medications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES public.patient_profiles(user_id) ON DELETE RESTRICT,
  medication_name text NOT NULL CHECK (length(trim(medication_name)) > 0),
  active_ingredient text,
  brand_name text,
  strength text,
  dosage_form text,
  route text,
  status public.medication_status NOT NULL DEFAULT 'active',
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  discontinued_at timestamptz,
  CHECK ((status = 'discontinued') = (discontinued_at IS NOT NULL))
);
CREATE INDEX medications_patient_status_idx ON public.medications(patient_id, status);

CREATE TABLE public.prescription_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  medication_id uuid NOT NULL REFERENCES public.medications(id) ON DELETE RESTRICT,
  version_number integer NOT NULL CHECK (version_number > 0),
  dosage_amount numeric(12,4) NOT NULL CHECK (dosage_amount > 0),
  dosage_unit text NOT NULL CHECK (length(trim(dosage_unit)) > 0),
  frequency_text text NOT NULL CHECK (length(trim(frequency_text)) > 0),
  instructions text,
  effective_from timestamptz NOT NULL,
  effective_until timestamptz,
  prescribed_by uuid NOT NULL REFERENCES public.doctor_profiles(user_id) ON DELETE RESTRICT,
  change_reason text NOT NULL CHECK (length(trim(change_reason)) > 0),
  source_reference text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (medication_id, version_number),
  CHECK (effective_until IS NULL OR effective_until > effective_from),
  EXCLUDE USING gist (
    medication_id WITH =,
    tstzrange(effective_from, effective_until, '[)') WITH &&
  )
);
CREATE INDEX prescription_versions_medication_effective_idx
  ON public.prescription_versions(medication_id, effective_from DESC);

CREATE TABLE public.medication_schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prescription_version_id uuid NOT NULL REFERENCES public.prescription_versions(id) ON DELETE RESTRICT,
  local_times time[] NOT NULL,
  -- ISO weekday numbering: Monday=0 through Sunday=6.
  days_of_week smallint[] NOT NULL DEFAULT ARRAY[0,1,2,3,4,5,6]::smallint[],
  start_date date NOT NULL,
  end_date date,
  reminder_enabled boolean NOT NULL DEFAULT true,
  grace_period_minutes integer NOT NULL DEFAULT 60,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (cardinality(local_times) > 0),
  CHECK (cardinality(days_of_week) > 0),
  CHECK (0 <= ALL(days_of_week) AND 6 >= ALL(days_of_week)),
  CHECK (public.has_unique_smallints(days_of_week)),
  CHECK (end_date IS NULL OR end_date >= start_date),
  CHECK (grace_period_minutes BETWEEN 0 AND 1440)
);
CREATE INDEX medication_schedules_prescription_idx ON public.medication_schedules(prescription_version_id);

CREATE TABLE public.dose_occurrences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES public.patient_profiles(user_id) ON DELETE RESTRICT,
  medication_id uuid NOT NULL REFERENCES public.medications(id) ON DELETE RESTRICT,
  schedule_id uuid REFERENCES public.medication_schedules(id) ON DELETE RESTRICT,
  scheduled_for timestamptz NOT NULL,
  status public.dose_status NOT NULL DEFAULT 'pending',
  recorded_at timestamptz,
  source public.dose_source,
  recorded_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  patient_reported_at timestamptz,
  notes text,
  idempotency_key uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (schedule_id, scheduled_for),
  UNIQUE (patient_id, idempotency_key),
  CHECK ((status IN ('taken', 'missed', 'skipped', 'cancelled')) = (recorded_at IS NOT NULL)),
  CHECK ((recorded_at IS NULL) = (source IS NULL AND recorded_by IS NULL))
);
CREATE INDEX dose_occurrences_patient_timeline_idx ON public.dose_occurrences(patient_id, scheduled_for DESC);
CREATE INDEX dose_occurrences_medication_timeline_idx ON public.dose_occurrences(medication_id, scheduled_for DESC);

CREATE FUNCTION public.validate_dose_occurrence()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  schedule_patient uuid;
  schedule_medication uuid;
BEGIN
  IF NEW.schedule_id IS NOT NULL THEN
    SELECT m.patient_id, m.id INTO schedule_patient, schedule_medication
    FROM public.medication_schedules s
    JOIN public.prescription_versions p ON p.id = s.prescription_version_id
    JOIN public.medications m ON m.id = p.medication_id
    WHERE s.id = NEW.schedule_id;
    IF schedule_patient IS DISTINCT FROM NEW.patient_id
       OR schedule_medication IS DISTINCT FROM NEW.medication_id THEN
      RAISE EXCEPTION 'dose patient, medication and schedule do not match' USING ERRCODE = '23514';
    END IF;
  ELSIF NOT EXISTS (
    SELECT 1 FROM public.medications m
    WHERE m.id = NEW.medication_id AND m.patient_id = NEW.patient_id
  ) THEN
    RAISE EXCEPTION 'dose medication does not belong to patient' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER dose_occurrence_consistency
  BEFORE INSERT OR UPDATE OF patient_id, medication_id, schedule_id
  ON public.dose_occurrences FOR EACH ROW EXECUTE FUNCTION public.validate_dose_occurrence();

CREATE TABLE public.dose_event_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  occurrence_id uuid NOT NULL REFERENCES public.dose_occurrences(id) ON DELETE RESTRICT,
  actor_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  action text NOT NULL CHECK (action IN ('created', 'marked_taken', 'marked_missed', 'marked_skipped', 'corrected', 'cancelled')),
  previous_status public.dose_status,
  new_status public.dose_status,
  reason text,
  source public.dose_source,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dose_event_history_occurrence_idx ON public.dose_event_history(occurrence_id, created_at DESC);

CREATE TABLE public.voice_confirmation_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES public.patient_profiles(user_id) ON DELETE RESTRICT,
  requested_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  medication_id uuid NOT NULL REFERENCES public.medications(id) ON DELETE RESTRICT,
  occurrence_id uuid REFERENCES public.dose_occurrences(id) ON DELETE RESTRICT,
  proposed_action text NOT NULL CHECK (proposed_action IN ('mark_taken', 'mark_skipped')),
  transcript text,
  token_hash text NOT NULL UNIQUE,
  status public.voice_request_status NOT NULL DEFAULT 'pending',
  expires_at timestamptz NOT NULL,
  confirmed_at timestamptz,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((status IN ('confirmed', 'consumed')) = (confirmed_at IS NOT NULL)),
  CHECK ((status = 'consumed') = (consumed_at IS NOT NULL))
);
CREATE INDEX voice_confirmation_patient_created_idx
  ON public.voice_confirmation_requests(patient_id, created_at DESC);
CREATE UNIQUE INDEX one_pending_voice_confirmation_per_occurrence
  ON public.voice_confirmation_requests(occurrence_id)
  WHERE status = 'pending' AND occurrence_id IS NOT NULL;

CREATE TABLE public.appointments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES public.patient_profiles(user_id) ON DELETE RESTRICT,
  doctor_id uuid NOT NULL REFERENCES public.doctor_profiles(user_id) ON DELETE RESTRICT,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  appointment_type public.appointment_type NOT NULL DEFAULT 'in_person',
  status public.appointment_status NOT NULL DEFAULT 'scheduled',
  reason text,
  patient_notes text,
  clinician_notes text,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  cancelled_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  cancelled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
  EXCLUDE USING gist (
    doctor_id WITH =,
    tstzrange(starts_at, ends_at, '[)') WITH &&
  ) WHERE (status NOT IN ('cancelled', 'rescheduled'))
);
CREATE INDEX appointments_patient_starts_idx ON public.appointments(patient_id, starts_at);
CREATE INDEX appointments_doctor_starts_idx ON public.appointments(doctor_id, starts_at);

CREATE TABLE public.symptom_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id uuid NOT NULL REFERENCES public.patient_profiles(user_id) ON DELETE RESTRICT,
  medication_id uuid REFERENCES public.medications(id) ON DELETE RESTRICT,
  reported_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  symptom_text text NOT NULL CHECK (length(trim(symptom_text)) > 0),
  severity smallint CHECK (severity BETWEEN 1 AND 5),
  started_at timestamptz,
  reported_at timestamptz NOT NULL DEFAULT now(),
  clinician_reviewed_by uuid REFERENCES public.doctor_profiles(user_id) ON DELETE RESTRICT,
  clinician_reviewed_at timestamptz,
  clinician_response text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((clinician_reviewed_by IS NULL) = (clinician_reviewed_at IS NULL))
);
CREATE INDEX symptom_reports_patient_reported_idx ON public.symptom_reports(patient_id, reported_at DESC);

CREATE TABLE public.clinical_audit_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  patient_id uuid REFERENCES public.patient_profiles(user_id) ON DELETE RESTRICT,
  action text NOT NULL,
  resource_type text NOT NULL,
  resource_id text NOT NULL,
  reason text,
  previous_values jsonb,
  new_values jsonb,
  request_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX clinical_audit_patient_created_idx ON public.clinical_audit_log(patient_id, created_at DESC);

CREATE TABLE public.notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  patient_id uuid REFERENCES public.patient_profiles(user_id) ON DELETE RESTRICT,
  event_type text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status public.notification_status NOT NULL DEFAULT 'pending',
  scheduled_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notification_outbox_pending_idx ON public.notification_outbox(status, scheduled_at)
  WHERE status IN ('pending', 'failed');
CREATE INDEX notification_outbox_recipient_idx ON public.notification_outbox(recipient_id, created_at DESC);

CREATE TABLE public.notification_delivery_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_id uuid NOT NULL REFERENCES public.notification_outbox(id) ON DELETE RESTRICT,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  succeeded boolean NOT NULL,
  provider text NOT NULL,
  provider_reference text,
  error_code text
);
CREATE INDEX notification_attempts_notification_idx
  ON public.notification_delivery_attempts(notification_id, attempted_at DESC);

CREATE FUNCTION public.record_dose_status_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.dose_event_history (occurrence_id, actor_id, action, new_status, source)
    VALUES (NEW.id, NEW.recorded_by, 'created', NEW.status, NEW.source);
  ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO public.dose_event_history
      (occurrence_id, actor_id, action, previous_status, new_status, reason, source)
    VALUES (
      NEW.id, NEW.recorded_by,
      CASE NEW.status
        WHEN 'taken' THEN 'marked_taken'
        WHEN 'missed' THEN 'marked_missed'
        WHEN 'skipped' THEN 'marked_skipped'
        WHEN 'cancelled' THEN 'cancelled'
        ELSE 'corrected'
      END,
      OLD.status, NEW.status, NEW.notes, NEW.source
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.validate_dose_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status AND OLD.status <> 'pending' THEN
    RAISE EXCEPTION 'terminal dose status cannot be changed' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER dose_transition_guard
  BEFORE UPDATE OF status ON public.dose_occurrences
  FOR EACH ROW EXECUTE FUNCTION public.validate_dose_transition();

CREATE FUNCTION public.validate_prescription_authorization()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE target_patient uuid;
BEGIN
  SELECT patient_id INTO target_patient
  FROM public.medications WHERE id = NEW.medication_id;
  IF auth.uid() IS DISTINCT FROM NEW.prescribed_by
     OR NOT smartmed_private.is_verified_doctor_for_patient(target_patient) THEN
    RAISE EXCEPTION 'verified doctor authorization required' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER prescription_authorization
  BEFORE INSERT ON public.prescription_versions
  FOR EACH ROW EXECUTE FUNCTION public.validate_prescription_authorization();

CREATE FUNCTION public.validate_appointment_authorization()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT smartmed_private.is_verified_doctor_assigned(NEW.doctor_id, NEW.patient_id)
     OR auth.uid() NOT IN (NEW.patient_id, NEW.doctor_id) THEN
    RAISE EXCEPTION 'appointment access authorization required' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER appointment_authorization
  BEFORE INSERT OR UPDATE ON public.appointments
  FOR EACH ROW EXECUTE FUNCTION public.validate_appointment_authorization();

CREATE TRIGGER dose_status_history
  AFTER INSERT OR UPDATE OF status ON public.dose_occurrences
  FOR EACH ROW EXECUTE FUNCTION public.record_dose_status_change();
CREATE TRIGGER dose_event_history_immutable
  BEFORE UPDATE OR DELETE ON public.dose_event_history
  FOR EACH ROW EXECUTE FUNCTION public.reject_immutable_change();
CREATE TRIGGER clinical_audit_immutable
  BEFORE UPDATE OR DELETE ON public.clinical_audit_log
  FOR EACH ROW EXECUTE FUNCTION public.reject_immutable_change();
CREATE TRIGGER prescription_versions_immutable
  BEFORE UPDATE OR DELETE ON public.prescription_versions
  FOR EACH ROW EXECUTE FUNCTION public.protect_prescription_version();

DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'user_profiles', 'doctor_profiles', 'patient_profiles', 'clinics', 'clinic_memberships',
    'care_team_assignments', 'caregiver_assignments', 'medications', 'dose_occurrences',
    'appointments', 'notification_outbox'
  ] LOOP
    EXECUTE format(
      'CREATE TRIGGER %I_set_updated_at BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()',
      table_name, table_name
    );
  END LOOP;
END;
$$;

-- Helpers run with a fixed search_path and expose only narrowly scoped predicates.
CREATE FUNCTION smartmed_private.is_verified_doctor_assigned(target_doctor uuid, target_patient uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.doctor_profiles d
    JOIN public.care_team_assignments a ON a.doctor_id = d.user_id
    WHERE d.user_id = target_doctor AND d.verification = 'verified'
      AND a.patient_id = target_patient AND a.status = 'active'
  );
$$;

CREATE FUNCTION smartmed_private.is_verified_doctor_for_patient(target_patient uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT smartmed_private.is_verified_doctor_assigned(auth.uid(), target_patient);
$$;

CREATE FUNCTION smartmed_private.has_caregiver_permission(target_patient uuid, permission_name text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.caregiver_assignments a
    WHERE a.caregiver_id = auth.uid() AND a.patient_id = target_patient
      AND a.status = 'active'
      AND CASE permission_name
        WHEN 'can_log_doses' THEN a.can_log_doses
        WHEN 'can_view_medications' THEN a.can_view_medications
        WHEN 'can_view_appointments' THEN a.can_view_appointments
        ELSE false
      END
  );
$$;

CREATE FUNCTION smartmed_private.can_access_patient(target_patient uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT auth.uid() = target_patient
    OR smartmed_private.is_verified_doctor_for_patient(target_patient)
    OR EXISTS (
      SELECT 1 FROM public.caregiver_assignments a
      WHERE a.caregiver_id = auth.uid() AND a.patient_id = target_patient
        AND a.status = 'active'
    );
$$;

REVOKE ALL ON FUNCTION smartmed_private.is_verified_doctor_assigned(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION smartmed_private.is_verified_doctor_for_patient(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION smartmed_private.has_caregiver_permission(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION smartmed_private.can_access_patient(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION smartmed_private.is_verified_doctor_assigned(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION smartmed_private.is_verified_doctor_for_patient(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION smartmed_private.has_caregiver_permission(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION smartmed_private.can_access_patient(uuid) TO authenticated;

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinic_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.care_team_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.caregiver_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.prescription_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medication_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dose_occurrences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dose_event_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voice_confirmation_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.appointments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.symptom_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinical_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_delivery_attempts ENABLE ROW LEVEL SECURITY;

CREATE POLICY profiles_read_self ON public.user_profiles FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY profiles_read_authorized_patient ON public.user_profiles FOR SELECT TO authenticated
  USING (smartmed_private.is_verified_doctor_for_patient(user_id));
CREATE POLICY profiles_insert_self ON public.user_profiles FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY profiles_update_self ON public.user_profiles FOR UPDATE TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY roles_read_self ON public.user_roles FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY doctor_profiles_read_owner ON public.doctor_profiles FOR SELECT TO authenticated
  USING (user_id = auth.uid());
CREATE POLICY patient_profiles_read_authorized ON public.patient_profiles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR smartmed_private.is_verified_doctor_for_patient(user_id));
CREATE POLICY patient_profiles_insert_self ON public.patient_profiles FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE FUNCTION smartmed_private.is_active_clinic_member(target_clinic uuid, required_role public.app_role DEFAULT NULL)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.clinic_memberships cm
    WHERE cm.clinic_id = target_clinic AND cm.user_id = auth.uid() AND cm.active
      AND (required_role IS NULL OR cm.role = required_role)
  );
$$;
REVOKE ALL ON FUNCTION smartmed_private.is_active_clinic_member(uuid, public.app_role) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION smartmed_private.is_active_clinic_member(uuid, public.app_role) TO authenticated;
CREATE POLICY clinics_read_member ON public.clinics FOR SELECT TO authenticated
  USING (smartmed_private.is_active_clinic_member(id));
CREATE POLICY memberships_read_same_clinic ON public.clinic_memberships FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR smartmed_private.is_active_clinic_member(clinic_id, 'clinic_admin'));
CREATE POLICY care_team_patient_read ON public.care_team_assignments FOR SELECT TO authenticated USING (patient_id = auth.uid());
CREATE POLICY care_team_doctor_read ON public.care_team_assignments FOR SELECT TO authenticated USING (doctor_id = auth.uid());
CREATE POLICY caregiver_assignment_read ON public.caregiver_assignments FOR SELECT TO authenticated
  USING (patient_id = auth.uid() OR caregiver_id = auth.uid());

CREATE POLICY medications_read_authorized ON public.medications FOR SELECT TO authenticated
  USING (
    patient_id = auth.uid()
    OR smartmed_private.is_verified_doctor_for_patient(patient_id)
    OR smartmed_private.has_caregiver_permission(patient_id, 'can_view_medications')
  );
CREATE POLICY prescriptions_read_authorized ON public.prescription_versions FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.medications m WHERE m.id = medication_id
      AND (m.patient_id = auth.uid()
        OR smartmed_private.is_verified_doctor_for_patient(m.patient_id)
        OR smartmed_private.has_caregiver_permission(m.patient_id, 'can_view_medications'))
  ));
CREATE POLICY schedules_read_authorized ON public.medication_schedules FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.prescription_versions p JOIN public.medications m ON m.id = p.medication_id
    WHERE p.id = prescription_version_id AND (
      m.patient_id = auth.uid()
      OR smartmed_private.is_verified_doctor_for_patient(m.patient_id)
      OR smartmed_private.has_caregiver_permission(m.patient_id, 'can_view_medications')
    )
  ));
CREATE POLICY doses_read_authorized ON public.dose_occurrences FOR SELECT TO authenticated
  USING (
    patient_id = auth.uid()
    OR smartmed_private.is_verified_doctor_for_patient(patient_id)
    OR smartmed_private.has_caregiver_permission(patient_id, 'can_view_medications')
    OR smartmed_private.has_caregiver_permission(patient_id, 'can_log_doses')
  );
CREATE POLICY dose_history_read_authorized ON public.dose_event_history FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.dose_occurrences d
    WHERE d.id = occurrence_id AND (
      d.patient_id = auth.uid()
      OR smartmed_private.is_verified_doctor_for_patient(d.patient_id)
      OR smartmed_private.has_caregiver_permission(d.patient_id, 'can_view_medications')
      OR smartmed_private.has_caregiver_permission(d.patient_id, 'can_log_doses')
    )
  ));
CREATE POLICY symptoms_read_authorized ON public.symptom_reports FOR SELECT TO authenticated
  USING (patient_id = auth.uid() OR smartmed_private.is_verified_doctor_for_patient(patient_id));
CREATE POLICY symptoms_insert_self ON public.symptom_reports FOR INSERT TO authenticated
  WITH CHECK (patient_id = auth.uid() AND reported_by = auth.uid());
CREATE POLICY audit_read_authorized_doctor ON public.clinical_audit_log FOR SELECT TO authenticated
  USING (patient_id IS NOT NULL AND smartmed_private.is_verified_doctor_for_patient(patient_id));
CREATE POLICY notifications_read_recipient ON public.notification_outbox FOR SELECT TO authenticated
  USING (recipient_id = auth.uid());
CREATE POLICY notification_attempts_read_recipient ON public.notification_delivery_attempts FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.notification_outbox n
    WHERE n.id = notification_id AND n.recipient_id = auth.uid()
  ));

-- Appointment rows and voice token hashes are available only through safe projections
-- and authenticated backend operations, never as unrestricted table selects.
REVOKE SELECT ON public.appointments FROM anon, authenticated;
REVOKE ALL ON public.voice_confirmation_requests FROM anon, authenticated;
CREATE VIEW public.patient_appointments WITH (security_barrier = true) AS
  SELECT id, patient_id, doctor_id, starts_at, ends_at, appointment_type, status,
         reason, patient_notes, created_at, updated_at
  FROM public.appointments
  WHERE patient_id = auth.uid();
CREATE VIEW public.doctor_appointments WITH (security_barrier = true) AS
  SELECT id, patient_id, doctor_id, starts_at, ends_at, appointment_type, status,
         reason, patient_notes, clinician_notes, created_by, cancelled_by, cancelled_at,
         created_at, updated_at
  FROM public.appointments
  WHERE smartmed_private.is_verified_doctor_for_patient(patient_id);
CREATE VIEW public.caregiver_appointments WITH (security_barrier = true) AS
  SELECT id, patient_id, doctor_id, starts_at, ends_at, appointment_type, status,
         reason, patient_notes, created_at, updated_at
  FROM public.appointments
  WHERE smartmed_private.has_caregiver_permission(patient_id, 'can_view_appointments');
GRANT SELECT ON public.patient_appointments, public.doctor_appointments,
  public.caregiver_appointments TO authenticated;

-- No authenticated INSERT/UPDATE/DELETE policies exist for roles, doctor verification,
-- prescriptions, audit history, notifications, or assignment activation. Trusted backend
-- operations must use a narrowly scoped administrative database role/workflow and re-check
-- the caller in application services; never expose the Supabase service-role key.
