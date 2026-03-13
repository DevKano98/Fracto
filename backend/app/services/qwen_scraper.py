"""
qwen_scraper.py — FREE real-time web scraping + Qwen reasoning engine.

Architecture:
  Step 1: Scrape raw text from multiple FREE sources in parallel
            - DuckDuckGo HTML (no key)
            - Google Custom Search (100 free queries/day)
            - Bing Web Search (3 free tiers exist, 1000/month free)
            - SearXNG self-hosted (completely free, no limits)
            - NewsAPI free tier (100 req/day)
            - Government sites direct scrape
            - Reddit public JSON API
            - Telegram public channel scrape
            - Wikipedia API (completely free)
            - Common Crawl index API (completely free)
            - AltNews / BoomLive / FactCheck.in direct scrape (India fact-checkers)

  Step 2: Feed ALL scraped text into Qwen as context
            - Qwen via HuggingFace Inference API (FREE tier available)
            - OR Qwen via Groq API (FREE, very fast)
            - OR Qwen via Ollama local (FREE, offline)
            - OR Qwen via Together AI (free $25 credit)
            Qwen reads all evidence and produces structured verdict

  Step 3: Return structured evidence + Qwen analysis back to Gemini verify pipeline

WHY QWEN FOR THIS TASK:
  - Qwen2.5-72B has 128k context window → can read ALL scraped pages at once
  - Qwen excels at multilingual (Hindi, Urdu, Tamil, Bengali, etc.)
  - Much cheaper/free vs Perplexity
  - Qwen3 supports "thinking" mode for better reasoning
  - On Groq: qwen-qwq-32b is FREE and has chain-of-thought reasoning

FREE API OPTIONS (choose one):
  GROQ_API_KEY    — groq.com — free tier — qwen-qwq-32b or llama models
  HF_API_KEY      — huggingface.co — free tier — Qwen2.5-72B-Instruct
  TOGETHER_API_KEY — together.ai — $25 free credit — Qwen2.5-72B
  OLLAMA_BASE_URL — localhost:11434 — fully offline, no key needed
"""

import asyncio
import json
import logging
import re
import urllib.parse
from typing import Optional

import requests
from bs4 import BeautifulSoup

from app.config import settings

logger = logging.getLogger(__name__)

HTTP_TIMEOUT = 12
MAX_RESULTS_PER_SOURCE = 5
MAX_TEXT_PER_PAGE = 800   # chars — keep context window manageable

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
}


# ============================================================================
# FREE SCRAPING SOURCES
# ============================================================================

def _scrape_duckduckgo(query: str) -> list[dict]:
    """DuckDuckGo HTML — zero API key, zero cost."""
    try:
        resp = requests.get(
            "https://html.duckduckgo.com/html/",
            params={"q": query, "kl": "in-en"},
            headers=HEADERS,
            timeout=HTTP_TIMEOUT,
        )
        resp.raise_for_status()
        soup = BeautifulSoup(resp.text, "html.parser")
        results = []
        for r in soup.select(".result")[:MAX_RESULTS_PER_SOURCE]:
            title_el = soup.select_one(".result__title a")
            snippet_el = r.select_one(".result__snippet")
            title_el = r.select_one(".result__title a")
            title = title_el.get_text(strip=True) if title_el else ""
            snippet = snippet_el.get_text(strip=True) if snippet_el else ""
            href = title_el.get("href", "") if title_el else ""
            parsed = urllib.parse.parse_qs(urllib.parse.urlparse(href).query)
            url = parsed.get("uddg", [href])[0]
            if title:
                results.append({
                    "source": "duckduckgo",
                    "title": title,
                    "snippet": snippet[:MAX_TEXT_PER_PAGE],
                    "url": url,
                    "credibility_score": 0.65,
                })
        return results
    except Exception as exc:
        logger.debug("DuckDuckGo scrape failed: %s", exc)
        return []


def _scrape_google_cse(query: str) -> list[dict]:
    """
    Google Custom Search Engine — 100 free queries/day.
    Requires GOOGLE_CSE_KEY and GOOGLE_CSE_CX in .env.
    Get free at: console.cloud.google.com → Custom Search API → create CX at cse.google.com
    """
    key = getattr(settings, "GOOGLE_CSE_KEY", "")
    cx = getattr(settings, "GOOGLE_CSE_CX", "")
    if not key or not cx:
        return []
    try:
        resp = requests.get(
            "https://www.googleapis.com/customsearch/v1",
            params={"key": key, "cx": cx, "q": query, "num": MAX_RESULTS_PER_SOURCE, "gl": "in"},
            timeout=HTTP_TIMEOUT,
        )
        resp.raise_for_status()
        items = resp.json().get("items", [])
        return [
            {
                "source": "google_cse",
                "title": item.get("title", ""),
                "snippet": item.get("snippet", "")[:MAX_TEXT_PER_PAGE],
                "url": item.get("link", ""),
                "credibility_score": 0.80,
            }
            for item in items
        ]
    except Exception as exc:
        logger.debug("Google CSE failed: %s", exc)
        return []


def _scrape_searxng(query: str) -> list[dict]:
    """
    SearXNG — self-hosted or public instances. COMPLETELY FREE.
    Public instances: https://searx.space (pick a fast one)
    Self-host: docker run -d -p 8888:8080 searxng/searxng
    Set SEARXNG_BASE_URL=https://your-instance.com in .env
    """
    base_url = getattr(settings, "SEARXNG_BASE_URL", "https://searx.be")
    try:
        resp = requests.get(
            f"{base_url.rstrip('/')}/search",
            params={"q": query, "format": "json", "language": "en-IN", "categories": "general,news"},
            headers=HEADERS,
            timeout=HTTP_TIMEOUT,
        )
        resp.raise_for_status()
        results_raw = resp.json().get("results", [])
        return [
            {
                "source": "searxng",
                "title": r.get("title", ""),
                "snippet": r.get("content", "")[:MAX_TEXT_PER_PAGE],
                "url": r.get("url", ""),
                "credibility_score": 0.70,
            }
            for r in results_raw[:MAX_RESULTS_PER_SOURCE]
        ]
    except Exception as exc:
        logger.debug("SearXNG failed: %s", exc)
        return []


def _scrape_wikipedia(query: str) -> list[dict]:
    """Wikipedia API — completely free, no key needed. Great for factual baseline."""
    try:
        # Search endpoint
        search_resp = requests.get(
            "https://en.wikipedia.org/w/api.php",
            params={
                "action": "query",
                "list": "search",
                "srsearch": query,
                "srlimit": 3,
                "format": "json",
                "utf8": 1,
            },
            headers=HEADERS,
            timeout=HTTP_TIMEOUT,
        )
        search_resp.raise_for_status()
        hits = search_resp.json().get("query", {}).get("search", [])

        results = []
        for hit in hits[:2]:  # only top 2 to avoid too much Wikipedia
            page_id = hit.get("pageid")
            title = hit.get("title", "")
            snippet = BeautifulSoup(hit.get("snippet", ""), "html.parser").get_text()

            results.append({
                "source": "wikipedia",
                "title": title,
                "snippet": snippet[:MAX_TEXT_PER_PAGE],
                "url": f"https://en.wikipedia.org/?curid={page_id}",
                "credibility_score": 0.75,
            })
        return results
    except Exception as exc:
        logger.debug("Wikipedia scrape failed: %s", exc)
        return []


def _scrape_newsapi_free(query: str) -> list[dict]:
    """NewsAPI free tier — 100 req/day, great India coverage."""
    if not settings.NEWS_API_KEY:
        return []
    try:
        resp = requests.get(
            "https://newsapi.org/v2/everything",
            params={
                "q": query,
                "language": "en",
                "sortBy": "relevancy",
                "pageSize": MAX_RESULTS_PER_SOURCE,
                "apiKey": settings.NEWS_API_KEY,
            },
            timeout=HTTP_TIMEOUT,
        )
        resp.raise_for_status()
        articles = resp.json().get("articles", [])
        TRUSTED_INDIA = {
            "The Hindu", "NDTV", "Indian Express", "PTI", "ANI",
            "The Wire", "Scroll", "Mint", "Business Standard", "LiveMint",
            "AltNews", "BoomLive", "FactCheck India", "Reuters", "BBC",
        }
        results = []
        for a in articles:
            src_name = a.get("source", {}).get("name", "")
            cred = 0.90 if src_name in TRUSTED_INDIA else 0.70
            results.append({
                "source": "newsapi",
                "title": a.get("title", ""),
                "snippet": (a.get("description") or a.get("content") or "")[:MAX_TEXT_PER_PAGE],
                "url": a.get("url", ""),
                "published_at": a.get("publishedAt", ""),
                "news_source": src_name,
                "credibility_score": cred,
            })
        return results
    except Exception as exc:
        logger.debug("NewsAPI failed: %s", exc)
        return []


def _scrape_reddit_free(query: str) -> list[dict]:
    """Reddit public JSON — no auth, no key, 60 req/min."""
    try:
        resp = requests.get(
            "https://www.reddit.com/r/india+IndiaSpeaks+factcheck/search.json",
            params={"q": query, "limit": MAX_RESULTS_PER_SOURCE, "sort": "relevance"},
            headers={**HEADERS, "Accept": "application/json"},
            timeout=HTTP_TIMEOUT,
        )
        resp.raise_for_status()
        posts = resp.json().get("data", {}).get("children", [])
        return [
            {
                "source": "reddit",
                "title": p["data"].get("title", ""),
                "snippet": (p["data"].get("selftext") or "")[:MAX_TEXT_PER_PAGE],
                "url": "https://reddit.com" + p["data"].get("permalink", ""),
                "credibility_score": min(0.30 + p["data"].get("score", 0) / 20000, 0.55),
            }
            for p in posts if p.get("data")
        ]
    except Exception as exc:
        logger.debug("Reddit scrape failed: %s", exc)
        return []


def _scrape_india_factcheckers(query: str) -> list[dict]:
    """
    Scrape India's top fact-checking sites directly.
    AltNews, BoomLive, FactCheck.in, Vishvas News — all free public websites.
    These are THE most credible sources for India-specific misinformation.
    """
    FACTCHECK_SITES = [
        {
            "name": "AltNews",
            "search": "https://www.altnews.in/?s={query}",
            "credibility": 0.95,
        },
        {
            "name": "BoomLive",
            "search": "https://www.boomlive.in/search?query={query}",
            "credibility": 0.95,
        },
        {
            "name": "FactCheck.in",
            "search": "https://www.factcheck.in/?s={query}",
            "credibility": 0.90,
        },
        {
            "name": "VishvasNews",
            "search": "https://www.vishvasnews.com/?s={query}",
            "credibility": 0.88,
        },
        {
            "name": "NewsMobile",
            "search": "https://newsmobile.in/?s={query}",
            "credibility": 0.85,
        },
    ]
    results = []
    for site in FACTCHECK_SITES:
        try:
            url = site["search"].format(query=urllib.parse.quote(query))
            resp = requests.get(url, headers=HEADERS, timeout=HTTP_TIMEOUT)
            if resp.status_code != 200:
                continue
            soup = BeautifulSoup(resp.text, "html.parser")

            # Generic article title scrape
            for article in soup.select("article, .post, .search-result")[:2]:
                title_el = article.select_one("h2 a, h3 a, .entry-title a, .title a")
                if not title_el:
                    continue
                title_text = title_el.get_text(strip=True)
                article_url = title_el.get("href", "")
                excerpt_el = article.select_one(".entry-content p, .excerpt, .summary, p")
                excerpt = excerpt_el.get_text(strip=True)[:MAX_TEXT_PER_PAGE] if excerpt_el else ""

                if title_text:
                    results.append({
                        "source": f"factchecker:{site['name']}",
                        "title": title_text,
                        "snippet": excerpt,
                        "url": article_url,
                        "credibility_score": site["credibility"],
                    })
        except Exception as exc:
            logger.debug("Factchecker %s failed: %s", site["name"], exc)

    return results[:MAX_RESULTS_PER_SOURCE]


def _scrape_govt_pib(query: str) -> list[dict]:
    """
    PIB Fact Check — Press Information Bureau has a dedicated fact-check section.
    Direct scrape of pib.gov.in/factcheck — the MOST authoritative India source.
    """
    results = []
    try:
        # PIB Fact Check dedicated page
        resp = requests.get(
            "https://pib.gov.in/factcheck.aspx",
            headers=HEADERS,
            timeout=HTTP_TIMEOUT,
        )
        if resp.status_code == 200:
            soup = BeautifulSoup(resp.text, "html.parser")
            for link in soup.select("a")[:30]:
                text = link.get_text(strip=True)
                href = link.get("href", "")
                if len(text) > 20 and any(
                    kw in text.lower() for kw in query.lower().split()[:3]
                ):
                    if not href.startswith("http"):
                        href = "https://pib.gov.in" + href
                    results.append({
                        "source": "govt:PIB_FactCheck",
                        "title": text[:120],
                        "snippet": "Official PIB fact-check.",
                        "url": href,
                        "credibility_score": 0.97,
                    })
                    if len(results) >= 3:
                        break
    except Exception as exc:
        logger.debug("PIB FactCheck scrape failed: %s", exc)

    # Also search general PIB
    try:
        resp2 = requests.get(
            f"https://pib.gov.in/search.aspx?q={urllib.parse.quote(query)}",
            headers=HEADERS,
            timeout=HTTP_TIMEOUT,
        )
        if resp2.status_code == 200:
            soup2 = BeautifulSoup(resp2.text, "html.parser")
            for link in soup2.select(".SearchResult a, .result a")[:3]:
                text = link.get_text(strip=True)
                href = link.get("href", "")
                if len(text) > 20:
                    if not href.startswith("http"):
                        href = "https://pib.gov.in" + href
                    results.append({
                        "source": "govt:PIB",
                        "title": text[:120],
                        "snippet": "From PIB official press releases.",
                        "url": href,
                        "credibility_score": 0.95,
                    })
    except Exception as exc:
        logger.debug("PIB search failed: %s", exc)

    return results[:MAX_RESULTS_PER_SOURCE]


def _scrape_telegram_public(query: str) -> list[dict]:
    """Scrape public Telegram channels via t.me/s/ HTML preview — no API, no key."""
    CHANNELS = ["AltNewsIndia", "boomlive", "TheLogicalIndian", "ndtv", "TheWire_in"]
    results = []
    keywords = set(query.lower().split())
    for channel in CHANNELS:
        try:
            resp = requests.get(
                f"https://t.me/s/{channel}",
                headers=HEADERS,
                timeout=HTTP_TIMEOUT,
            )
            if resp.status_code != 200:
                continue
            soup = BeautifulSoup(resp.text, "html.parser")
            for msg in soup.select(".tgme_widget_message_text")[:15]:
                text = msg.get_text(strip=True)
                if not text:
                    continue
                if sum(1 for kw in keywords if kw in text.lower()) >= 2:
                    results.append({
                        "source": f"telegram:{channel}",
                        "title": f"@{channel}",
                        "snippet": text[:MAX_TEXT_PER_PAGE],
                        "url": f"https://t.me/{channel}",
                        "credibility_score": 0.35,
                    })
                    break
            if len(results) >= MAX_RESULTS_PER_SOURCE:
                break
        except Exception as exc:
            logger.debug("Telegram %s failed: %s", channel, exc)
    return results


def _fetch_page_content(url: str) -> str:
    """
    Fetch and extract clean text from a URL.
    Used to deep-read top results before passing to Qwen.
    """
    try:
        resp = requests.get(url, headers=HEADERS, timeout=HTTP_TIMEOUT)
        resp.raise_for_status()
        soup = BeautifulSoup(resp.text, "html.parser")
        # Remove nav, footer, ads
        for tag in soup(["nav", "footer", "script", "style", "aside", "header", "form"]):
            tag.decompose()
        text = soup.get_text(separator=" ", strip=True)
        # Collapse whitespace
        text = re.sub(r"\s+", " ", text).strip()
        return text[:3000]  # keep top 3000 chars per page for Qwen context
    except Exception as exc:
        logger.debug("Page fetch failed for %s: %s", url, exc)
        return ""


# ============================================================================
# QWEN REASONING ENGINE — powered by groq_service.py
# ============================================================================
# All LLM calls go through groq_service which handles:
#   - model selection (qwen-qwq-32b primary, llama fallback)
#   - retry on rate limit
#   - token usage logging
#   - model fallback on 503
# ============================================================================

from app.services.groq_service import analyze_evidence as _groq_analyze


async def _get_qwen_analysis_async(context: str, claim: str, language: str) -> dict:
    """Route evidence analysis through dedicated groq_service."""
    return await _groq_analyze(context, claim, language)


def _get_qwen_analysis(context: str, claim: str, language: str) -> dict:
    """Sync wrapper — called from gather_evidence_free via run_in_executor."""
    # This is already in a thread, so we need a new event loop
    import asyncio
    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            # We're inside an async context via executor — use asyncio.run in thread
            import concurrent.futures
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                future = executor.submit(asyncio.run, _groq_analyze(context, claim, language))
                return future.result(timeout=50)
        else:
            return loop.run_until_complete(_groq_analyze(context, claim, language))
    except Exception as exc:
        import logging
        logging.getLogger(__name__).error("Qwen analysis failed: %s", exc)
        return {
            "qwen_verdict": "UNVERIFIED",
            "qwen_confidence": 0.3,
            "qwen_summary": f"Analysis failed: {exc}",
            "qwen_backend_used": "none",
        }



# ============================================================================
# DEEP PAGE READER
# ============================================================================

async def _deep_read_top_results(results: list[dict], max_pages: int = 3) -> str:
    """
    Fetch full page content for the top N highest-credibility results.
    This gives Qwen actual article text, not just snippets.
    """
    # Sort by credibility, pick top pages that have URLs
    top = sorted(
        [r for r in results if r.get("url") and r.get("url").startswith("http")],
        key=lambda x: x.get("credibility_score", 0),
        reverse=True,
    )[:max_pages]

    loop = asyncio.get_event_loop()
    tasks = [
        loop.run_in_executor(None, _fetch_page_content, r["url"])
        for r in top
    ]
    page_texts = await asyncio.gather(*tasks, return_exceptions=True)

    sections = []
    for i, (result, text) in enumerate(zip(top, page_texts)):
        if isinstance(text, Exception) or not text:
            continue
        sections.append(
            f"--- SOURCE {i+1}: {result['source'].upper()} | {result['title']} ---\n"
            f"URL: {result['url']}\n"
            f"CREDIBILITY: {result['credibility_score']}\n"
            f"CONTENT: {text}\n"
        )
    return "\n\n".join(sections)


# ============================================================================
# MAIN ORCHESTRATOR
# ============================================================================

async def gather_evidence_free(claim_text: str, language: str = "en-IN") -> dict:
    """
    Full free RAG pipeline:
      1. Parallel scrape from 8+ free sources
      2. Deep-read top 3 pages for full article text
      3. Feed everything into Qwen for structured analysis
      4. Return evidence + Qwen verdict for injection into Gemini

    Returns:
      {
        all_evidence: list of evidence items,
        qwen_analysis: Qwen's verdict on the evidence,
        evidence_summary: plain text for Gemini context injection,
        source_counts: dict,
        has_govt_source: bool,
        has_factchecker_source: bool,
        total_sources_found: int,
      }
    """
    loop = asyncio.get_event_loop()

    # Step 1: Parallel scrape all free sources
    scrape_tasks = [
        loop.run_in_executor(None, _scrape_duckduckgo, claim_text),
        loop.run_in_executor(None, _scrape_google_cse, claim_text),
        loop.run_in_executor(None, _scrape_searxng, claim_text),
        loop.run_in_executor(None, _scrape_wikipedia, claim_text),
        loop.run_in_executor(None, _scrape_newsapi_free, claim_text),
        loop.run_in_executor(None, _scrape_reddit_free, claim_text),
        loop.run_in_executor(None, _scrape_india_factcheckers, claim_text),
        loop.run_in_executor(None, _scrape_govt_pib, claim_text),
        loop.run_in_executor(None, _scrape_telegram_public, claim_text),
    ]
    raw_batches = await asyncio.gather(*scrape_tasks, return_exceptions=True)

    # Merge and deduplicate
    all_evidence = []
    seen_urls: set[str] = set()
    source_counts: dict[str, int] = {}

    for batch in raw_batches:
        if isinstance(batch, Exception):
            continue
        for item in batch:
            url = item.get("url", "")
            if url and url in seen_urls:
                continue
            if url:
                seen_urls.add(url)
            all_evidence.append(item)
            src = item.get("source", "unknown")
            source_counts[src] = source_counts.get(src, 0) + 1

    all_evidence.sort(key=lambda x: x.get("credibility_score", 0), reverse=True)

    has_govt = any(item["source"].startswith("govt:") for item in all_evidence)
    has_factchecker = any(item["source"].startswith("factchecker:") for item in all_evidence)
    has_news = any(item["source"] in ("newsapi", "google_cse") for item in all_evidence)

    # Step 2: Deep-read top pages for full article text
    deep_context = await _deep_read_top_results(all_evidence, max_pages=4)

    # Step 3: Build compact snippet summary for fallback
    snippet_lines = [f"WEB EVIDENCE ({len(all_evidence)} items):"]
    for i, item in enumerate(all_evidence[:8], 1):
        snippet_lines.append(
            f"{i}. [{item['source'].upper()}] {item['title'][:80]} — "
            f"{item['snippet'][:150]} (cred: {item['credibility_score']}) "
            f"URL: {item['url']}"
        )
    snippet_summary = "\n".join(snippet_lines)

    # Combine deep page text + snippets for Qwen
    qwen_context = (deep_context + "\n\n" + snippet_summary).strip()

    # Step 4: Qwen analysis via Groq (qwen-qwq-32b chain-of-thought)
    qwen_analysis = await _get_qwen_analysis_async(qwen_context, claim_text, language)

    # Step 5: Build final evidence_summary for Gemini injection
    qwen_block = ""
    if qwen_analysis.get("qwen_verdict") and qwen_analysis.get("qwen_backend_used") != "none":
        qwen_block = (
            f"\nQWEN PRE-ANALYSIS (from real-time web evidence):\n"
            f"  Verdict: {qwen_analysis.get('qwen_verdict')}\n"
            f"  Confidence: {qwen_analysis.get('qwen_confidence')}\n"
            f"  Summary: {qwen_analysis.get('qwen_summary')}\n"
            f"  Key source: {qwen_analysis.get('qwen_key_source')}\n"
            f"  Reasoning: {qwen_analysis.get('qwen_reasoning')}\n"
            f"  Backend: {qwen_analysis.get('qwen_backend_used')}\n"
        )

    evidence_summary = snippet_summary + "\n" + qwen_block

    return {
        "all_evidence": all_evidence,
        "qwen_analysis": qwen_analysis,
        "evidence_summary": evidence_summary,
        "source_counts": source_counts,
        "has_govt_source": has_govt,
        "has_factchecker_source": has_factchecker,
        "has_news_source": has_news,
        "total_sources_found": len(all_evidence),
        "qwen_pre_verdict": qwen_analysis.get("qwen_verdict", "UNVERIFIED"),
        "qwen_pre_confidence": qwen_analysis.get("qwen_confidence", 0.3),
        "qwen_corrective": qwen_analysis.get("qwen_corrective", ""),
    }