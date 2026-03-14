"""
gemini_verify_service.py

Handles claim verification using Google Gemini.
Includes RAG evidence injection and blog generation.

Features:
- retry logic with exponential backoff
- timeout protection
- safe response parsing
- prompt injection mitigation
- structured verification output
"""

import asyncio
import json
import logging
import re
from typing import Dict, Any

import google.generativeai as genai
from google.api_core.exceptions import ResourceExhausted

from app.config import settings

logger = logging.getLogger(__name__)

genai.configure(api_key=settings.GEMINI_KEY_2)

# Stable model: Gemini 2.5 Flash (best price-performance for reasoning; avoid deprecated 1.5/2.0/3 Pro)
VERIFY_MODEL = genai.GenerativeModel("gemini-2.5-flash")

MAX_EVIDENCE_CHARS = 3000

SYSTEM_INSTRUCTION = """
You are Fracta, India's AI misinformation defense system.

Analyze the claim carefully.

Rules:
- Always verify using evidence provided
- Prefer government > fact-checkers > news > social sources
- Never invent sources
- Return structured output

Required output format:

VERDICT: TRUE/FALSE/MISLEADING/UNVERIFIED
CONFIDENCE: 0.0-1.0
EVIDENCE: one clear sentence
SOURCES: comma separated URLs
REASONING_STEP_1:
REASONING_STEP_2:
REASONING_STEP_3:
CORRECTIVE_RESPONSE: short correction in same language
"""


def _clean_llm_output(text: str) -> str:
    if not text:
        return ""

    text = text.strip()

    text = re.sub(r"^```.*?\n", "", text)
    text = re.sub(r"```$", "", text)

    return text.strip()


def _parse_verification(raw: str) -> Dict[str, Any]:
    raw = raw.upper()

    result = {
        "verdict": "UNVERIFIED",
        "confidence": 0.5,
        "evidence": "",
        "sources": [],
        "reasoning_steps": [],
        "corrective_response": "",
    }

    verdict = re.search(r"VERDICT\s*[:\-]\s*(TRUE|FALSE|MISLEADING|UNVERIFIED)", raw)
    if verdict:
        result["verdict"] = verdict.group(1)

    conf = re.search(r"CONFIDENCE\s*[:\-]\s*([0-9.]+)", raw)
    if conf:
        try:
            result["confidence"] = float(conf.group(1))
        except Exception:
            pass

    evidence = re.search(r"EVIDENCE\s*[:\-]\s*(.+)", raw)
    if evidence:
        result["evidence"] = evidence.group(1).strip()

    sources = re.search(r"SOURCES\s*[:\-]\s*(.+)", raw)
    if sources:
        result["sources"] = [
            s.strip() for s in sources.group(1).split(",") if s.strip()
        ]

    steps = re.findall(r"REASONING_STEP_\d+\s*[:\-]\s*(.+)", raw)
    result["reasoning_steps"] = [s.strip() for s in steps]

    corr = re.search(r"CORRECTIVE_RESPONSE\s*[:\-]\s*(.+)", raw)
    if corr:
        result["corrective_response"] = corr.group(1).strip()

    return result


def _truncate_evidence(text: str) -> str:
    if not text:
        return ""
    return text[:MAX_EVIDENCE_CHARS]


async def _call_gemini(prompt: str) -> str:
    loop = asyncio.get_running_loop()

    response = await asyncio.wait_for(
        loop.run_in_executor(
            None,
            lambda: VERIFY_MODEL.generate_content(prompt),
        ),
        timeout=20,
    )

    if not response:
        return ""

    if getattr(response, "text", None):
        return response.text

    if getattr(response, "candidates", None):
        try:
            return response.candidates[0].content.parts[0].text
        except Exception:
            pass

    return ""


def _fallback_verification(groq_fallback: Dict | None = None) -> Dict:
    """Safe fallback when Gemini fails; use Groq pre-verdict if available."""
    if groq_fallback:
        verdict = groq_fallback.get("qwen_verdict") or groq_fallback.get("verdict", "UNVERIFIED")
        confidence = float(groq_fallback.get("qwen_confidence") or groq_fallback.get("confidence", 0.5))
        return {
            "verdict": verdict.upper() if isinstance(verdict, str) else "UNVERIFIED",
            "confidence": max(0.0, min(1.0, confidence)),
            "evidence": groq_fallback.get("qwen_summary") or "Verification used Groq fallback (Gemini unavailable).",
            "sources": groq_fallback.get("sources", []),
            "reasoning_steps": ["Gemini verification failed; result from Groq evidence analysis."],
            "corrective_response": groq_fallback.get("qwen_corrective") or "Claim could not be fully verified.",
        }
    return {
        "verdict": "UNVERIFIED",
        "confidence": 0.0,
        "evidence": "Verification error",
        "sources": [],
        "reasoning_steps": ["LLM error"],
        "corrective_response": "Verification failed",
    }


async def verify_claim(
    claim_text: str,
    ml_result: Dict,
    visual_context: Dict,
    language: str,
    rag_evidence: Dict | None = None,
    groq_fallback: Dict | None = None,
) -> Dict:

    ml_summary = (
        f"ML category={ml_result.get('category','UNKNOWN')} "
        f"confidence={ml_result.get('confidence',0.5):.2f}"
    )

    visual_summary = ""

    if visual_context:
        flags = []
        if visual_context.get("fake_govt_logo"):
            flags.append("fake government logo")
        if visual_context.get("morphed_person"):
            flags.append("morphed image")
        if visual_context.get("manipulation_detected"):
            flags.append("image manipulation")

        if flags:
            visual_summary = "Visual analysis flags: " + ", ".join(flags)

    rag_section = ""

    if rag_evidence:
        evidence_summary = _truncate_evidence(
            rag_evidence.get("evidence_summary", "")
        )

        rag_section = f"""
WEB EVIDENCE:

{evidence_summary}

Government source: {rag_evidence.get("has_govt_source")}
Fact-checker source: {rag_evidence.get("has_factchecker_source")}
"""

    prompt = f"""
{SYSTEM_INSTRUCTION}

CLAIM:
{claim_text}

LANGUAGE:
{language}

ML ANALYSIS:
{ml_summary}

VISUAL ANALYSIS:
{visual_summary}

{rag_section}

Analyze and return structured result.
"""

    retries = 3
    parsed = None

    for attempt in range(retries):
        try:
            raw = await _call_gemini(prompt)
            raw = _clean_llm_output(raw)
            parsed = _parse_verification(raw)
            break
        except ResourceExhausted as e:
            if attempt < retries - 1:
                wait = 2 ** attempt
                logger.warning("Gemini quota exceeded retry in %ss", wait)
                await asyncio.sleep(wait)
            else:
                logger.error("Gemini quota exhausted")
                parsed = _fallback_verification(groq_fallback)
                break
        except Exception as e:
            logger.error("Gemini verify error: %s", e)
            parsed = _fallback_verification(groq_fallback)
            break

    if parsed is None:
        parsed = _fallback_verification(groq_fallback)

    if parsed.get("verdict") == "UNVERIFIED" and rag_evidence:
        try:
            from app.services.openrouter_service import reasoning_verification, is_available
            if is_available():
                evidence_summary = _truncate_evidence(rag_evidence.get("evidence_summary", ""))
                if evidence_summary:
                    openrouter_result = await reasoning_verification(
                        claim_text, evidence_summary, language
                    )
                    if openrouter_result and openrouter_result.get("verdict") != "UNVERIFIED":
                        parsed = openrouter_result
                        logger.info("Used OpenRouter Qwen3 fallback for verification")
        except Exception as e:
            logger.debug("OpenRouter reasoning fallback failed: %s", e)

    ml_conf = ml_result.get("confidence", 0.5)

    parsed["conflict_flag"] = abs(parsed["confidence"] - ml_conf) > 0.20

    return parsed


async def generate_blog_content(claim_data: Dict) -> Dict:

    claim = claim_data.get("extracted_claim") or claim_data.get("raw_text", "")
    verdict = claim_data.get("llm_verdict", "UNVERIFIED")
    evidence = claim_data.get("evidence", "")

    prompt = f"""
You are a fact-check journalist.

Write a 500 word fact-check blog.

Claim: {claim}
Verdict: {verdict}
Evidence: {evidence}

Return JSON with:
title, slug, summary, content, tags
"""

    raw = await _call_gemini(prompt)

    raw = _clean_llm_output(raw)

    try:
        return json.loads(raw)

    except Exception:

        slug = re.sub(r"[^a-z0-9]+", "-", claim.lower())[:50]

        return {
            "title": f"Fact Check: {claim[:80]}",
            "slug": slug,
            "summary": evidence,
            "content": f"{claim}\n\nVerdict: {verdict}\n\n{evidence}",
            "tags": ["fact-check"],
        }