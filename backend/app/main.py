from contextlib import asynccontextmanager
from uuid import UUID

from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.v1.doctor import router as doctor_router
from app.api.v1.voice import router as voice_router
from app.core.config import get_settings
from app.core.database import get_db_session
from app.core.request_limits import VoiceUploadSizeLimitMiddleware
from app.core.security import AuthenticatedUser, get_current_user
from app.schemas import PatientProfileResponse, ProfilePatch, ProfileResponse, RolesResponse


@asynccontextmanager
async def lifespan(_: FastAPI):
    settings = get_settings()
    settings.validate_production_settings()
    yield


settings = get_settings()
app = FastAPI(
    title="SmartMed API",
    version="1.0.0",
    description="Authenticated API for SmartMed patient and clinician workflows.",
    openapi_url="/api/v1/openapi.json",
    docs_url="/docs",
    lifespan=lifespan,
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_allowed_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
)
app.add_middleware(
    VoiceUploadSizeLimitMiddleware,
    max_body_bytes=settings.max_audio_upload_mb * 1024 * 1024 + 64 * 1024,
)
app.include_router(voice_router)
app.include_router(doctor_router)


@app.middleware("http")
async def add_request_id(request: Request, call_next):
    from uuid import uuid4

    request_id = request.headers.get("X-Request-ID") or str(uuid4())
    request.state.request_id = request_id
    response = await call_next(request)
    response.headers["X-Request-ID"] = request_id
    return response


@app.get("/health", tags=["health"])
async def health() -> dict[str, str]:
    return {"status": "ok", "environment": settings.app_env}


@app.get("/", include_in_schema=False)
async def root() -> RedirectResponse:
    return RedirectResponse(url="/docs")


@app.get("/api/v1/me", response_model=ProfileResponse, tags=["profile"])
async def read_my_profile(
    user: AuthenticatedUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_db_session),
) -> ProfileResponse:
    result = await session.execute(
        text(
            "SELECT user_id, full_name, phone, preferred_language, timezone, created_at, updated_at "
            "FROM public.user_profiles WHERE user_id = :user_id"
        ),
        {"user_id": user.id},
    )
    profile = result.mappings().one_or_none()
    if profile is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile not found")
    return ProfileResponse.model_validate(dict(profile))


@app.patch("/api/v1/me", response_model=ProfileResponse, tags=["profile"])
async def update_my_profile(
    patch: ProfilePatch,
    user: AuthenticatedUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_db_session),
) -> ProfileResponse:
    changes = patch.model_dump(exclude_unset=True)
    if not changes:
        raise HTTPException(status_code=400, detail="At least one profile field is required")
    if any(
        changes.get(field) is None
        for field in ("full_name", "preferred_language", "timezone")
        if field in changes
    ):
        raise HTTPException(status_code=400, detail="Profile fields cannot be null")
    assignments = ", ".join(f"{column} = :{column}" for column in changes)
    try:
        result = await session.execute(
            text(
                "UPDATE public.user_profiles SET " + assignments + " WHERE user_id = :user_id "
                "RETURNING user_id, full_name, phone, preferred_language, timezone, created_at, updated_at"
            ),
            {**changes, "user_id": user.id},
        )
        profile = result.mappings().one_or_none()
    except IntegrityError as exc:
        raise HTTPException(
            status_code=422, detail="Profile update violates a data constraint"
        ) from exc
    if profile is None:
        raise HTTPException(status_code=404, detail="Profile not found")
    return ProfileResponse.model_validate(dict(profile))


@app.get("/api/v1/me/roles", response_model=RolesResponse, tags=["profile"])
async def read_my_roles(
    user: AuthenticatedUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_db_session),
) -> RolesResponse:
    result = await session.execute(
        text("SELECT role::text FROM public.user_roles WHERE user_id = :user_id ORDER BY role"),
        {"user_id": user.id},
    )
    return RolesResponse(roles=[row[0] for row in result])


@app.get("/api/v1/patients/me", response_model=PatientProfileResponse, tags=["patients"])
async def read_my_patient_profile(
    user: AuthenticatedUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_db_session),
) -> PatientProfileResponse:
    result = await session.execute(
        text(
            "SELECT user_id, date_of_birth, emergency_contact_name, "
            "emergency_contact_phone, accessibility_notes, created_at, updated_at "
            "FROM public.patient_profiles WHERE user_id = :user_id"
        ),
        {"user_id": user.id},
    )
    profile = result.mappings().one_or_none()
    if profile is None:
        raise HTTPException(status_code=404, detail="Patient profile not found")
    return PatientProfileResponse.model_validate(dict(profile))


@app.get("/api/v1/patients/{patient_id}", tags=["patients"])
async def read_patient(
    patient_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
    session: AsyncSession = Depends(get_db_session),
) -> dict:
    result = await session.execute(
        text(
            "SELECT user_id, date_of_birth, created_at, updated_at "
            "FROM public.patient_profiles WHERE user_id = :patient_id"
        ),
        {"patient_id": str(patient_id)},
    )
    profile = result.mappings().one_or_none()
    if profile is None:
        raise HTTPException(status_code=404, detail="Patient not found")
    return dict(profile)
