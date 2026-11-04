import json
from collections.abc import AsyncIterator
from functools import lru_cache

from fastapi import Depends, HTTPException
from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.core.config import Settings, get_settings
from app.core.security import AuthenticatedUser, get_current_user


@lru_cache
def get_engine(database_url: str) -> AsyncEngine:
    return create_async_engine(database_url, pool_pre_ping=True)


def get_session_factory(settings: Settings) -> async_sessionmaker[AsyncSession]:
    if not settings.database_url:
        raise HTTPException(status_code=503, detail="Database is not configured")
    return async_sessionmaker(get_engine(settings.database_url), expire_on_commit=False)


async def get_db_session(
    user: AuthenticatedUser = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
) -> AsyncIterator[AsyncSession]:
    factory = get_session_factory(settings)
    async with factory() as session, session.begin():
        # Even when DATABASE_URL connects as the local Supabase postgres role,
        # application queries run with the restricted authenticated role.
        await session.execute(text("SET LOCAL ROLE authenticated"))
        claims = {
            "sub": user.id,
            "role": "authenticated",
            "app_metadata": {"roles": sorted(user.roles)},
        }
        await session.execute(
            text(
                "SELECT set_config('request.jwt.claims', :claims, true), "
                "set_config('request.jwt.claim.sub', :subject, true), "
                "set_config('request.jwt.claim.role', 'authenticated', true)"
            ),
            {"claims": json.dumps(claims), "subject": user.id},
        )
        yield session
