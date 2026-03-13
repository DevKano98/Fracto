"""
gemini_verify_service.py
Uses GEMINI_KEY_2 for verification and blog generation.
RAG-augmented: injects web evidence from web_scraper.gather_evidence()
into the Gemini prompt before calling the LLM.
"""

import asyncio
import json
import logging
import re
import time

import google.generativeai as genai
from google.api_core.exceptions import ResourceExhausted

from app.config import settings

logger = logging.getLogger(__name__)

genai.configure(api_key=settings.GEMINI_KEY_2)
_verify_model = genai.GenerativeModel("gemini-2.0-flash")  # Updated to stable model

SYSTEM_INSTRUCTION = """You are Fracta, India's AI misinformation defense system.
Analyze the given claim. Use available tools to find evidence.
ALWAYS check at least 2 sources before giving verdict.
Be especially vigilant about: health myths, financial scams, election rumors, communal content.
Return structured output with fields:
  VERDICT: TRUE/FALSE/MISLEADING/UNVERIFIED
  CONFIDENCE: 0.0 to 1.0
  EVIDENCE: one clear sentence
  SOURCES: comma separated list
  REASONING_STEP_1 through REASONING_STEP_N
  CORRECTIVE_RESPONSE: tweet-length correction in same language as input claim"""


def _parse_verification(raw: str) -> dict:
    result = {
        "verdict": "UNVERIFIED",
        "confidence": 0.5,
        "evidence": "",
        "sources": [],
        "reasoning_steps": [],
        "corrective_response": "",
    }
    verdict_match = re.search(r"VERDICT:\s*(TRUE|FALSE|MISLEADING|UNVERIFIED)", raw, re.IGNORECASE)
    if verdict_match:
        result["verdict"] = verdict_match.group(1).upper()
    conf_match = re.search(r"CONFIDENCE:\s*([0-9.]+)", raw, re.IGNORECASE)
    if conf_match:
        try:
            result["confidence"] = float(conf_match.group(1))
        except ValueError:
            pass
    evidence_match = re.search(r"EVIDENCE:\s*(.+?)(?:\nSOURCES:|\nREASONING_STEP_|\Z)", raw, re.IGNORECASE | re.DOTALL)
    if evidence_match:
        result["evidence"] = evidence_match.group(1).strip()
    sources_match = re.search(r"SOURCES:\s*(.+?)(?:\nREASONING_STEP_|\Z)", raw, re.IGNORECASE | re.DOTALL)
    if sources_match:
        sources_raw = sources_match.group(1).strip()
        result["sources"] = [s.strip() for s in sources_raw.split(",") if s.strip()]
    steps = re.findall(r"REASONING_STEP_\d+:\s*(.+?)(?=REASONING_STEP_\d+:|\nCORRECTIVE_|\Z)", raw, re.IGNORECASE | re.DOTALL)
    result["reasoning_steps"] = [s.strip() for s in steps if s.strip()]
    corrective_match = re.search(r"CORRECTIVE_RESPONSE:\s*(.+?)(?:\n[A-Z_]+:|\Z)", raw, re.IGNORECASE | re.DOTALL)
    if corrective_match:
        result["corrective_response"] = corrective_match.group(1).strip()
    return result


async def verify_claim(
    claim_text: str,
    ml_result: dict,
    visual_context: dict,
    language: str,
    rag_evidence: dict | None = None,
) -> dict:
    ml_summary = (
        f"ML Classifier result: category={ml_result.get('category', 'UNKNOWN')}, "
        f"confidence={ml_result.get('confidence', 0.5):.2f}"
    )
    visual_summary = ""
    if visual_context:
        flags = []
        if visual_context.get("fake_govt_logo"):
            flags.append("fake government logo detected")
        if visual_context.get("morphed_person"):
            flags.append("morphed person detected")
        if visual_context.get("manipulation_detected"):
            flags.append("image manipulation detected")
        if flags:
            visual_summary = f"Visual analysis flags: {', '.join(flags)}."

    rag_section = ""
    rag_sources_for_response = []
    if rag_evidence and rag_evidence.get("total_sources_found", 0) > 0:
        qwen = rag_evidence.get("qwen_analysis", {})
        qwen_block = ""
        if qwen.get("qwen_verdict") and qwen.get("qwen_backend_used", "none") != "none":
            qwen_block = (
                f"\nQWEN PRE-ANALYSIS (Qwen already read the web evidence above):\n"
                f"  Qwen Verdict: {qwen.get('qwen_verdict')}\n"
                f"  Qwen Confidence: {qwen.get('qwen_confidence')}\n"
                f"  Qwen Summary: {qwen.get('qwen_summary')}\n"
                f"  Qwen Key Source: {qwen.get('qwen_key_source')}\n"
                f"  Qwen Reasoning: {qwen.get('qwen_reasoning')}\n"
                f"  Qwen Corrective (in claim language): {qwen.get('qwen_corrective')}\n"
                f"\nUse Qwen's analysis as a starting point but verify with sources independently.\n"
            )
        factchecker_flag = (
            "India fact-checker source found (AltNews/BoomLive/FactCheck.in)!"
            if rag_evidence.get("has_factchecker_source") else ""
        )
        rag_section = (
            f"\nREAL-TIME WEB EVIDENCE (retrieved just now — use this as ground truth):\n"
            f"{rag_evidence.get('evidence_summary', '')}\n\n"
            f"Government source found: {rag_evidence.get('has_govt_source', False)}\n"
            f"News source found: {rag_evidence.get('has_news_source', False)}\n"
            f"{factchecker_flag}\n"
            f"Total evidence items: {rag_evidence.get('total_sources_found', 0)}\n"
            f"{qwen_block}\n"
            f"IMPORTANT: Prioritize government > India fact-checkers > news above Reddit/Telegram.\n"
        )
        rag_sources_for_response = [
            item.get("url", "")
            for item in rag_evidence.get("top_sources", rag_evidence.get("all_evidence", []))[:5]
            if item.get("url")
        ]

    prompt = (
        f"{SYSTEM_INSTRUCTION}\n\n"
        f"CLAIM TO ANALYZE:\n\"\"\"{claim_text}\"\"\"\n\n"
        f"LANGUAGE: {language}\n"
        f"{ml_summary}\n"
        f"{visual_summary}\n"
        f"{rag_section}\n"
        f"Analyze this claim thoroughly using the web evidence above and return your structured response."
    )

    loop = asyncio.get_event_loop()
    max_retries = 3
    for attempt in range(max_retries):
        try:
            response = await loop.run_in_executor(
                None, lambda: _verify_model.generate_content(prompt)
            )
            raw = response.text.strip()
            parsed = _parse_verification(raw)
            break  # Success, exit retry loop
        except ResourceExhausted as e:
            if attempt < max_retries - 1:
                wait_time = (2 ** attempt) * 1.0  # Exponential backoff
                logger.warning(f"Gemini quota exceeded, retrying in {wait_time}s (attempt {attempt+1}/{max_retries})")
                await asyncio.sleep(wait_time)
            else:
                logger.error(f"Gemini API quota exhausted after {max_retries} attempts: {e}")
                parsed = {
                    "verdict": "UNVERIFIED",
                    "confidence": 0.0,
                    "evidence": "API quota exceeded",
                    "sources": [],
                    "reasoning_steps": ["API rate limit reached"],
                    "corrective_response": "Unable to verify due to service limits",
                }
        except Exception as e:
            logger.error(f"Gemini API error: {e}")
            parsed = {
                "verdict": "UNVERIFIED",
                "confidence": 0.0,
                "evidence": "API error occurred",
                "sources": [],
                "reasoning_steps": ["Technical error during verification"],
                "corrective_response": "Verification failed due to technical issues",
            }
            break
        }

    if rag_sources_for_response:
        existing = set(parsed["sources"])
        for url in rag_sources_for_response:
            if url not in existing:
                parsed["sources"].append(url)
                existing.add(url)

    ml_conf = ml_result.get("confidence", 0.5)
    llm_conf = parsed["confidence"]
    parsed["conflict_flag"] = abs(ml_conf - llm_conf) > 0.20

    if rag_evidence:
        if rag_evidence.get("has_govt_source") and parsed["verdict"] in ("FALSE", "MISLEADING"):
            parsed["confidence"] = min(parsed["confidence"] + 0.10, 0.99)
            parsed["govt_source_corroborated"] = True
        if rag_evidence.get("has_factchecker_source") and parsed["verdict"] in ("FALSE", "MISLEADING"):
            parsed["confidence"] = min(parsed["confidence"] + 0.08, 0.99)
            parsed["factchecker_corroborated"] = True
        # If Qwen and Gemini agree on verdict, boost confidence
        qwen_pre = rag_evidence.get("qwen_pre_verdict", "")
        if qwen_pre and qwen_pre == parsed["verdict"]:
            parsed["confidence"] = min(parsed["confidence"] + 0.05, 0.99)
            parsed["qwen_gemini_agreement"] = True
        # Include Qwen's corrective response if Gemini's is empty
        if not parsed.get("corrective_response") and rag_evidence.get("qwen_corrective"):
            parsed["corrective_response"] = rag_evidence["qwen_corrective"]

    return parsed


async def generate_blog_content(claim_data: dict) -> dict:
    claim_text = claim_data.get("extracted_claim") or claim_data.get("raw_text", "")
    verdict = claim_data.get("llm_verdict", "FALSE")
    evidence = claim_data.get("evidence", "")
    language = claim_data.get("language", "en-IN")
    corrective = claim_data.get("corrective_response", "")
    category = claim_data.get("ml_category", "UNKNOWN")
    sources = claim_data.get("sources", [])
    source_list = "\n".join(f"- {s}" for s in sources[:5]) if sources else "No sources available"

    prompt = (
        "You are a fact-checking journalist for Fracta, India's misinformation defense platform.\n"
        "Write a comprehensive fact-check blog post about the following misinformation claim.\n\n"
        f"CLAIM: {claim_text}\n"
        f"VERDICT: {verdict}\n"
        f"EVIDENCE: {evidence}\n"
        f"CATEGORY: {category}\n"
        f"SOURCES FOUND:\n{source_list}\n"
        f"CORRECTIVE RESPONSE: {corrective}\n\n"
        "Write a blog post (400-600 words in markdown) covering:\n"
        "1. What the claim says\n"
        "2. Why it is false or misleading (cite sources by URL where possible)\n"
        "3. The truth / correct information\n"
        "4. How readers can protect themselves\n"
        "5. A 'What to share instead' section with the corrective response\n\n"
        f"The corrective_response field must be in language: {language}\n\n"
        "Return ONLY valid JSON with fields: title, slug, summary, content, image_prompt, tags[], corrective_response"
    )

    loop = asyncio.get_event_loop()
    response = await loop.run_in_executor(
        None, lambda: _verify_model.generate_content(prompt)
    )
    raw = response.text.strip()
    raw = re.sub(r"^```json\s*", "", raw)
    raw = re.sub(r"```$", "", raw).strip()
    try:
        return json.loads(raw)
    except Exception as exc:
        logger.error("generate_blog_content JSON parse error: %s", exc)
        slug = re.sub(r"[^a-z0-9]+", "-", claim_text[:50].lower()).strip("-")
        return {
            "title": f"Fact Check: {claim_text[:80]}",
            "slug": slug,
            "summary": evidence,
            "content": f"# Fact Check\n\n{claim_text}\n\n**Verdict:** {verdict}\n\n{evidence}",
            "image_prompt": "India fact-checking journalism professional illustration no text",
            "tags": [category.lower(), "fact-check", "india"],
            "corrective_response": corrective,
        }