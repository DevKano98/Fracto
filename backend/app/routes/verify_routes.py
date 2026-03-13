"""
verify_routes.py — Full RAG pipeline with duplicate detection, virality, social signals.
"""

import asyncio
import base64
import hashlib
import json
import logging
from typing import Optional

import requests as http_requests
from fastapi import APIRouter, File, Form, Request, UploadFile, Depends, Security
from fastapi.security import HTTPBearer
from pydantic import BaseModel
from slowapi import Limiter
from slowapi.util import get_remote_address

from app.config import settings
from app.database.queries import insert_claim, insert_user_report
from app.services.auth_service import verify_access_token

optional_bearer = HTTPBearer(auto_error=False)
async def get_optional_user(credentials=Security(optional_bearer)):
    if not credentials: return None
    payload = verify_access_token(credentials.credentials)
    if payload:
        payload["id"] = payload.get("sub")
    return payload
from app.ml.classifier import classify_claim
from app.models.claim_model import ClaimInput, ClaimResponse
from app.services.gemini_ocr_service import process_image, scrape_url
from app.services.gemini_verify_service import verify_claim
from app.services.risk_scorer import compute_risk
from app.services.sarvam_service import detect_language, speech_to_text, text_to_speech
from app.services.qwen_scraper import gather_evidence_free as gather_evidence
from app.services.groq_service import (
    translate_to_english,
    extract_core_claim,
    generate_corrective_in_language,
)
from app.services.trend_detector import (
    duplicate_clusterer,
    virality_estimator,
    social_signal_scorer,
    trend_detector,
)

logger = logging.getLogger(__name__)
router = APIRouter()
limiter = Limiter(key_func=get_remote_address)


# ---------------------------------------------------------------------------
# Redis helpers (Upstash REST)
# ---------------------------------------------------------------------------
def _redis_get(key: str):
    try:
        resp = http_requests.get(
            f"{settings.UPSTASH_REDIS_URL}/get/{key}",
            headers={"Authorization": f"Bearer {settings.UPSTASH_REDIS_TOKEN}"},
            timeout=5,
        )
        return resp.json().get("result")
    except Exception:
        return None


def _redis_set(key: str, value: str, ex: int = 3600):
    try:
        http_requests.post(
            f"{settings.UPSTASH_REDIS_URL}/set/{key}/{value}/ex/{ex}",
            headers={"Authorization": f"Bearer {settings.UPSTASH_REDIS_TOKEN}"},
            timeout=5,
        )
    except Exception:
        pass


def _cache_key(text: str) -> str:
    return "fracta:claim:" + hashlib.sha256(text.encode()).hexdigest()


def _safe_json(data: dict) -> str:
    safe = {}
    for k, v in data.items():
        if isinstance(v, (str, int, float, bool, type(None))):
            safe[k] = v
        elif isinstance(v, list):
            safe[k] = v
        else:
            safe[k] = str(v)
    return json.dumps(safe)


# ---------------------------------------------------------------------------
# Full RAG pipeline
# ---------------------------------------------------------------------------
async def _run_full_pipeline(
    raw_text: str,
    source_type: str,
    platform: str,
    shares: int,
    visual_flags: list,
    visual_context: dict,
    language: Optional[str] = None,
    extra_signals: Optional[dict] = None,
    current_user: Optional[dict] = None,
) -> dict:

    # 1. Duplicate detection — skip pipeline if near-duplicate found
    duplicate = duplicate_clusterer.find_duplicate(raw_text)
    if duplicate:
        logger.info("Near-duplicate claim detected, returning existing result.")
        result = dict(duplicate)
        result["is_duplicate"] = True
        result["duplicate_similarity"] = duplicate.get("similarity_score", 0)
        return result

    # 2. Language detection first (needed for translation)
    if not language:
        language = detect_language(raw_text)

    # 2b. Groq: translate non-English to English for ML classifier
    text_for_ml = raw_text
    if language and not language.startswith("en"):
        text_for_ml = await translate_to_english(raw_text)

    # 2c. Groq: extract core checkable claim from long text
    extracted_claim = raw_text
    if len(raw_text) > 300:
        extracted_claim = await extract_core_claim(raw_text)

    # 3. ML classify (on English text)
    ml_result = classify_claim(text_for_ml)

    # 4. RAG — gather web evidence in parallel with nothing else blocking
    rag_evidence = await gather_evidence(raw_text, language)

    # 5. LLM verification with RAG context injected
    verification = await verify_claim(
        raw_text, ml_result, visual_context, language, rag_evidence=rag_evidence
    )

    # 6. Visual flags
    vf = list(visual_flags)
    if visual_context.get("manipulation_detected"):
        vf.append("manipulation_detected")
    if visual_context.get("fake_govt_logo"):
        vf.append("fake_govt_logo")
    if visual_context.get("morphed_person"):
        vf.append("morphed_person")

    # 7. Risk scoring
    risk = compute_risk(
        ml_confidence=ml_result["confidence"],
        llm_confidence=verification["confidence"],
        category=ml_result["category"],
        platform=platform,
        shares=shares,
        visual_flags=vf,
    )

    # 8. Virality estimation
    from datetime import datetime, timezone
    virality = virality_estimator.estimate(
        shares=shares,
        platform=platform,
        language=language,
        source_type=source_type,
        category=ml_result["category"],
        created_at=datetime.now(timezone.utc),
    )

    # 9. Social signal scoring (extra_signals dict from request body if provided)
    es = extra_signals or {}
    social = social_signal_scorer.score(
        whatsapp_forwards=es.get("whatsapp_forwards", shares if platform == "whatsapp" else 0),
        twitter_retweets=es.get("twitter_retweets", shares if platform == "twitter" else 0),
        instagram_shares=es.get("instagram_shares", shares if platform == "instagram" else 0),
        facebook_shares=es.get("facebook_shares", 0),
        youtube_views=es.get("youtube_views", 0),
        telegram_forwards=es.get("telegram_forwards", 0),
        reddit_upvotes=es.get("reddit_upvotes", 0),
    )

    # 10. Record for trend detection
    trend_detector.record_claim_category(ml_result["category"], platform)

    # 11. Assemble and save
    claim_data = {
        "raw_text": raw_text,
        "extracted_claim": extracted_claim,
        "source_type": source_type,
        "platform": platform,
        "language": language,
        "ml_category": ml_result["category"],
        "ml_confidence": ml_result["confidence"],
        "llm_verdict": verification["verdict"],
        "llm_confidence": verification["confidence"],
        "evidence": verification["evidence"],
        "sources": verification["sources"],
        "reasoning_steps": verification["reasoning_steps"],
        "corrective_response": verification["corrective_response"],
        "risk_score": risk["score"],
        "risk_level": risk["level"],
        "visual_flags": vf,
        "status": "PENDING",
        "submitted_by": current_user["id"] if current_user else None,
    }

    saved = insert_claim(claim_data)
    claim_data["id"] = saved.get("id")
    claim_data["created_at"] = saved.get("created_at")

    # Attach enrichment data (not stored in DB, returned in response)
    claim_data["conflict_flag"] = verification.get("conflict_flag", False)
    claim_data["govt_source_corroborated"] = verification.get("govt_source_corroborated", False)
    claim_data["virality_score"] = virality["virality_score"]
    claim_data["virality_level"] = virality["virality_level"]
    claim_data["estimated_reach"] = virality["estimated_reach"]
    claim_data["social_threat_score"] = social["social_threat_score"]
    claim_data["social_recommended_action"] = social["recommended_action"]
    claim_data["rag_sources_count"] = rag_evidence.get("total_sources_found", 0)
    claim_data["is_duplicate"] = False

    return claim_data


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.post("/text", response_model=ClaimResponse)
@limiter.limit("20/minute")
async def verify_text(
    request: Request, 
    body: ClaimInput,
    current_user: Optional[dict] = Depends(get_optional_user)
):
    cache_key = _cache_key(body.raw_text)
    cached = _redis_get(cache_key)
    if cached:
        try:
            return ClaimResponse(**json.loads(cached))
        except Exception:
            pass

    result = await _run_full_pipeline(
        raw_text=body.raw_text,
        source_type=body.source_type,
        platform=body.platform,
        shares=body.shares,
        visual_flags=[],
        visual_context={},
        current_user=current_user,
    )

    from app.services.blog_generator import auto_generate_blog
    asyncio.create_task(auto_generate_blog(result))

    _redis_set(cache_key, _safe_json(result))
    return ClaimResponse(**result)


@router.post("/image", response_model=ClaimResponse)
async def verify_image(
    request: Request,
    file: UploadFile = File(...),
    platform: str = Form(default="unknown"),
    shares: int = Form(default=0),
    current_user: Optional[dict] = Depends(get_optional_user)
):
    image_bytes = await file.read()
    image_result = await process_image(image_bytes)

    extracted_text = image_result.get("extracted_text", "") or image_result.get("image_summary", "No text extracted")
    detected_platform = image_result.get("platform", platform)
    language = image_result.get("language_code", "en-IN")
    visual_context = {
        "manipulation_detected": image_result.get("manipulation_detected", False),
        "fake_govt_logo": image_result.get("fake_govt_logo", False),
        "morphed_person": image_result.get("morphed_person", False),
    }

    result = await _run_full_pipeline(
        raw_text=extracted_text,
        source_type="image",
        platform=detected_platform,
        shares=shares,
        visual_flags=[],
        visual_context=visual_context,
        language=language,
        current_user=current_user,
    )

    from app.services.blog_generator import auto_generate_blog
    asyncio.create_task(auto_generate_blog(result))
    return ClaimResponse(**result)


@router.post("/url", response_model=ClaimResponse)
@limiter.limit("20/minute")
async def verify_url(
    request: Request,
    url: str = Form(...),
    platform: str = Form(default="unknown"),
    shares: int = Form(default=0),
    current_user: Optional[dict] = Depends(get_optional_user)
):
    cache_key = _cache_key(url)
    cached = _redis_get(cache_key)
    if cached:
        try:
            return ClaimResponse(**json.loads(cached))
        except Exception:
            pass

    scraped = scrape_url(url)
    raw_text = scraped.get("text", "") or f"Content from {url}"

    result = await _run_full_pipeline(
        raw_text=raw_text,
        source_type="url",
        platform=platform,
        shares=shares,
        visual_flags=[],
        visual_context={},
        current_user=current_user,
    )

    from app.services.blog_generator import auto_generate_blog
    asyncio.create_task(auto_generate_blog(result))

    _redis_set(cache_key, _safe_json(result))
    return ClaimResponse(**result)


@router.post("/voice", response_model=ClaimResponse)
async def verify_voice(
    request: Request,
    file: UploadFile = File(...),
    language: str = Form(default="hi-IN"),
    platform: str = Form(default="unknown"),
    shares: int = Form(default=0),
    current_user: Optional[dict] = Depends(get_optional_user)
):
    audio_bytes = await file.read()
    transcript = speech_to_text(audio_bytes, language, filename=file.filename, content_type=file.content_type) or "Could not transcribe audio"
    detected_lang = detect_language(transcript) if transcript else language

    result = await _run_full_pipeline(
        raw_text=transcript,
        source_type="voice",
        platform=platform,
        shares=shares,
        visual_flags=[],
        visual_context={},
        language=detected_lang,
        current_user=current_user,
    )

    corrective = result.get("corrective_response", "")
    ai_audio_b64 = ""
    if corrective:
        tts_bytes = text_to_speech(corrective, detected_lang)
        if tts_bytes:
            ai_audio_b64 = base64.b64encode(tts_bytes).decode("utf-8")
    result["ai_audio_b64"] = ai_audio_b64

    from app.services.blog_generator import auto_generate_blog
    asyncio.create_task(auto_generate_blog(result))
    return ClaimResponse(**result)


class ReportInput(BaseModel):
    claim_id: str
    report_type: str
    note: str = ""

@router.post("/report")
async def report_claim(
    request: Request,
    body: ReportInput,
    current_user: Optional[dict] = Depends(get_optional_user)
):
    reported_by = current_user["id"] if current_user else None
    insert_user_report(body.claim_id, reported_by, body.report_type, body.note)
    return {"message": "Report submitted successfully"}