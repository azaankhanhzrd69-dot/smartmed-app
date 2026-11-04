import asyncio

import httpx
import pytest
from fastapi import HTTPException

from app.core.config import Settings
from app.core.security import decode_access_token


def test_health_endpoint_does_not_require_external_services():
    from app.main import app

    async def request():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        ) as client:
            return await client.get("/health")

    response = asyncio.run(request())
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_root_redirects_to_api_docs():
    from app.main import app

    async def request():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
            follow_redirects=False,
        ) as client:
            return await client.get("/")

    response = asyncio.run(request())
    assert response.status_code == 307
    assert response.headers["location"] == "/docs"


def test_api_requires_bearer_authentication():
    from app.main import app

    async def request():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        ) as client:
            return await client.get("/api/v1/me")

    response = asyncio.run(request())
    assert response.status_code == 401


def test_jwt_verification_requires_trusted_issuer_configuration():
    with pytest.raises(HTTPException) as error:
        decode_access_token("not-a-token", Settings())

    assert error.value.status_code == 503
    assert error.value.detail == "Authentication is not configured"


def test_production_settings_require_database_and_trusted_jwks():
    settings = Settings(app_env="production")

    with pytest.raises(ValueError, match="DATABASE_URL"):
        settings.validate_production_settings()


def test_cors_origins_are_loaded_from_json_environment_value(monkeypatch):
    monkeypatch.setenv("CORS_ALLOWED_ORIGINS", '["http://localhost:5173"]')

    assert Settings().cors_allowed_origins == ["http://localhost:5173"]


def test_profile_schema_rejects_untrusted_role_fields():
    from pydantic import ValidationError

    from app.schemas import ProfilePatch

    with pytest.raises(ValidationError):
        ProfilePatch.model_validate({"full_name": "A Patient", "role": "doctor"})
