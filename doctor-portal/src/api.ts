import { createClient, type Session } from "@supabase/supabase-js";

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;
export const apiBaseUrl = (
  import.meta.env.VITE_API_BASE_URL ?? "http://127.0.0.1:8000"
).replace(/\/$/, "");

export const configurationError =
  !supabaseUrl || !supabaseAnonKey
    ? "Add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY to doctor-portal/.env.local."
    : null;

export const supabase =
  supabaseUrl && supabaseAnonKey
    ? createClient(supabaseUrl, supabaseAnonKey, {
      auth: { autoRefreshToken: true, detectSessionInUrl: true, persistSession: true },
      })
    : null;

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export async function apiGet<T>(path: string, session: Session): Promise<T> {
  const response = await fetch(`${apiBaseUrl}/api/v1${path}`, {
    headers: { Authorization: `Bearer ${session.access_token}` },
  });
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { detail?: string };
    throw new ApiError(body.detail ?? `Request failed (${response.status})`, response.status);
  }
  return (await response.json()) as T;
}

export interface DoctorProfile {
  user_id: string;
  full_name: string;
  specialization: string | null;
  verification: string;
}

export interface PatientSummary {
  user_id: string;
  full_name: string;
  phone: string | null;
  date_of_birth: string | null;
  active_medication_count: number;
  latest_symptom_at: string | null;
}

export interface DoctorAppointment {
  id: string;
  patient_id: string;
  patient_name: string;
  starts_at: string;
  ends_at: string;
  appointment_type: "in_person" | "video" | "phone";
  status: "scheduled" | "confirmed" | "completed" | "cancelled" | "no_show" | "rescheduled";
  reason: string | null;
  patient_notes: string | null;
  clinician_notes: string | null;
}

export interface PatientDetail extends Omit<PatientSummary, "active_medication_count" | "latest_symptom_at"> {
  accessibility_notes: string | null;
  medications: {
    medication_id: string;
    medication_name: string;
    strength: string | null;
    dosage_amount: number | null;
    dosage_unit: string | null;
    frequency_text: string | null;
    instructions: string | null;
    effective_from: string | null;
    schedule_times: string[];
  }[];
  symptoms: {
    id: string;
    symptom_text: string;
    severity: number | null;
    reported_at: string;
    clinician_response: string | null;
  }[];
}
