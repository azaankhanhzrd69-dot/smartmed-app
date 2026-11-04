from functools import lru_cache

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(".env", "backend/.env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_env: str = "development"
    app_host: str = "127.0.0.1"
    app_port: int = 8000
    database_url: str | None = None
    supabase_url: str | None = None
    supabase_anon_key: SecretStr | None = None
    jwt_issuer: str | None = None
    jwt_audience: str = "authenticated"
    jwt_jwks_url: str | None = None
    gemini_api_key: SecretStr | None = None
    gemini_model: str | None = None
    cors_allowed_origins: list[str] = Field(default_factory=lambda: ["http://localhost:5173"])
    max_audio_upload_mb: int = Field(default=15, ge=1, le=50)
    max_audio_duration_seconds: int = Field(default=120, ge=1, le=600)
    voice_confirmation_ttl_seconds: int = Field(default=120, ge=30, le=600)

    @field_validator("app_env")
    @classmethod
    def validate_environment(cls, value: str) -> str:
        if value not in {"development", "test", "production"}:
            raise ValueError("APP_ENV must be development, test, or production")
        return value

    @field_validator("cors_allowed_origins", mode="before")
    @classmethod
    def parse_cors_origins(cls, value: object) -> object:
        if isinstance(value, str) and not value.lstrip().startswith("["):
            return [origin.strip() for origin in value.split(",") if origin.strip()]
        return value

    def validate_production_settings(self) -> None:
        if self.app_env == "production":
            missing = [
                name
                for name, value in (
                    ("DATABASE_URL", self.database_url),
                    ("JWT_ISSUER", self.jwt_issuer),
                    ("JWT_JWKS_URL", self.jwt_jwks_url),
                    (
                        "GEMINI_API_KEY",
                        self.gemini_api_key.get_secret_value()
                        if self.gemini_api_key is not None
                        else None,
                    ),
                    ("GEMINI_MODEL", self.gemini_model),
                )
                if not value
            ]
            if missing:
                raise ValueError(f"Missing production settings: {', '.join(missing)}")


@lru_cache
def get_settings() -> Settings:
    return Settings()
