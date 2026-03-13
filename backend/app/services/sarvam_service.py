import logging

import requests
from requests.exceptions import RequestException

from app.config import settings

logger = logging.getLogger(__name__)

SARVAM_HEADERS = {"api-subscription-key": settings.SARVAM_API_KEY}

VOICE_MAP = {
    "hi-IN": "meera",
    "default": "meera",
}


def speech_to_text(audio_bytes: bytes, language: str = "hi-IN", filename: str = "audio.wav", content_type: str = "audio/wav") -> str:
    try:
        files = {"file": (filename, audio_bytes, content_type)}
        data = {"language_code": language, "model": "saarika:v2"}
        response = requests.post(
            "https://api.sarvam.ai/speech-to-text",
            headers=SARVAM_HEADERS,
            files=files,
            data=data,
            timeout=30,
        )
        response.raise_for_status()
        result = response.json()
        return result.get("transcript", "")
    except RequestException as exc:
        logger.error("Sarvam STT error: %s", exc)
        return ""


def text_to_speech(text: str, language: str = "hi-IN") -> bytes:
    try:
        speaker = VOICE_MAP.get(language, VOICE_MAP["default"])
        payload = {
            "inputs": [text],
            "target_language_code": language,
            "speaker": speaker,
            "model": "bulbul:v1",
            "speech_sample_rate": 22050,
        }
        response = requests.post(
            "https://api.sarvam.ai/text-to-speech",
            headers={**SARVAM_HEADERS, "Content-Type": "application/json"},
            json=payload,
            timeout=30,
        )
        response.raise_for_status()
        import base64
        audios = response.json().get("audios", [])
        if audios:
            return base64.b64decode(audios[0])
        return b""
    except RequestException as exc:
        logger.error("Sarvam TTS error: %s", exc)
        return b""


def detect_language(text: str) -> str:
    try:
        response = requests.post(
            "https://api.sarvam.ai/text-lid",
            headers={**SARVAM_HEADERS, "Content-Type": "application/json"},
            json={"input": text},
            timeout=10,
        )
        response.raise_for_status()
        return response.json().get("language_code", "en-IN")
    except RequestException as exc:
        logger.error("Sarvam language detect error: %s", exc)
        return "en-IN"