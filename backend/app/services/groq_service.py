"""
groq_service.py — Production Groq API service for Fracta.

Groq is the PRIMARY free LLM backend for real-time web evidence analysis.
It replaces Perplexity entirely at zero cost.

FREE TIER LIMITS (as of 2025):
  qwen-qwq-32b        → 6000 tokens/min,  14400 req/day  (BEST for reasoning)
  llama-3.3-70b-versatile → 12000 tokens/min, 14400 req/day  (BEST for speed)
  llama-3.1-8b-instant    → 20000 tokens/min, 14400 req/day  (FASTEST, lightweight)
  mixtral-8x7b-32768      → 5000 tokens/min,  14400 req/day  (multilingual)
  gemma2-9b-it            → 15000 tokens/min, 14400 req/day  (compact)

SIGN UP FREE: https://console.groq.com
Get API key:  console.groq.com → API Keys → Create API Key
Add to .env:  GROQ_API_KEY=gsk_xxxxxxxxxxxx

HOW THIS WORKS IN FRACTA:
  1. web scraper gathers raw text from 9 free sources in parallel
  2. groq_service.analyze_evidence() feeds all text to qwen-qwq-32b
  3. Qwen reads everything and returns a structured pre-verdict
  4. That pre-verdict + evidence is injected into Gemini's prompt
  5. Gemini produces the final verdict, now grounded in real evidence

WHY qwen-qwq-32b FOR THIS TASK:
  - "QwQ" = Qwen with Questions = chain-of-thought reasoning model
  - It thinks step-by-step before answering, like a human analyst
  - 32k context = can read 8 full news articles at once
  - Native Hindi/Urdu/Tamil/Bengali = no translation needed
  - Free on Groq with 6000 tokens/min throughput
"""

import asyncio
import json
import logging
import re
import time
from typing import Optional

import requests

from app.config import settings

logger = logging.getLogger(__name__)

# ─────────────────────────────────────────────────────────────────────────────
# Model catalogue — all FREE on Groq
# ─────────────────────────────────────────────────────────────────────────────
GROQ_MODELS = {
    "reasoning": "llama-3.3-70b-versatile",   # primary reasoning model
    "fast": "llama-3.3-70b-versatile",        # fallback
    "instant": "llama-3.1-8b-instant",        # translation / small tasks
    "multilingual": "llama-3.3-70b-versatile" # translation tasks
}

GROQ_API_BASE = "https://api.groq.com/openai/v1"

# ─────────────────────────────────────────────────────────────────────────────
# System prompts — one per task type
# ─────────────────────────────────────────────────────────────────────────────

FACTCHECK_SYSTEM_PROMPT = """You are a senior fact-checker at Fracta, India's AI misinformation defense platform.

Your job: Read web evidence and determine if a claim is true or false.

RULES:
- Base your verdict ONLY on the evidence provided, not your training data
- Prioritize sources in this order: Government (PIB/RBI/SEBI) > India fact-checkers (AltNews/BoomLive) > Major news (Hindu/NDTV/PTI) > General web
- If evidence is contradictory, note the conflict and lean toward authoritative sources
- Be especially critical of: health cures, financial get-rich schemes, election results, communal violence claims
- Always write the CORRECTIVE_RESPONSE in the SAME LANGUAGE and SAME SCRIPT as the original claim
- For Hindi claims: write correction in Hindi (Devanagari script)
- For English claims: write correction in English
- For mixed language: use the dominant language

OUTPUT FORMAT (use these exact labels):
THINKING: [your reasoning process — analyse each evidence item]
VERDICT: [TRUE / FALSE / MISLEADING / UNVERIFIED]
CONFIDENCE: [0.0 to 1.0 — be honest, use 0.3-0.5 if evidence is weak]
EVIDENCE_USED: [which source(s) most supported your verdict]
ONE_LINE_SUMMARY: [single sentence — what is actually true]
CORRECTIVE_RESPONSE: [tweet-length correction in the same language as the claim]
RED_FLAGS: [any suspicious patterns — comma separated or "none"]"""

TRANSLATION_SYSTEM_PROMPT = """You are a multilingual assistant. 
Translate the given text to English accurately.
Preserve all factual claims, numbers, and named entities exactly.
Return ONLY the translation, nothing else."""

CLAIM_EXTRACT_SYSTEM_PROMPT = """You are a claim extraction specialist.
From the given text, extract the single most checkable factual claim.
The claim should be:
- Specific and falsifiable
- The most potentially harmful or misleading statement
- Written as a clear declarative sentence in English
Return ONLY the extracted claim, one sentence, nothing else."""


# ─────────────────────────────────────────────────────────────────────────────
# Core Groq client
# ─────────────────────────────────────────────────────────────────────────────

class GroqClient:
    """
    Thin, dependency-free Groq client using requests.
    Handles: retries, rate limit backoff, model fallback, token counting.
    """

    def __init__(self):
        self.api_key = settings.GROQ_API_KEY
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        })
        self._request_count = 0
        self._last_reset = time.time()

    def _chat(
        self,
        messages: list[dict],
        model: str = "llama-3.3-70b-versatile",
        max_tokens: int = 1500,
        temperature: float = 0.1,
        retries: int = 3,
    ) -> str:
        """
        Call Groq chat completion with automatic retry on rate limit (429).
        Returns the response text or raises on persistent failure.
        """
        if not self.api_key:
            raise ValueError("GROQ_API_KEY not set in environment")

        payload = {
            "model": model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
        }

        for attempt in range(retries):
            try:
                resp = self.session.post(
                    f"{GROQ_API_BASE}/chat/completions",
                    json=payload,
                    timeout=45,
                )

                if resp.status_code == 429:
                    # Rate limited — read retry-after header or back off exponentially
                    retry_after = float(resp.headers.get("retry-after", 2 ** attempt))
                    logger.warning(
                        "Groq rate limit hit (attempt %d/%d). Waiting %.1fs...",
                        attempt + 1, retries, retry_after,
                    )
                    time.sleep(min(retry_after, 10))
                    continue

                if resp.status_code == 503:
                    # Model overloaded — try fallback model
                    if attempt < retries - 1:
                        logger.warning("Groq 503 Overloaded. Retrying with fallback model.")
                        model = GROQ_MODELS["fast"]
                        time.sleep(1)
                        continue
                    
                resp.raise_for_status()
                data = resp.json()
                self._request_count += 1

                content = data["choices"][0]["message"]["content"]

                # Log token usage for monitoring
                usage = data.get("usage", {})
                logger.debug(
                    "Groq %s | tokens: %d prompt + %d completion | req#%d",
                    payload["model"],
                    usage.get("prompt_tokens", 0),
                    usage.get("completion_tokens", 0),
                    self._request_count,
                )

                return content

            except requests.exceptions.RequestException as e:
                logger.error(f"Groq API error (attempt {attempt+1}): {e}")
                if attempt == retries - 1:
                    raise e
                time.sleep(2 ** attempt)

        raise RuntimeError("Groq API failed after all retries")

    def complete(
        self,
        user_message: str,
        system_prompt: str = "",
        model: str = "qwen-3-32b",
        max_tokens: int = 1500,
        temperature: float = 0.1,
    ) -> str:
        """Simple single-turn completion."""
        messages = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": user_message})
        return self._chat(messages, model=model, max_tokens=max_tokens, temperature=temperature)

    def is_available(self) -> bool:
        return bool(self.api_key)

    def get_stats(self) -> dict:
        return {
            "requests_made": self._request_count,
            "api_key_configured": self.is_available(),
            "primary_model": GROQ_MODELS["reasoning"],
        }


# Singleton client
_client: Optional[GroqClient] = None


def get_groq_client() -> GroqClient:
    global _client
    if _client is None:
        _client = GroqClient()
    return _client


# ─────────────────────────────────────────────────────────────────────────────
# Task-specific functions
# ─────────────────────────────────────────────────────────────────────────────

def _parse_factcheck_output(raw: str) -> dict:
    """
    Parse the structured output from qwen-3-32b.
    QwQ outputs a THINKING block first (chain-of-thought), then the answer.
    We capture both — the thinking is valuable for debugging and transparency.
    """
    result = {
        "qwen_verdict": "UNVERIFIED",
        "qwen_confidence": 0.3,
        "qwen_evidence_used": "",
        "qwen_summary": "",
        "qwen_corrective": "",
        "qwen_red_flags": [],
        "qwen_thinking": "",
        "qwen_backend_used": "groq",
    }

    # Extract THINKING block (QwQ chain-of-thought — may be in <think> tags)
    think_match = re.search(r"<think>(.*?)</think>", raw, re.DOTALL | re.IGNORECASE)
    if think_match:
        result["qwen_thinking"] = think_match.group(1).strip()[:2000]
        # Remove thinking block from raw for cleaner parsing below
        raw = raw[think_match.end():].strip()

    # Also check for THINKING: label (our prompt format)
    thinking_label = re.search(r"THINKING:\s*(.+?)(?=VERDICT:|\Z)", raw, re.IGNORECASE | re.DOTALL)
    if thinking_label and not result["qwen_thinking"]:
        result["qwen_thinking"] = thinking_label.group(1).strip()[:2000]

    patterns = {
        "qwen_verdict":        r"VERDICT:\s*(TRUE|FALSE|MISLEADING|UNVERIFIED)",
        "qwen_confidence":     r"CONFIDENCE:\s*([0-9.]+)",
        "qwen_evidence_used":  r"EVIDENCE_USED:\s*(.+?)(?=\n[A-Z_]+:|\Z)",
        "qwen_summary":        r"ONE_LINE_SUMMARY:\s*(.+?)(?=\n[A-Z_]+:|\Z)",
        "qwen_corrective":     r"CORRECTIVE_RESPONSE:\s*(.+?)(?=\n[A-Z_]+:|\Z)",
        "qwen_red_flags":      r"RED_FLAGS:\s*(.+?)(?=\n[A-Z_]+:|\Z)",
    }

    for field, pattern in patterns.items():
        match = re.search(pattern, raw, re.IGNORECASE | re.DOTALL)
        if not match:
            continue
        val = match.group(1).strip()
        if field == "qwen_confidence":
            try:
                result[field] = max(0.0, min(1.0, float(val)))
            except ValueError:
                pass
        elif field == "qwen_red_flags":
            if val.lower() != "none":
                result[field] = [f.strip() for f in val.split(",") if f.strip()]
        else:
            result[field] = val

    return result


async def analyze_evidence(
    evidence_context: str,
    claim: str,
    language: str = "en-IN",
) -> dict:
    """
    PRIMARY FUNCTION — called from qwen_scraper.py.

    Feed all scraped web evidence to Qwen via Groq.
    Returns structured analysis to inject into Gemini's prompt.

    Uses qwen-3-32b which does chain-of-thought reasoning:
      1. Reads each evidence item
      2. Weighs source credibility
      3. Identifies contradictions
      4. Forms a verdict
    All this thinking happens BEFORE Gemini sees the claim.
    """
    client = get_groq_client()
    if not client.is_available():
        logger.warning("Groq not configured — skipping LLM pre-analysis")
        return {
            "qwen_verdict": "UNVERIFIED",
            "qwen_confidence": 0.3,
            "qwen_summary": "Groq not configured.",
            "qwen_backend_used": "none",
        }

    user_message = f"""CLAIM TO FACT-CHECK:
"{claim}"

LANGUAGE OF CLAIM: {language}

WEB EVIDENCE GATHERED IN REAL TIME:
{evidence_context}

Analyze all the evidence above and provide your structured fact-check."""

    loop = asyncio.get_event_loop()
    try:
        raw = await loop.run_in_executor(
            None,
            lambda: client.complete(
                user_message=user_message,
                system_prompt=FACTCHECK_SYSTEM_PROMPT,
                model=GROQ_MODELS["reasoning"],   # qwen-qwq-32b
                max_tokens=1500,
                temperature=0.1,
            ),
        )
        result = _parse_factcheck_output(raw)
        logger.info(
            "Groq analysis complete — verdict=%s confidence=%.2f",
            result["qwen_verdict"],
            result["qwen_confidence"],
        )
        return result

    except Exception as exc:
        logger.error("Groq analyze_evidence failed: %s", exc)
        # Try fallback model
        try:
            raw = await loop.run_in_executor(
                None,
                lambda: client.complete(
                    user_message=user_message,
                    system_prompt=FACTCHECK_SYSTEM_PROMPT,
                    model=GROQ_MODELS["fast"],   # llama-3.3-70b fallback
                    max_tokens=1200,
                    temperature=0.1,
                ),
            )
            result = _parse_factcheck_output(raw)
            result["qwen_backend_used"] = "groq_fallback_llama"
            return result
        except Exception as exc2:
            logger.error("Groq fallback also failed: %s", exc2)
            return {
                "qwen_verdict": "UNVERIFIED",
                "qwen_confidence": 0.3,
                "qwen_summary": f"Groq analysis failed: {exc}",
                "qwen_backend_used": "none",
            }


async def translate_to_english(text: str) -> str:
    """
    Translate any Indian language text to English using Groq.
    Used before ML classifier (which is trained on English).
    Uses llama-3.1-8b-instant for speed (translation doesn't need heavy reasoning).
    """
    if not text or not text.strip():
        return text

    # Quick heuristic: if mostly ASCII, skip translation
    ascii_ratio = sum(1 for c in text if ord(c) < 128) / max(len(text), 1)
    if ascii_ratio > 0.85:
        return text

    client = get_groq_client()
    if not client.is_available():
        return text

    loop = asyncio.get_event_loop()
    try:
        translated = await loop.run_in_executor(
            None,
            lambda: client.complete(
                user_message=text,
                system_prompt=TRANSLATION_SYSTEM_PROMPT,
                model=GROQ_MODELS["instant"],   # llama-3.1-8b — fast, cheap
                max_tokens=500,
                temperature=0.0,   # deterministic translation
            ),
        )
        logger.debug("Translated: %s → %s", text[:50], translated[:50])
        return translated.strip()
    except Exception as exc:
        logger.warning("Groq translation failed: %s", exc)
        return text


async def extract_core_claim(raw_text: str) -> str:
    """
    Extract the single most checkable claim from a long piece of text.
    Useful for URL scrapes or long voice transcripts.
    Uses llama-3.3-70b for good comprehension.
    """
    if len(raw_text) < 100:
        return raw_text

    client = get_groq_client()
    if not client.is_available():
        return raw_text[:500]

    loop = asyncio.get_event_loop()
    try:
        claim = await loop.run_in_executor(
            None,
            lambda: client.complete(
                user_message=raw_text[:4000],  # send first 4k chars
                system_prompt=CLAIM_EXTRACT_SYSTEM_PROMPT,
                model=GROQ_MODELS["fast"],
                max_tokens=200,
                temperature=0.0,
            ),
        )
        return claim.strip()
    except Exception as exc:
        logger.warning("Groq claim extraction failed: %s", exc)
        return raw_text[:500]


async def generate_corrective_in_language(
    correction_english: str,
    target_language: str,
) -> str:
    """
    Translate an English corrective response into the target language.
    Used when Gemini returns correction in English but claim was in Hindi etc.
    """
    if target_language in ("en-IN", "en"):
        return correction_english

    lang_names = {
        "hi-IN": "Hindi (Devanagari script)",
        "bn-IN": "Bengali",
        "ta-IN": "Tamil",
        "te-IN": "Telugu",
        "mr-IN": "Marathi",
        "gu-IN": "Gujarati",
        "kn-IN": "Kannada",
        "ml-IN": "Malayalam",
        "pa-IN": "Punjabi (Gurmukhi script)",
        "ur-IN": "Urdu (Nastaliq script)",
        "or-IN": "Odia",
    }
    lang_name = lang_names.get(target_language, target_language)

    client = get_groq_client()
    if not client.is_available():
        return correction_english

    loop = asyncio.get_event_loop()
    try:
        translated = await loop.run_in_executor(
            None,
            lambda: client.complete(
                user_message=f"Translate this fact-check correction to {lang_name}. Keep it under 280 characters. Original: {correction_english}",
                system_prompt="You are a translator. Return ONLY the translation in the target language and script. Nothing else.",
                model=GROQ_MODELS["reasoning"],   # mixtral — best multilingual
                max_tokens=200,
                temperature=0.0,
            ),
        )
        return translated.strip()
    except Exception as exc:
        logger.warning("Groq translation to %s failed: %s", target_language, exc)
        return correction_english


def get_available_models() -> dict:
    """Returns Groq model catalogue with free tier limits."""
    return {
        "qwen-3-32b": {
            "use_case": "fact-checking, chain-of-thought reasoning",
            "context_window": 32768,
            "tokens_per_minute": 6000,
            "requests_per_day": 14400,
            "cost": "FREE",
            "strength": "Best reasoning, step-by-step analysis, multilingual",
        },
        "llama-3.3-70b-versatile": {
            "use_case": "general analysis, fallback",
            "context_window": 128000,
            "tokens_per_minute": 12000,
            "requests_per_day": 14400,
            "cost": "FREE",
            "strength": "Best speed/quality ratio, large context",
        },
        "llama-3.1-8b-instant": {
            "use_case": "translation, simple extraction",
            "context_window": 128000,
            "tokens_per_minute": 20000,
            "requests_per_day": 14400,
            "cost": "FREE",
            "strength": "Fastest, good for quick tasks",
        },
        "mixtral-8x7b-32768": {
            "use_case": "Hindi/regional language tasks",
            "context_window": 32768,
            "tokens_per_minute": 5000,
            "requests_per_day": 14400,
            "cost": "FREE",
            "strength": "Best multilingual support",
        },
    }


def health_check() -> dict:
    """Quick Groq connectivity check — used by /health endpoint."""
    client = get_groq_client()
    if not client.is_available():
        return {"groq": False, "reason": "GROQ_API_KEY not set"}

    try:
        resp = requests.get(
            f"{GROQ_API_BASE}/models",
            headers={"Authorization": f"Bearer {client.api_key}"},
            timeout=5,
        )
        if resp.status_code == 200:
            models = [m["id"] for m in resp.json().get("data", [])]
            qwen_available = "qwen-3-32b" in models
            return {
    "groq": True,
    "qwen_available": qwen_available,
    "primary_model": GROQ_MODELS["reasoning"],
    "stats": client.get_stats(),
}
    except Exception as exc:
        return {"groq": False, "reason": str(exc)}

    return {"groq": False, "reason": "unexpected response"}