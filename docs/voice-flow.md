# Voice interpretation

`POST /api/v1/voice/interpret` accepts one authenticated MP3 multipart upload. It validates the MIME type, MPEG audio frame structure, streamed request byte limit, and duration before invoking Gemini. It forwards the actual MP3 bytes as inline `audio/mp3` input for smaller requests and uses the official Files API for larger accepted uploads. Temporary local files and any provider-side file upload are deleted after processing. Interactions are requested with `store=False`.

Gemini returns a Pydantic-defined structured intent. The server downgrades a `mark_taken` or `mark_skipped` interpretation to `unknown` if the model does not report an explicit patient statement. The endpoint never writes medication or dose records. An interpretation is not proof of ingestion; a future confirmation endpoint must resolve real medications and dose occurrences, show the proposed action, and perform the dose write atomically only after explicit patient confirmation.

Configure `GEMINI_API_KEY` and `GEMINI_MODEL` in `backend/.env`. The model is deliberately configurable; Google's current audio guide uses `gemini-3.8-flash` in its examples, but availability varies by account and may change. Verify an available audio-capable model in the [Gemini models guide](https://ai.google.dev/gemini-api/docs/models) before configuring it. The implementation uses the current official [audio input](https://ai.google.dev/gemini-api/docs/audio) and [structured output](https://ai.google.dev/gemini-api/docs/structured-output) patterns via `google-genai` Interactions. The API key remains backend-only.

The automated voice tests mock the provider and require no Gemini key. Live Gemini behavior was not tested because no key was provided.
