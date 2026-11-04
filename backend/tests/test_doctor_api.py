import asyncio

import httpx

from app.core.database import get_db_session
from app.core.security import AuthenticatedUser, get_current_user
from app.main import app


class FakeResult:
    def __init__(self, value):
        self.value = value

    def scalar_one_or_none(self):
        return self.value


class FakeRows:
    def __init__(self, rows):
        self.rows = rows

    def mappings(self):
        return self

    def __iter__(self):
        return iter(self.rows)


class FakeSession:
    def __init__(self, roster=None, assignment_exists=True, verification="pending"):
        self.roster = roster or []
        self.assignment_exists = assignment_exists
        self.verification = verification

    async def execute(self, query, parameters):
        query_text = str(query)
        if "SELECT verification::text" in query_text:
            return FakeResult(self.verification)
        if "FROM public.care_team_assignments a" in query_text:
            assert "a.status = 'active'" in query_text
            assert str(parameters["doctor_id"]) == "00000000-0000-0000-0000-000000000001"
            return FakeRows(self.roster)
        if "FROM public.care_team_assignments" in query_text:
            assert str(parameters["doctor_id"]) == "00000000-0000-0000-0000-000000000001"
            return FakeResult(1 if self.assignment_exists else None)
        raise AssertionError("Unverified doctor must not query patient data")


def test_doctor_routes_require_a_verified_doctor_profile():
    async def request():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        ) as client:
            return await client.get("/api/v1/doctor/patients")

    async def database_session():
        yield FakeSession()

    app.dependency_overrides[get_current_user] = lambda: AuthenticatedUser(
        id="00000000-0000-0000-0000-000000000001",
        roles=frozenset({"doctor"}),
    )
    app.dependency_overrides[get_db_session] = database_session
    try:
        response = asyncio.run(request())
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 403
    assert response.json()["detail"] == "A verified doctor profile is required"


def test_doctor_routes_require_authentication():
    async def request():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        ) as client:
            return await client.get("/api/v1/doctor/patients")

    response = asyncio.run(request())

    assert response.status_code == 401


def test_patient_detail_hides_patients_without_an_active_assignment():
    async def request():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        ) as client:
            return await client.get(
                "/api/v1/doctor/patients/00000000-0000-0000-0000-000000000002"
            )

    async def database_session():
        yield FakeSession(assignment_exists=False, verification="verified")

    app.dependency_overrides[get_current_user] = lambda: AuthenticatedUser(
        id="00000000-0000-0000-0000-000000000001",
        roles=frozenset({"doctor"}),
    )
    app.dependency_overrides[get_db_session] = database_session
    try:
        response = asyncio.run(request())
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 404
    assert response.json()["detail"] == "Patient not found"


def test_doctor_roster_only_contains_active_assignments():
    async def request():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        ) as client:
            return await client.get("/api/v1/doctor/patients")

    async def database_session():
        yield FakeSession(
            roster=[
                {
                    "user_id": "00000000-0000-0000-0000-000000000002",
                    "full_name": "Taylor Patient",
                    "phone": None,
                    "date_of_birth": None,
                    "active_medication_count": 2,
                    "latest_symptom_at": None,
                }
            ],
            verification="verified",
        )

    app.dependency_overrides[get_current_user] = lambda: AuthenticatedUser(
        id="00000000-0000-0000-0000-000000000001",
        roles=frozenset({"doctor"}),
    )
    app.dependency_overrides[get_db_session] = database_session
    try:
        response = asyncio.run(request())
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200
    assert response.json()[0]["full_name"] == "Taylor Patient"
    assert response.json()[0]["active_medication_count"] == 2
