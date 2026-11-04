import asyncio
import base64
import json
from types import SimpleNamespace

import httpx
import pytest
from google import genai
from pydantic import SecretStr

from app.core.config import Settings
from app.core.request_limits import VoiceUploadSizeLimitMiddleware
from app.core.security import AuthenticatedUser, get_current_user
from app.main import app
from app.schemas import VoiceIntent
from app.services.audio_validation import inspect_mp3
from app.services.gemini_audio import GeminiInvalidResponseError, _generate_intent


def make_mp3(frame_count: int = 2) -> bytes:
    frame = bytes.fromhex("FFFB9064") + bytes(413)
    return frame * frame_count


def test_valid_mp3_frames_are_accepted():
    details = inspect_mp3(make_mp3())

    assert details.frame_count == 2
    assert details.duration_seconds > 0


@pytest.mark.parametrize("audio", [b"", b"not an mp3", bytes.fromhex("FFFB9064")])
def test_malformed_or_incomplete_mp3_is_rejected(audio: bytes):
    with pytest.raises(ValueError):
        inspect_mp3(audio)


def test_voice_upload_middleware_rejects_chunked_body_over_limit():
    async def run_request():
        body_messages = iter(
            [
                {"type": "http.request", "body": b"123", "more_body": True},
                {"type": "http.request", "body": b"456", "more_body": False},
            ]
        )
        sent = []
        called = False

        async def receive():
            return next(body_messages)

        async def send(message):
            sent.append(message)

        async def endpoint(_scope, _receive, _send):
            nonlocal called
            called = True
            await _receive()
            await _receive()

        middleware = VoiceUploadSizeLimitMiddleware(endpoint, max_body_bytes=5)
        scope = {
            "type": "http",
            "method": "POST",
            "path": "/api/v1/voice/interpret",
            "headers": [],
        }
        await middleware(scope, receive, send)
        return sent, called

    sent, called = asyncio.run(run_request())
    assert sent[0]["status"] == 413
    assert called


def test_voice_intent_does_not_claim_a_dose_without_explicit_report():
    intent = VoiceIntent(
        detected_language="en",
        intent="mark_taken",
        explicitly_reported_action=False,
        user_summary="The audio mentioned medicine.",
    )

    assert intent.intent == "unknown"
    assert intent.ambiguity
    assert intent.clarification_question


def test_gemini_receives_the_actual_mp3_as_inline_audio(monkeypatch):
    captured: dict = {}

    class FakeInteractions:
        def create(self, **kwargs):
            captured.update(kwargs)
            return SimpleNamespace(
                output_text=json.dumps(
                    {
                        "detected_language": "en",
                        "transcript": "I took my evening tablet.",
                        "intent": "mark_taken",
                        "medication_mention": "tablet",
                        "timing_mention": "evening",
                        "explicitly_reported_action": True,
                        "ambiguity": False,
                        "clarification_question": None,
                        "user_summary": "You said you took your evening tablet.",
                    }
                )
            )

    class FakeClient:
        interactions = FakeInteractions()

        def close(self):
            captured["closed"] = True

    monkeypatch.setattr(genai, "Client", lambda **_: FakeClient())
    audio = make_mp3()
    result = _generate_intent(
        audio,
        Settings(gemini_api_key=SecretStr("test-only"), gemini_model="configured-model"),
    )

    assert result.intent == "mark_taken"
    assert captured["input"][1]["type"] == "audio"
    assert captured["input"][1]["mime_type"] == "audio/mp3"
    assert captured["input"][1]["data"] == base64.b64encode(audio).decode("ascii")
    assert captured["store"] is False
    assert captured["closed"]


def test_large_audio_uses_temporary_files_api_upload_and_deletes_it(monkeypatch):
    captured: dict = {}

    class FakeFiles:
        def upload(self, *, file, config):
            from pathlib import Path

            path = Path(file)
            captured["local_path"] = path
            captured["local_size"] = path.stat().st_size
            captured["config"] = config
            return SimpleNamespace(uri="files/audio-1", mime_type="audio/mp3", name="files/audio-1")

        def delete(self, *, name):
            captured["deleted_name"] = name

    class FakeInteractions:
        def create(self, **kwargs):
            captured["input"] = kwargs["input"]
            return SimpleNamespace(output_text="{}")

    class FakeClient:
        files = FakeFiles()
        interactions = FakeInteractions()

        def close(self):
            captured["closed"] = True

    monkeypatch.setattr(genai, "Client", lambda **_: FakeClient())
    audio = b"x" * 14_000_001
    with pytest.raises(GeminiInvalidResponseError):
        _generate_intent(
            audio,
            Settings(gemini_api_key=SecretStr("test-only"), gemini_model="configured-model"),
        )

    assert captured["local_size"] == len(audio)
    assert not captured["local_path"].exists()
    assert captured["config"] == {"mime_type": "audio/mp3"}
    assert captured["input"][1]["uri"] == "files/audio-1"
    assert captured["deleted_name"] == "files/audio-1"
    assert captured["closed"]


def test_interpret_endpoint_requires_authentication():
    async def request():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        ) as client:
            return await client.post(
                "/api/v1/voice/interpret",
                files={"audio": ("voice.mp3", make_mp3(), "audio/mpeg")},
            )

    response = asyncio.run(request())
    assert response.status_code == 401


def test_interpret_endpoint_sends_validated_mp3_to_service(monkeypatch):
    observed: list[bytes] = []

    async def fake_interpret(audio_bytes, _settings):
        observed.append(audio_bytes)
        from app.services.gemini_audio import AudioInterpretation

        return AudioInterpretation(
            intent=VoiceIntent(
                detected_language="en",
                intent="ask_schedule",
                user_summary="You asked about today's schedule.",
            )
        )

    from app.api.v1 import voice

    monkeypatch.setattr(voice, "interpret_mp3", fake_interpret)
    monkeypatch.setitem(
        app.dependency_overrides,
        get_current_user,
        lambda: AuthenticatedUser(
            id="00000000-0000-0000-0000-000000000001", roles=frozenset({"patient"})
        ),
    )

    async def request():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app),
            base_url="http://test",
        ) as client:
            return await client.post(
                "/api/v1/voice/interpret",
                files={"audio": ("voice.mp3", make_mp3(), "audio/mpeg")},
            )

    audio = make_mp3()
    response = asyncio.run(request())
    assert response.status_code == 200
    assert response.json()["intent"] == "ask_schedule"
    assert observed == [audio]
