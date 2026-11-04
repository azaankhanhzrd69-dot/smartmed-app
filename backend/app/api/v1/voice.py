from fastapi import APIRouter, Depends, File, HTTPException, UploadFile

from app.core.config import Settings, get_settings
from app.core.security import AuthenticatedUser, get_current_user
from app.schemas import VoiceIntent
from app.services.audio_validation import inspect_mp3
from app.services.gemini_audio import (
    GeminiInvalidResponseError,
    GeminiProviderError,
    GeminiRateLimitError,
    GeminiTimeoutError,
    GeminiUnavailableError,
    interpret_mp3,
)

router = APIRouter(prefix="/api/v1/voice", tags=["voice"])


@router.post("/interpret", response_model=VoiceIntent)
async def interpret_voice(
    audio: UploadFile = File(...),
    _: AuthenticatedUser = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
) -> VoiceIntent:
    if audio.content_type not in {"audio/mpeg", "audio/mp3"}:
        await audio.close()
        raise HTTPException(
            status_code=415, detail="Upload must use the audio/mpeg or audio/mp3 media type"
        )

    max_bytes = settings.max_audio_upload_mb * 1024 * 1024
    audio_bytes = await audio.read(max_bytes + 1)
    await audio.close()
    if len(audio_bytes) > max_bytes:
        raise HTTPException(
            status_code=413, detail="Audio upload exceeds the configured size limit"
        )
    try:
        inspect_mp3(audio_bytes, settings.max_audio_duration_seconds)
    except ValueError as exc:
        raise HTTPException(status_code=415, detail=str(exc)) from exc

    try:
        result = await interpret_mp3(audio_bytes, settings)
    except GeminiUnavailableError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except GeminiRateLimitError as exc:
        raise HTTPException(
            status_code=429, detail="Voice processing is temporarily rate limited"
        ) from exc
    except GeminiTimeoutError as exc:
        raise HTTPException(
            status_code=504, detail="Voice processing timed out; try again or use manual entry"
        ) from exc
    except GeminiInvalidResponseError as exc:
        raise HTTPException(
            status_code=502, detail="Voice processing returned an invalid interpretation"
        ) from exc
    except GeminiProviderError as exc:
        raise HTTPException(
            status_code=502, detail="Voice processing is temporarily unavailable"
        ) from exc

    return result.intent
