import base64
import json
import logging
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
from fastapi.concurrency import run_in_threadpool
from pydantic import ValidationError

from app.core.config import Settings
from app.schemas import VoiceIntent

logger = logging.getLogger(__name__)

INTENT_PROMPT = """
Listen to the supplied audio directly. Understand English, Hindi, Telugu, and normal
code-switching between them. Return only the requested structured intent.

Classify only these intents: mark_taken, mark_skipped, ask_schedule, ask_next_dose,
report_symptom, unknown. A mark_taken or mark_skipped intent is valid only when the
speaker explicitly says they took or skipped a medicine. Do not infer ingestion from
plans, questions, silence, or context. Never invent patient, medication, dose, dosage,
schedule, identity, or timestamp data. Never recommend or change a prescription.
Extract spoken medication and timing mentions as plain text only. Mark ambiguity when
the action, medication, or timing is unclear. Phrase clarification and the short user
summary in the speaker's detected language when possible. This is a patient-reported
intent, not a clinically verified fact.
""".strip()
MAX_INLINE_AUDIO_BYTES = 14_000_000


class GeminiUnavailableError(Exception):
    pass


class GeminiProviderError(Exception):
    pass


class GeminiRateLimitError(GeminiProviderError):
    pass


class GeminiTimeoutError(GeminiProviderError):
    pass


class GeminiInvalidResponseError(GeminiProviderError):
    pass


@dataclass(frozen=True)
class AudioInterpretation:
    intent: VoiceIntent


def _generate_intent(audio_bytes: bytes, settings: Settings) -> VoiceIntent:
    try:
        from google import genai
        from google.genai.errors import APIError
    except ImportError as exc:
        raise GeminiUnavailableError("Install the backend voice extra to enable Gemini.") from exc

    if settings.gemini_api_key is None or not settings.gemini_model:
        raise GeminiUnavailableError("Gemini audio processing is not configured.")

    client = genai.Client(api_key=settings.gemini_api_key.get_secret_value())
    uploaded_file: Any | None = None
    temporary_path: Path | None = None
    try:
        if len(audio_bytes) <= MAX_INLINE_AUDIO_BYTES:
            audio_input: dict[str, str] = {
                "type": "audio",
                "data": base64.b64encode(audio_bytes).decode("ascii"),
                "mime_type": "audio/mp3",
            }
        else:
            with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as audio_file:
                audio_file.write(audio_bytes)
                temporary_path = Path(audio_file.name)
            uploaded_file = client.files.upload(
                file=str(temporary_path),
                config={"mime_type": "audio/mp3"},
            )
            audio_input = {
                "type": "audio",
                "uri": uploaded_file.uri,
                "mime_type": uploaded_file.mime_type or "audio/mp3",
            }

        interaction = client.interactions.create(
            model=settings.gemini_model,
            input=[
                {"type": "text", "text": INTENT_PROMPT},
                audio_input,
            ],
            response_format={
                "type": "text",
                "mime_type": "application/json",
                "schema": VoiceIntent.model_json_schema(),
            },
            store=False,
            timeout=30,
        )
        output_text = interaction.output_text
    except httpx.TimeoutException as exc:
        logger.warning("Gemini audio request timed out")
        raise GeminiTimeoutError("Gemini audio request timed out.") from exc
    except APIError as exc:
        code = getattr(exc, "code", None)
        logger.warning("Gemini audio request failed with HTTP status %s", code)
        if code == 429:
            raise GeminiRateLimitError("Gemini rate limit reached.") from exc
        if code in {408, 504}:
            raise GeminiTimeoutError("Gemini audio request timed out.") from exc
        raise GeminiProviderError("Gemini audio request failed.") from exc
    finally:
        try:
            if uploaded_file is not None:
                client.files.delete(name=uploaded_file.name)
        except (APIError, httpx.HTTPError) as exc:
            code = getattr(exc, "code", None)
            logger.error("Gemini temporary audio file deletion failed with HTTP status %s", code)
            raise GeminiProviderError(
                "Could not securely remove temporary provider audio."
            ) from exc
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)
            client.close()

    if not output_text:
        raise GeminiInvalidResponseError("Gemini returned no structured intent.")
    try:
        return VoiceIntent.model_validate(json.loads(output_text))
    except (json.JSONDecodeError, ValidationError) as exc:
        raise GeminiInvalidResponseError("Gemini returned an invalid structured intent.") from exc


async def interpret_mp3(audio_bytes: bytes, settings: Settings) -> AudioInterpretation:
    intent = await run_in_threadpool(_generate_intent, audio_bytes, settings)
    return AudioInterpretation(intent=intent)
