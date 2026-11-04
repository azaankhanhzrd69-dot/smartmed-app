from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db_session
from app.core.security import AuthenticatedUser, get_current_user
from app.schemas import (
    DoctorAppointmentResponse,
    DoctorMedicationResponse,
    DoctorPatientDetail,
    DoctorPatientSummary,
    DoctorProfileResponse,
    DoctorSymptomResponse,
)

router = APIRouter(prefix="/api/v1/doctor", tags=["doctor"])


async def _require_verified_doctor(user: AuthenticatedUser, session: AsyncSession) -> None:
    result = await session.execute(
        text(
            "SELECT verification::text FROM public.doctor_profiles "
            "WHERE user_id = :doctor_id"
        ),
        {"doctor_id": UUID(user.id)},
    )
    verification = result.scalar_one_or_none()
    if verification != "verified":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="A verified doctor profile is required",
        )


@router.get("/me", response_model=DoctorProfileResponse)
async def read_doctor_profile(
    user: AuthenticatedUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_db_session),
) -> DoctorProfileResponse:
    await _require_verified_doctor(user, session)
    result = await session.execute(
        text(
            "SELECT d.user_id, p.full_name, d.specialization, d.verification::text "
            "FROM public.doctor_profiles d "
            "JOIN public.user_profiles p ON p.user_id = d.user_id "
            "WHERE d.user_id = :doctor_id"
        ),
        {"doctor_id": UUID(user.id)},
    )
    profile = result.mappings().one_or_none()
    if profile is None:
        raise HTTPException(status_code=404, detail="Doctor profile not found")
    return DoctorProfileResponse.model_validate(dict(profile))


@router.get("/patients", response_model=list[DoctorPatientSummary])
async def read_doctor_patients(
    user: AuthenticatedUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_db_session),
) -> list[DoctorPatientSummary]:
    await _require_verified_doctor(user, session)
    result = await session.execute(
        text(
            "SELECT p.user_id, p.full_name, p.phone, pp.date_of_birth, "
            "(SELECT count(*) FROM public.medications m "
            " WHERE m.patient_id = pp.user_id AND m.status = 'active')::integer "
            " AS active_medication_count, "
            "(SELECT max(sr.reported_at) FROM public.symptom_reports sr "
            " WHERE sr.patient_id = pp.user_id) AS latest_symptom_at "
            "FROM public.care_team_assignments a "
            "JOIN public.patient_profiles pp ON pp.user_id = a.patient_id "
            "JOIN public.user_profiles p ON p.user_id = pp.user_id "
            "WHERE a.doctor_id = :doctor_id AND a.status = 'active' "
            "ORDER BY p.full_name LIMIT 200"
        ),
        {"doctor_id": UUID(user.id)},
    )
    return [DoctorPatientSummary.model_validate(dict(row)) for row in result.mappings()]


@router.get("/appointments", response_model=list[DoctorAppointmentResponse])
async def read_doctor_appointments(
    user: AuthenticatedUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_db_session),
) -> list[DoctorAppointmentResponse]:
    await _require_verified_doctor(user, session)
    result = await session.execute(
        text(
            "SELECT a.id, a.patient_id, p.full_name AS patient_name, a.starts_at, a.ends_at, "
            "a.appointment_type::text AS appointment_type, a.status::text AS status, "
            "a.reason, a.patient_notes, a.clinician_notes "
            "FROM public.doctor_appointments a "
            "JOIN public.user_profiles p ON p.user_id = a.patient_id "
            "WHERE a.doctor_id = :doctor_id AND a.starts_at >= now() - interval '30 days' "
            "ORDER BY a.starts_at LIMIT 200"
        ),
        {"doctor_id": UUID(user.id)},
    )
    return [DoctorAppointmentResponse.model_validate(dict(row)) for row in result.mappings()]


@router.get("/patients/{patient_id}", response_model=DoctorPatientDetail)
async def read_doctor_patient(
    patient_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_db_session),
) -> DoctorPatientDetail:
    await _require_verified_doctor(user, session)
    access = await session.execute(
        text(
            "SELECT 1 FROM public.care_team_assignments "
            "WHERE doctor_id = :doctor_id AND patient_id = :patient_id AND status = 'active'"
        ),
        {"doctor_id": UUID(user.id), "patient_id": patient_id},
    )
    if access.scalar_one_or_none() is None:
        raise HTTPException(status_code=404, detail="Patient not found")

    patient_result = await session.execute(
        text(
            "SELECT p.user_id, p.full_name, p.phone, pp.date_of_birth, pp.accessibility_notes "
            "FROM public.patient_profiles pp "
            "JOIN public.user_profiles p ON p.user_id = pp.user_id "
            "WHERE pp.user_id = :patient_id"
        ),
        {"patient_id": patient_id},
    )
    patient = patient_result.mappings().one_or_none()
    if patient is None:
        raise HTTPException(status_code=404, detail="Patient not found")

    medications_result = await session.execute(
        text(
            "SELECT m.id AS medication_id, m.medication_name, m.strength, "
            "pv.dosage_amount, pv.dosage_unit, pv.frequency_text, pv.instructions, "
            "pv.effective_from, COALESCE(s.schedule_times, ARRAY[]::text[]) AS schedule_times "
            "FROM public.medications m "
            "JOIN public.user_profiles patient_profile ON patient_profile.user_id = m.patient_id "
            "LEFT JOIN LATERAL ("
            " SELECT v.dosage_amount, v.dosage_unit, v.frequency_text, v.instructions, v.id, "
            " v.effective_from FROM public.prescription_versions v "
            " WHERE v.medication_id = m.id AND v.effective_from <= now() "
            " AND (v.effective_until IS NULL OR v.effective_until > now()) "
            " ORDER BY v.effective_from DESC LIMIT 1"
            ") pv ON true "
            "LEFT JOIN LATERAL ("
            " SELECT array_agg(to_char(t.local_time, 'HH24:MI') ORDER BY t.local_time) "
            " AS schedule_times FROM public.medication_schedules ms "
            " CROSS JOIN LATERAL unnest(ms.local_times) AS t(local_time) "
            " WHERE ms.prescription_version_id = pv.id "
            " AND ms.start_date <= (now() AT TIME ZONE patient_profile.timezone)::date "
            " AND (ms.end_date IS NULL OR "
            " (ms.end_date >= (now() AT TIME ZONE patient_profile.timezone)::date)) "
            " AND (extract(isodow FROM now() AT TIME ZONE patient_profile.timezone)::smallint - 1) "
            " = ANY(ms.days_of_week)"
            ") s ON true "
            "WHERE m.patient_id = :patient_id AND m.status = 'active' "
            "ORDER BY m.medication_name LIMIT 200"
        ),
        {"patient_id": patient_id},
    )
    symptoms_result = await session.execute(
        text(
            "SELECT id, symptom_text, severity, reported_at, clinician_response "
            "FROM public.symptom_reports WHERE patient_id = :patient_id "
            "ORDER BY reported_at DESC LIMIT 50"
        ),
        {"patient_id": patient_id},
    )
    medications = [
        DoctorMedicationResponse.model_validate(dict(row))
        for row in medications_result.mappings()
    ]
    symptoms = [
        DoctorSymptomResponse.model_validate(dict(row)) for row in symptoms_result.mappings()
    ]
    return DoctorPatientDetail(
        **dict(patient),
        medications=medications,
        symptoms=symptoms,
    )
