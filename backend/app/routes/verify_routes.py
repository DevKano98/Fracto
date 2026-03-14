"""
verify_routes.py — Full RAG pipeline with duplicate detection, virality, social signals.

Complete verification pipeline:
  Input (text | image | url | voice)
    → Preprocessing (OCR / scrape / STT)
    → Language detection (Sarvam + Groq)
    → Claim extraction (Groq)
    → ML classifier
    → RAG search (news + web + social, parallel)
    → Groq reasoning (pre-verdict)
    → Gemini verification (final verdict; fallback to Groq if Gemini fails)
    → Final verdict
    → Store result in Supabase
    → Return response
    → Optional voice output (TTS in original language)
"""

import asyncio
import base64
import hashlib
import json
import logging
from typing import Optional

import requests as http_requests
from fastapi import APIRouter, File, Form, Request, UploadFile, Depends, Security, HTTPException
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
try:
    from app.services.sarvam_service import (
        detect_language,
        speech_to_text,
        text_to_speech,
    )
except ImportError as e:
    logging.getLogger(__name__).warning(
        "Sarvam service unavailable: %s. Voice verification will use fallbacks.", e
    )

    async def detect_language(text: str) -> str:
        return "en-IN" if text and any(ord(c) < 128 for c in text[:50]) else "hi-IN"

    async def speech_to_text(*_, **__) -> str:
        return ""

    async def text_to_speech(*_, **__) -> bytes:
        return b""
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
    if not settings.UPSTASH_REDIS_URL or not settings.UPSTASH_REDIS_TOKEN:
        return None
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
    if not settings.UPSTASH_REDIS_URL or not settings.UPSTASH_REDIS_TOKEN:
        return
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


PIPELINE_TIMEOUT_SECONDS = 90


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
    try:
        return await _run_full_pipeline_impl(
            raw_text, source_type, platform, shares,
            visual_flags, visual_context, language, extra_signals, current_user,
        )
    except Exception as exc:
        logger.exception("Pipeline failed: %s", exc)
        return {
            "raw_text": raw_text,
            "extracted_claim": raw_text[:500],
            "source_type": source_type,
            "platform": platform,
            "language": language or "en-IN",
            "ml_category": "UNKNOWN",
            "ml_confidence": 0.5,
            "llm_verdict": "UNVERIFIED",
            "llm_confidence": 0.0,
            "evidence": "Verification pipeline error",
            "sources": [],
            "reasoning_steps": ["A temporary error occurred. Please try again."],
            "corrective_response": "We couldn't verify this claim right now. Please try again in a moment.",
            "risk_score": 5.0,
            "risk_level": "MEDIUM",
            "visual_flags": list(visual_flags),
            "status": "PENDING",
            "submitted_by": current_user["id"] if current_user else None,
            "id": None,
            "created_at": None,
            "conflict_flag": False,
            "govt_source_corroborated": False,
            "virality_score": 0.0,
            "virality_level": "low",
            "estimated_reach": "0",
            "social_threat_score": 0.0,
            "social_recommended_action": "retry",
            "rag_sources_count": 0,
            "is_duplicate": False,
        }


async def _run_full_pipeline_impl(
    raw_text: str,
    source_type: str,
    platform: str,
    shares: int,
    visual_flags: list,
    visual_context: dict,
    language: Optional[str],
    extra_signals: Optional[dict],
    current_user: Optional[dict],
) -> dict:
    # 1. Duplicate detection — skip pipeline if near-duplicate found
    duplicate = None
    try:
        duplicate = duplicate_clusterer.find_duplicate(raw_text)
    except Exception as exc:
        logger.debug("Duplicate detection failed: %s", exc)
    if duplicate:
        logger.info("Near-duplicate claim detected, returning existing result.")
        result = dict(duplicate)
        result["is_duplicate"] = True
        result["duplicate_similarity"] = duplicate.get("similarity_score", 0)
        return result

    # 2. Language detection
    if not language:
        try:
            language = await detect_language(raw_text)
        except Exception as exc:
            logger.debug("Language detection failed: %s", exc)
            language = "en-IN"

    # 2b. Groq: translate non-English to English for ML classifier
    text_for_ml = raw_text
    if language and not language.startswith("en"):
        text_for_ml = await translate_to_english(raw_text)

    # 2c. Groq: extract core claim from long text
    extracted_claim = raw_text
    if len(raw_text) > 300:
        extracted_claim = await extract_core_claim(raw_text)

    # 3. ML classify (on English text)
    try:
        ml_result = classify_claim(text_for_ml)
    except Exception as exc:
        logger.warning("ML classify failed: %s", exc)
        ml_result = {"category": "UNKNOWN", "confidence": 0.5}

    # 4. RAG — gather web evidence
    try:
        rag_evidence = await asyncio.wait_for(
            gather_evidence(raw_text, language),
            timeout=45,
        )
    except asyncio.TimeoutError:
        logger.warning("RAG evidence gather timed out")
        rag_evidence = {"evidence_summary": "", "has_govt_source": False, "has_factchecker_source": False}
    except Exception as exc:
        logger.warning("RAG evidence failed: %s", exc)
        rag_evidence = {"evidence_summary": "", "has_govt_source": False, "has_factchecker_source": False}

    # 5. LLM verification with RAG context injected; Groq pre-verdict used if Gemini fails
    groq_fallback = None
    if rag_evidence and rag_evidence.get("qwen_analysis"):
        qa = rag_evidence["qwen_analysis"]
        groq_fallback = {
            "qwen_verdict": qa.get("qwen_verdict"),
            "qwen_confidence": qa.get("qwen_confidence"),
            "qwen_summary": qa.get("qwen_summary"),
            "qwen_corrective": qa.get("qwen_corrective"),
            "sources": [],
        }
    verification = await verify_claim(
        raw_text,
        ml_result,
        visual_context,
        language,
        rag_evidence=rag_evidence,
        groq_fallback=groq_fallback,
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

    # 10. Record for trend detection (non-critical)
    try:
        trend_detector.record_claim_category(ml_result["category"], platform)
    except Exception as exc:
        logger.debug("Trend record failed: %s", exc)

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

    try:
        saved = insert_claim(claim_data)
        claim_data["id"] = saved.get("id")
        claim_data["created_at"] = saved.get("created_at")
    except Exception as exc:
        logger.error("DB insert_claim failed: %s", exc)
        claim_data["id"] = None
        claim_data["created_at"] = None

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

    try:
        result = await asyncio.wait_for(
            _run_full_pipeline(
                raw_text=body.raw_text,
                source_type=body.source_type,
                platform=body.platform,
                shares=body.shares,
                visual_flags=[],
                visual_context={},
                current_user=current_user,
            ),
            timeout=PIPELINE_TIMEOUT_SECONDS,
        )
    except asyncio.TimeoutError:
        logger.warning("Text verification pipeline timed out after %ss", PIPELINE_TIMEOUT_SECONDS)
        raise HTTPException(
            status_code=504,
            detail="Verification took too long. Please try again.",
        )

    from app.services.blog_generator import auto_generate_blog

    async def _safe_blog_task(r):
        try:
            await auto_generate_blog(r)
        except Exception as exc:
            logger.exception("Background blog generation failed: %s", exc)

    asyncio.create_task(_safe_blog_task(result))
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
    cache_key_img = _cache_key(f"image:{hashlib.sha256(image_bytes).hexdigest()}")
    cached = _redis_get(cache_key_img)
    if cached:
        try:
            return ClaimResponse(**json.loads(cached))
        except Exception:
            pass

    try:
        image_result = await process_image(image_bytes)
    except Exception as img_e:
        logger.exception("Image processing failed: %s", img_e)
        from datetime import datetime, timezone
        return ClaimResponse(
            raw_text="",
            extracted_claim="Image analysis failed",
            source_type="image",
            platform=platform,
            language="en-IN",
            ml_category="UNKNOWN",
            ml_confidence=0.5,
            llm_verdict="UNVERIFIED",
            llm_confidence=0.0,
            evidence="Image verification failed. Please try again or use text/URL.",
            sources=[],
            reasoning_steps=["Image processing error. You can retry or verify as text."],
            corrective_response="We couldn't analyze this image. Try uploading again or paste the text for verification.",
            risk_score=5.0,
            risk_level="MEDIUM",
            visual_flags=[],
            status="PENDING",
            id=None,
            created_at=datetime.now(timezone.utc),
            conflict_flag=False,
            govt_source_corroborated=False,
            virality_score=0.0,
            virality_level="low",
            estimated_reach="0",
            social_threat_score=0.0,
            social_recommended_action="retry",
            rag_sources_count=0,
            is_duplicate=False,
        )

    extracted_text = image_result.get("extracted_text", "") or image_result.get("image_summary", "No text extracted")
    detected_platform = image_result.get("platform", platform)
    language = image_result.get("language_code", "en-IN")
    visual_context = {
        "manipulation_detected": image_result.get("manipulation_detected", False),
        "fake_govt_logo": image_result.get("fake_govt_logo", False),
        "morphed_person": image_result.get("morphed_person", False),
    }

    try:
        result = await asyncio.wait_for(
            _run_full_pipeline(
                raw_text=extracted_text,
                source_type="image",
                platform=detected_platform,
                shares=shares,
                visual_flags=[],
                visual_context=visual_context,
                language=language,
                current_user=current_user,
            ),
            timeout=PIPELINE_TIMEOUT_SECONDS,
        )
    except asyncio.TimeoutError:
        logger.warning("Image verification pipeline timed out")
        raise HTTPException(status_code=504, detail="Verification took too long. Please try again.")
    except Exception as pipe_e:
        logger.exception("Image verification pipeline failed: %s", pipe_e)
        from datetime import datetime, timezone
        return ClaimResponse(
            raw_text=extracted_text[:500],
            extracted_claim=extracted_text[:300] or "Image content",
            source_type="image",
            platform=detected_platform,
            language=language,
            ml_category="UNKNOWN",
            ml_confidence=0.5,
            llm_verdict="UNVERIFIED",
            llm_confidence=0.0,
            evidence="Verification step failed. Please try again.",
            sources=[],
            reasoning_steps=["A temporary error occurred during verification."],
            corrective_response="We couldn't complete verification for this image. Please try again.",
            risk_score=5.0,
            risk_level="MEDIUM",
            visual_flags=[],
            status="PENDING",
            id=None,
            created_at=datetime.now(timezone.utc),
            conflict_flag=False,
            govt_source_corroborated=False,
            virality_score=0.0,
            virality_level="low",
            estimated_reach="0",
            social_threat_score=0.0,
            social_recommended_action="retry",
            rag_sources_count=0,
            is_duplicate=False,
        )

    from app.services.blog_generator import auto_generate_blog

    async def _safe_blog_task(r):
        try:
            await auto_generate_blog(r)
        except Exception as exc:
            logger.exception("Background blog generation failed: %s", exc)

    asyncio.create_task(_safe_blog_task(result))
    _redis_set(cache_key_img, _safe_json(result))
    return ClaimResponse(**result)


class UrlVerifyInput(BaseModel):
    url: str
    platform: str = "unknown"
    shares: int = 0


@router.post("/url", response_model=ClaimResponse)
@limiter.limit("20/minute")
async def verify_url(
    request: Request,
    body: UrlVerifyInput,
    current_user: Optional[dict] = Depends(get_optional_user)
):
    """Accepts JSON: {url, platform?, shares?} — matches Flutter ApiService and BackgroundService."""
    url_val, platform_val, shares_val = body.url, body.platform, body.shares
    cache_key = _cache_key(url_val)
    cached = _redis_get(cache_key)
    if cached:
        try:
            return ClaimResponse(**json.loads(cached))
        except Exception:
            pass

    scraped = scrape_url(url_val)
    raw_text = scraped.get("text", "") or f"Content from {url_val}"

    try:
        result = await asyncio.wait_for(
            _run_full_pipeline(
                raw_text=raw_text,
                source_type="url",
                platform=platform_val,
                shares=shares_val,
                visual_flags=[],
                visual_context={},
                current_user=current_user,
            ),
            timeout=PIPELINE_TIMEOUT_SECONDS,
        )
    except asyncio.TimeoutError:
        logger.warning("URL verification pipeline timed out")
        raise HTTPException(status_code=504, detail="Verification took too long. Please try again.")

    from app.services.blog_generator import auto_generate_blog

    async def _safe_blog_task(r):
        try:
            await auto_generate_blog(r)
        except Exception as exc:
            logger.exception("Background blog generation failed: %s", exc)

    asyncio.create_task(_safe_blog_task(result))
    _redis_set(cache_key, _safe_json(result))
    return ClaimResponse(**result)


@router.post("/voice", response_model=ClaimResponse)
async def verify_voice(
    request: Request,
    file: UploadFile = File(...),
    screen_image: Optional[UploadFile] = File(None),
    language: str = Form(default="hi-IN"),
    platform: str = Form(default="unknown"),
    shares: int = Form(default=0),
    current_user: Optional[dict] = Depends(get_optional_user)
):
    audio_bytes = await file.read()
    transcript = await speech_to_text(audio_bytes, language, filename=file.filename, content_type=file.content_type) or "Could not transcribe audio"
    detected_lang = await detect_language(transcript) if transcript else language

    # Live screen + voice: OCR screen (Gemini/OpenRouter), merge with STT, then full pipeline (search, TTS)
    visual_context = {}
    if screen_image and screen_image.filename:
        try:
            image_bytes = await screen_image.read()
            if image_bytes:
                image_result = await process_image(image_bytes)  # Gemini OCR, OpenRouter fallback
                visual_context = {
                    "manipulation_detected": image_result.get("manipulation_detected", False),
                    "fake_govt_logo": image_result.get("fake_govt_logo", False),
                    "morphed_person": image_result.get("morphed_person", False),
                }
                screen_text = (image_result.get("extracted_text", "") or image_result.get("image_summary", "")).strip()
                if screen_text:
                    # Combine as live transcript: screen content first (what user sees), then what they said
                    transcript = (
                        f"LIVE SCREEN CONTENT (OCR):\n{screen_text[:3000]}\n\n"
                        f"USER SAID: {transcript}"
                    )
        except Exception as img_e:
            logger.warning("Voice + screen image processing failed: %s", img_e)

    try:
        result = await asyncio.wait_for(
            _run_full_pipeline(
                raw_text=transcript,
                source_type="voice",
                platform=platform,
                shares=shares,
                visual_flags=[],
                visual_context=visual_context,
                language=detected_lang,
                current_user=current_user,
            ),
            timeout=PIPELINE_TIMEOUT_SECONDS,
        )
    except asyncio.TimeoutError:
        logger.warning("Voice verification pipeline timed out")
        raise HTTPException(status_code=504, detail="Verification took too long. Please try again.")

    corrective = result.get("corrective_response", "")
    ai_audio_b64 = ""
    if corrective:
        tts_bytes = await text_to_speech(corrective, detected_lang)
        if tts_bytes:
            ai_audio_b64 = base64.b64encode(tts_bytes).decode("utf-8")
    result["ai_audio_b64"] = ai_audio_b64

    from app.services.blog_generator import auto_generate_blog

    async def _safe_blog_task(r):
        try:
            await auto_generate_blog(r)
        except Exception as exc:
            logger.exception("Background blog generation failed: %s", exc)

    asyncio.create_task(_safe_blog_task(result))
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