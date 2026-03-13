"""
sarvam_service.py

Handles Sarvam AI APIs:
- Speech to Text (STT)
- Text to Speech (TTS)
- Language Detection

Features:
- async HTTP client (httpx)
- retries with exponential backoff
- robust error handling
- JSON validation
- audio size validation
"""

import base64
import logging
import asyncio
from typing import Optional

import httpx

from app.config import settings

logger = logging.getLogger(__name__)

SARVAM_BASE = "https://api.sarvam.ai"

HEADERS = {
    "api-subscription-key": settings.SARVAM_API_KEY,
    "Accept": "application/json",
}

VOICE_MAP = {
    "hi-IN": "ritu",
    "en-IN": "ritu",
    "default": "ritu",
}

MAX_AUDIO_SIZE = 10 * 1024 * 1024  # 10MB


class SarvamService:
    def __init__(self):
        self.client = httpx.AsyncClient(
            timeout=httpx.Timeout(30.0),
            limits=httpx.Limits(max_keepalive_connections=10, max_connections=20),
        )

    async def _post_with_retry(self, url: str, **kwargs) -> Optional[dict]:
        retries = 3

        for attempt in range(retries):
            try:
                response = await self.client.post(url, **kwargs)
                response.raise_for_status()
                return response.json()

            except httpx.HTTPStatusError as exc:
                logger.error(
                    "Sarvam HTTP error %s: %s",
                    exc.response.status_code,
                    exc.response.text,
                )

            except httpx.RequestError as exc:
                logger.error("Sarvam network error: %s", exc)

            except Exception as exc:
                logger.error("Sarvam unexpected error: %s", exc)

            if attempt < retries - 1:
                wait = 2 ** attempt
                await asyncio.sleep(wait)

        return None

    async def speech_to_text(
        self,
        audio_bytes: bytes,
        language: str = "hi-IN",
        filename: str = "audio.wav",
        content_type: str = "audio/wav",
    ) -> str:
        """
        Convert speech audio to text using Sarvam STT.
        """

        if not audio_bytes:
            return ""

        if len(audio_bytes) > MAX_AUDIO_SIZE:
            logger.warning("Audio file too large for STT")
            return ""

        files = {"file": (filename, audio_bytes, content_type)}

        data = {
            "language_code": language,
            "model": "saaras:v3",
        }

        result = await self._post_with_retry(
            f"{SARVAM_BASE}/speech-to-text",
            headers=HEADERS,
            files=files,
            data=data,
        )

        if not result:
            return ""

        transcript = result.get("transcript", "")
        return transcript.strip()

    async def text_to_speech(self, text: str, language: str = "hi-IN") -> bytes:
        """
        Convert text to speech using Sarvam TTS.
        """

        if not text:
            return b""

        # prevent extremely long requests
        text = text[:1000]

        speaker = VOICE_MAP.get(language, VOICE_MAP["default"])

        payload = {
            "input": text,
            "target_language_code": language,
            "speaker": speaker,
            "model": "bulbul:v3",
            "speech_sample_rate": 22050,
        }

        result = await self._post_with_retry(
            f"{SARVAM_BASE}/text-to-speech",
            headers={**HEADERS, "Content-Type": "application/json"},
            json=payload,
        )

        if not result:
            return b""

        audios = result.get("audios", [])

        if not audios:
            return b""

        try:
            return base64.b64decode(audios[0])
        except Exception as exc:
            logger.error("Sarvam TTS decode error: %s", exc)
            return b""

    async def detect_language(self, text: str) -> str:
        """
        Detect language using Sarvam language identification.
        """

        if not text:
            return "en-IN"

        payload = {"input": text}

        result = await self._post_with_retry(
            f"{SARVAM_BASE}/text-lid",
            headers={**HEADERS, "Content-Type": "application/json"},
            json=payload,
        )

        if not result:
            return self._fallback_language(text)

        return result.get("language_code", "en-IN")

    def _fallback_language(self, text: str) -> str:
        """
        Fallback language detection based on unicode.
        """

        devanagari_count = sum(1 for ch in text if "\u0900" <= ch <= "\u097F")

        if devanagari_count > len(text) * 0.2:
            return "hi-IN"

        return "en-IN"

    async def close(self):
        await self.client.aclose()


sarvam_service = SarvamService()