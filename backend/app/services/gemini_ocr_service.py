import asyncio
import base64
import json
import logging
import re

import requests
from bs4 import BeautifulSoup
import google.generativeai as genai

from app.config import settings

logger = logging.getLogger(__name__)

genai.configure(api_key=settings.GEMINI_KEY_1)
_ocr_model = genai.GenerativeModel("gemini-2.5-flash")


def _b64(image_bytes: bytes) -> str:
    return base64.b64encode(image_bytes).decode("utf-8")


async def _run_ocr(image_bytes: bytes) -> dict:
    try:
        image_part = {"inline_data": {"mime_type": "image/jpeg", "data": _b64(image_bytes)}}
        text_part = (
            "Extract ALL visible text from this image exactly as it appears. "
            "Also identify: the platform this content is from (whatsapp/twitter/instagram/unknown), "
            "the primary language of the text (return as BCP-47 language code like hi-IN, en-IN), "
            "and a one-line summary of what the image is showing. "
            "Return JSON with fields: extracted_text, platform, language_code, image_summary."
        )
        loop = asyncio.get_event_loop()
        response = await loop.run_in_executor(
            None, lambda: _ocr_model.generate_content([image_part, text_part])
        )
        raw = response.text.strip()
        raw = re.sub(r"^```json\s*", "", raw)
        raw = re.sub(r"```$", "", raw).strip()
        try:
            return json.loads(raw)
        except Exception:
            return {"extracted_text": raw, "platform": "unknown", "language_code": "en-IN", "image_summary": ""}
    except Exception as e:
        logger.warning("Gemini OCR failed: %s", e)
        try:
            from app.services.openrouter_service import image_extract_ocr
            return await image_extract_ocr(image_bytes)
        except Exception as fallback_e:
            logger.warning("OpenRouter OCR fallback failed: %s", fallback_e)
            return {"extracted_text": "", "platform": "unknown", "language_code": "en-IN", "image_summary": "Image analysis unavailable"}


async def _run_context_analysis(image_bytes: bytes) -> dict:
    try:
        image_part = {"inline_data": {"mime_type": "image/jpeg", "data": _b64(image_bytes)}}
        text_part = (
            "Analyze this image for misinformation signals. Check for: "
            "1. Presence of government logos or seals (fake_govt_logo: true/false) "
            "2. Visible faces or people who may be morphed or manipulated (morphed_person: true/false) "
            "3. Signs of digital manipulation, splicing or editing (manipulation_detected: true/false) "
            "4. Type of image: screenshot/meme/photo/graphic/document "
            "5. Any suspicious elements that could indicate misinformation. "
            "Return JSON with fields: fake_govt_logo (bool), morphed_person (bool), "
            "manipulation_detected (bool), image_type (str), suspicious_elements (list of strings)."
        )
        loop = asyncio.get_event_loop()
        response = await loop.run_in_executor(
            None, lambda: _ocr_model.generate_content([image_part, text_part])
        )
        raw = response.text.strip()
        raw = re.sub(r"^```json\s*", "", raw)
        raw = re.sub(r"```$", "", raw).strip()
        try:
            return json.loads(raw)
        except Exception:
            return {
                "fake_govt_logo": False,
                "morphed_person": False,
                "manipulation_detected": False,
                "image_type": "unknown",
                "suspicious_elements": [],
            }
    except Exception as e:
        logger.warning("Gemini context analysis failed: %s", e)
        try:
            from app.services.openrouter_service import image_context_analysis
            return await image_context_analysis(image_bytes)
        except Exception as fallback_e:
            logger.warning("OpenRouter context fallback failed: %s", fallback_e)
            return {
                "fake_govt_logo": False,
                "morphed_person": False,
                "manipulation_detected": False,
                "image_type": "unknown",
                "suspicious_elements": [],
            }


async def process_image(image_bytes: bytes) -> dict:
    ocr_result, context_result = await asyncio.gather(
        _run_ocr(image_bytes),
        _run_context_analysis(image_bytes),
    )
    return {
        "extracted_text": ocr_result.get("extracted_text", ""),
        "platform": ocr_result.get("platform", "unknown"),
        "language_code": ocr_result.get("language_code", "en-IN"),
        "image_summary": ocr_result.get("image_summary", ""),
        "fake_govt_logo": context_result.get("fake_govt_logo", False),
        "morphed_person": context_result.get("morphed_person", False),
        "manipulation_detected": context_result.get("manipulation_detected", False),
        "image_type": context_result.get("image_type", "unknown"),
        "suspicious_elements": context_result.get("suspicious_elements", []),
    }


def scrape_url(url: str) -> dict:
    try:
        resp = requests.get(url, timeout=10, headers={"User-Agent": "Mozilla/5.0"})
        resp.raise_for_status()
        soup = BeautifulSoup(resp.text, "html.parser")
        title = soup.title.string.strip() if soup.title else ""
        paragraphs = soup.find_all("p")
        words = []
        for p in paragraphs:
            words.extend(p.get_text().split())
            if len(words) >= 500:
                break
        body = " ".join(words[:500])
        return {"text": f"{title}. {body}".strip(), "url": url}
    except Exception as exc:
        logger.error("scrape_url error for %s: %s", url, exc)
        return {"text": "", "url": url}