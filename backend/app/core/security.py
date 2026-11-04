from dataclasses import dataclass
from functools import lru_cache
from typing import Any

import jwt as jwt_lib
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient
from jwt.exceptions import PyJWKClientError, PyJWTError

from app.core.config import Settings, get_settings


@dataclass(frozen=True)
class AuthenticatedUser:
    id: str
    roles: frozenset[str]


bearer_scheme = HTTPBearer(auto_error=False)


@lru_cache
def _jwks_client(url: str) -> PyJWKClient:
    return PyJWKClient(url, cache_keys=True, timeout=5)


def decode_access_token(token: str, settings: Settings) -> dict[str, Any]:
    if not settings.jwt_issuer or not settings.jwt_jwks_url:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Authentication is not configured",
        )
    try:
        signing_key = _jwks_client(settings.jwt_jwks_url).get_signing_key_from_jwt(token)
        claims = jwt_lib.decode(
            token,
            signing_key.key,
            algorithms=["ES256", "RS256"],
            audience=settings.jwt_audience,
            issuer=settings.jwt_issuer,
            options={"require": ["exp", "iat", "sub"]},
        )
    except PyJWKClientError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Authentication key service is unavailable",
        ) from exc
    except PyJWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired access token",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    if not isinstance(claims.get("sub"), str) or not claims["sub"]:
        raise HTTPException(status_code=401, detail="Access token has no subject")
    return claims


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    settings: Settings = Depends(get_settings),
) -> AuthenticatedUser:
    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Bearer access token required",
            headers={"WWW-Authenticate": "Bearer"},
        )
    claims = decode_access_token(credentials.credentials, settings)
    metadata = claims.get("app_metadata")
    raw_roles = metadata.get("roles", []) if isinstance(metadata, dict) else []
    if not isinstance(raw_roles, list):
        raw_roles = []
    roles = frozenset(
        role for role in raw_roles if role in {"patient", "doctor", "caregiver", "clinic_admin"}
    )
    return AuthenticatedUser(id=claims["sub"], roles=roles)
