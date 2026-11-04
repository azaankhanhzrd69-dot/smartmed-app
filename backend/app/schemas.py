from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


class ProfileResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    user_id: UUID
    full_name: str
    phone: str | None
    preferred_language: Literal["en", "hi", "te"]
    timezone: str
    created_at: datetime
    updated_at: datetime


class ProfilePatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    full_name: str | None = Field(default=None, min_length=1, max_length=200)
    phone: str | None = Field(default=None, max_length=40)
    preferred_language: Literal["en", "hi", "te"] | None = None
    timezone: str | None = Field(default=None, min_length=1, max_length=100)


class PatientProfileResponse(BaseModel):
    user_id: UUID
    date_of_birth: date | None
    emergency_contact_name: str | None
    emergency_contact_phone: str | None
    accessibility_notes: str | None
    created_at: datetime
    updated_at: datetime


class RolesResponse(BaseModel):
    roles: list[Literal["patient", "doctor", "caregiver", "clinic_admin"]]


class DoctorProfileResponse(BaseModel):
    user_id: UUID
    full_name: str
    email: str | None = None
    specialization: str | None
    verification: Literal["pending", "verified", "rejected", "suspended"]


class DoctorPatientSummary(BaseModel):
    user_id: UUID
    full_name: str
    phone: str | None
    date_of_birth: date | None
    active_medication_count: int
    latest_symptom_at: datetime | None


class DoctorAppointmentResponse(BaseModel):
    id: UUID
    patient_id: UUID
    patient_name: str
    starts_at: datetime
    ends_at: datetime
    appointment_type: Literal["in_person", "video", "phone"]
    status: Literal["scheduled", "confirmed", "completed", "cancelled", "no_show", "rescheduled"]
    reason: str | None
    patient_notes: str | None
    clinician_notes: str | None


class DoctorMedicationResponse(BaseModel):
    medication_id: UUID
    medication_name: str
    strength: str | None
    dosage_amount: float | None
    dosage_unit: str | None
    frequency_text: str | None
    instructions: str | None
    effective_from: datetime | None
    schedule_times: list[str]


class DoctorSymptomResponse(BaseModel):
    id: UUID
    symptom_text: str
    severity: int | None
    reported_at: datetime
    clinician_response: str | None


class DoctorPatientDetail(BaseModel):
    user_id: UUID
    full_name: str
    phone: str | None
    date_of_birth: date | None
    accessibility_notes: str | None
    medications: list[DoctorMedicationResponse]
    symptoms: list[DoctorSymptomResponse]


class ErrorResponse(BaseModel):
    detail: str
    request_id: str | None = None


class VoiceIntent(BaseModel):
    detected_language: Literal["en", "hi", "te", "unknown"]
    transcript: str | None = Field(default=None, max_length=2000)
    intent: Literal[
        "mark_taken",
        "mark_skipped",
        "ask_schedule",
        "ask_next_dose",
        "report_symptom",
        "unknown",
    ]
    medication_mention: str | None = Field(default=None, max_length=160)
    timing_mention: str | None = Field(default=None, max_length=160)
    explicitly_reported_action: bool = False
    ambiguity: bool = False
    clarification_question: str | None = Field(default=None, max_length=300)
    user_summary: str = Field(max_length=300)

    @model_validator(mode="after")
    def require_explicit_dose_report(self) -> "VoiceIntent":
        if self.intent in {"mark_taken", "mark_skipped"} and not self.explicitly_reported_action:
            self.intent = "unknown"
            self.ambiguity = True
            if self.clarification_question is None:
                self.clarification_question = (
                    "Did you take or skip a dose? Please clarify before continuing."
                )
        return self
