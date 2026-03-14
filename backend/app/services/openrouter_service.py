"""
openrouter_service.py

OpenRouter API for Fracta fallbacks:
- Vision (image-to-text): Google Gemma 3 4B (google/gemma-3-4b-it:free)
- Reasoning/verification: Qwen3 Next 80B (qwen/qwen3-next-80b-a3b-instruct:free)

Used when Gemini fails (500, quota, or model errors) to avoid server errors and provide
reliable image verification and claim reasoning.
"""

import base64
import json
import logging
import re
from typing import Any, Dict, List, Optional

import httpx

from app.config import settings

logger = logging.getLogger(__name__)

OPENROUTER_BASE = "https://openrouter.ai/api/v1/chat/completions"
TIMEOUT = 60


def _headers() -> dict:
    return {
        "Authorization": f"Bearer {settings.OPENROUTER_API_KEY}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://fracta.app",
    }


def is_available() -> bool:
    return bool(settings.OPENROUTER_API_KEY)


async def _chat(
    model: str,
    messages: List[Dict[str, Any]],
    max_tokens: int = 2048,
    temperature: float = 0.2,
) -> Optional[str]:
    if not is_available():
        return None
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            r = await client.post(
                OPENROUTER_BASE,
                headers=_headers(),
                json={
                    "model": model,
                    "messages": messages,
                    "max_tokens": max_tokens,
                    "temperature": temperature,
                },
            )
            r.raise_for_status()
            data = r.json()
            choice = data.get("choices", [{}])[0]
            msg = choice.get("message", {})
            return msg.get("content", "").strip()
    except Exception as e:
        logger.warning("OpenRouter %s error: %s", model, e)
        return None


async def image_to_text(image_bytes: bytes, prompt: str) -> Optional[str]:
    """
    Send image + text prompt to vision model (Gemma 3 4B).
    Used for OCR and image context when Gemini fails.
    """
    if not is_available():
        return None
    b64 = base64.b64encode(image_bytes).decode("utf-8")
    data_url = f"data:image/jpeg;base64,{b64}"
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": data_url}},
            ],
        }
    ]
    return await _chat(settings.OPENROUTER_VISION_MODEL, messages, max_tokens=1024)


async def image_extract_ocr(image_bytes: bytes) -> Dict[str, Any]:
    """
    Extract text and metadata from image (fallback when Gemini OCR fails).
    Returns dict with extracted_text, platform, language_code, image_summary.
    """
    prompt = (
        "Extract ALL visible text from this image exactly as it appears. "
        "Also identify: the platform this content is from (whatsapp/twitter/instagram/unknown), "
        "the primary language of the text (return as BCP-47 like hi-IN, en-IN), "
        "and a one-line summary of what the image is showing. "
        "Return ONLY valid JSON with keys: extracted_text, platform, language_code, image_summary."
    )
    raw = await image_to_text(image_bytes, prompt)
    if not raw:
        return {
            "extracted_text": "",
            "platform": "unknown",
            "language_code": "en-IN",
            "image_summary": "OpenRouter vision unavailable",
        }
    raw = re.sub(r"^```json\s*", "", raw)
    raw = re.sub(r"```\s*$", "", raw).strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {
            "extracted_text": raw[:2000],
            "platform": "unknown",
            "language_code": "en-IN",
            "image_summary": "",
        }


async def image_context_analysis(image_bytes: bytes) -> Dict[str, Any]:
    """
    Analyze image for misinformation signals (fallback when Gemini context fails).
    """
    prompt = (
        "Analyze this image for misinformation signals. Check for: "
        "1. Government logos or seals (fake_govt_logo: true/false) "
        "2. Faces or people morphed/manipulated (morphed_person: true/false) "
        "3. Digital manipulation or editing (manipulation_detected: true/false) "
        "4. Type: screenshot/meme/photo/graphic/document "
        "5. Any suspicious elements. "
        "Return ONLY valid JSON with keys: fake_govt_logo (bool), morphed_person (bool), "
        "manipulation_detected (bool), image_type (str), suspicious_elements (list of strings)."
    )
    raw = await image_to_text(image_bytes, prompt)
    if not raw:
        return {
            "fake_govt_logo": False,
            "morphed_person": False,
            "manipulation_detected": False,
            "image_type": "unknown",
            "suspicious_elements": [],
        }
    raw = re.sub(r"^```json\s*", "", raw)
    raw = re.sub(r"```\s*$", "", raw).strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {
            "fake_govt_logo": False,
            "morphed_person": False,
            "manipulation_detected": False,
            "image_type": "unknown",
            "suspicious_elements": [],
        }


async def reasoning_verification(
    claim_text: str,
    evidence_summary: str,
    language: str = "en-IN",
) -> Optional[Dict[str, Any]]:
    """
    Run verification reasoning with Qwen3 Next 80B (fallback when Gemini verify fails).
    Returns parsed dict with verdict, confidence, evidence, corrective_response, etc.
    """
    system = """You are Fracta, India's AI misinformation defense system.
Analyze the claim using the evidence provided.
Rules: Base verdict ONLY on evidence; prefer government > fact-checkers > news.
Return structured output with these exact labels:
VERDICT: TRUE or FALSE or MISLEADING or UNVERIFIED
CONFIDENCE: 0.0 to 1.0
EVIDENCE: one clear sentence
SOURCES: comma separated or "none"
REASONING_STEP_1: ...
REASONING_STEP_2: ...
CORRECTIVE_RESPONSE: short correction in same language as the claim."""
    user = f"""CLAIM:\n{claim_text}\n\nLANGUAGE: {language}\n\nEVIDENCE:\n{evidence_summary}\n\nAnalyze and return the structured result."""
    content = await _chat(
        settings.OPENROUTER_REASONING_MODEL,
        [{"role": "system", "content": system}, {"role": "user", "content": user}],
        max_tokens=1500,
        temperature=0.1,
    )
    if not content:
        return None
    content = content.upper()
    result = {
        "verdict": "UNVERIFIED",
        "confidence": 0.5,
        "evidence": "",
        "sources": [],
        "reasoning_steps": [],
        "corrective_response": "",
    }
    v = re.search(r"VERDICT\s*[:\-]\s*(TRUE|FALSE|MISLEADING|UNVERIFIED)", content)
    if v:
        result["verdict"] = v.group(1)
    c = re.search(r"CONFIDENCE\s*[:\-]\s*([0-9.]+)", content)
    if c:
        try:
            result["confidence"] = float(c.group(1))
        except ValueError:
            pass
    e = re.search(r"EVIDENCE\s*[:\-]\s*(.+?)(?=\n[A-Z_]+:|\Z)", content, re.DOTALL)
    if e:
        result["evidence"] = e.group(1).strip()
    s = re.search(r"SOURCES\s*[:\-]\s*(.+?)(?=\n[A-Z_]+:|\Z)", content, re.DOTALL)
    if s and "none" not in s.group(1).lower():
        result["sources"] = [x.strip() for x in s.group(1).split(",") if x.strip()]
    steps = re.findall(r"REASONING_STEP_\d+\s*[:\-]\s*(.+?)(?=\nREASONING_STEP|\nCORRECTIVE|\Z)", content, re.DOTALL)
    result["reasoning_steps"] = [x.strip() for x in steps if x.strip()]
    corr = re.search(r"CORRECTIVE_RESPONSE\s*[:\-]\s*(.+?)(?=\n[A-Z_]+:|\Z)", content, re.DOTALL)
    if corr:
        result["corrective_response"] = corr.group(1).strip()
    return result
