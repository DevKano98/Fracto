import asyncio
import logging
import time
import requests
import httpx
import praw
from bs4 import BeautifulSoup
from typing import List, Dict
from urllib.parse import quote, urlparse, parse_qs
from telethon import TelegramClient, functions

from app.config import settings

logger = logging.getLogger(__name__)

HTTP_TIMEOUT = 10
MAX_RESULTS = 5

HEADERS = {
    "User-Agent": "Mozilla/5.0"
}


def expand_query(query: str):
    q = query.lower()
    return [
        q,
        q + " fact check",
        q + " myth",
        q + " misinformation"
    ]


# ----------------------------------------------------
# Groq Retry Wrapper
# ----------------------------------------------------
def call_groq_with_retry(client, messages, model, max_retries=3):
    from groq import Groq
    if not isinstance(client, Groq):
        client = Groq(api_key=settings.GROQ_API_KEY)
    for attempt in range(max_retries):
        try:
            return client.chat.completions.create(
                model=model, messages=messages, temperature=0.3)
        except Exception as e:
            if "429" in str(e) and attempt < max_retries - 1:
                time.sleep(2 ** attempt)
                continue
            raise


# ----------------------------------------------------
# DuckDuckGo
# ----------------------------------------------------
def search_duckduckgo(query: str) -> List[Dict]:
    results = []
    try:
        for q in expand_query(query):
            resp = requests.get(
                "https://html.duckduckgo.com/html/",
                params={"q": q, "kl": "in-en"},
                headers=HEADERS,
                timeout=HTTP_TIMEOUT
            )
            soup = BeautifulSoup(resp.text, "html.parser")
            for r in soup.select(".result")[:MAX_RESULTS]:
                title_el = r.select_one(".result__a")
                snippet_el = r.select_one(".result__snippet")
                if not title_el:
                    continue
                href = title_el.get("href")
                parsed = parse_qs(urlparse(href).query)
                clean_url = parsed.get("uddg", [href])[0]
                results.append({
                    "source": "duckduckgo",
                    "title": title_el.text.strip(),
                    "snippet": snippet_el.text.strip() if snippet_el else "",
                    "url": clean_url,
                    "credibility": 0.65
                })
            if results:
                break
    except Exception as e:
        logger.warning("DuckDuckGo failed: %s", e)
    return results[:MAX_RESULTS]


# ----------------------------------------------------
# NewsAPI
# ----------------------------------------------------
def search_news(query: str):
    if not settings.NEWS_API_KEY:
        return []
    results = []
    try:
        resp = requests.get(
            "https://newsapi.org/v2/everything",
            params={
                "q": query,
                "language": "en",
                "sortBy": "relevancy",
                "pageSize": MAX_RESULTS,
                "apiKey": settings.NEWS_API_KEY
            },
            timeout=HTTP_TIMEOUT
        )
        data = resp.json().get("articles", [])
        for a in data:
            results.append({
                "source": "newsapi",
                "title": a.get("title",""),
                "snippet": a.get("description",""),
                "url": a.get("url",""),
                "credibility": 0.85
            })
    except Exception as e:
        logger.warning("NewsAPI failed: %s", e)
    return results[:MAX_RESULTS]


# ----------------------------------------------------
# Government Sites (Search via Google CSE)
# ----------------------------------------------------
def search_government_sources(query: str) -> List[Dict]:
    if not settings.GOOGLE_CSE_KEY or not settings.GOOGLE_CSE_CX:
        return []
    results = []
    try:
        resp = requests.get(
            "https://www.googleapis.com/customsearch/v1",
            params={"key": settings.GOOGLE_CSE_KEY, "cx": settings.GOOGLE_CSE_CX, "q": f"{query} site:gov.in OR site:rbi.org.in OR site:pib.gov.in"},
            timeout=HTTP_TIMEOUT
        )
        items = resp.json().get("items", [])
        for item in items[:MAX_RESULTS]:
            results.append({
                "source": "government_cse",
                "title": item.get("title", ""),
                "snippet": item.get("snippet", ""),
                "url": item.get("link", ""),
                "credibility": 0.95
            })
    except Exception as e:
        logger.warning("Google CSE failed: %s", e)
    return results


# ----------------------------------------------------
# Reddit (Praw Wrapper)
# ----------------------------------------------------
def search_reddit_sync(query: str) -> List[Dict]:
    if not settings.REDDIT_CLIENT_ID or not settings.REDDIT_CLIENT_SECRET:
        return []
    results = []
    try:
        reddit = praw.Reddit(
            client_id=settings.REDDIT_CLIENT_ID,
            client_secret=settings.REDDIT_CLIENT_SECRET,
            user_agent="FractaBot/1.0"
        )
        for d in reddit.subreddit("all").search(query, limit=3):
            score = d.score
            cred = min(0.35 + (score / 10000) * 0.15, 0.50)
            results.append({
                "source": "reddit",
                "title": d.title,
                "url": "https://reddit.com" + d.permalink,
                "snippet": d.selftext[:200],
                "credibility": round(cred, 2)
            })
    except Exception as e:
        logger.warning(f"Reddit search failed: {e}")
    return results

async def search_reddit_async(query: str) -> List[Dict]:
    return await asyncio.to_thread(search_reddit_sync, query)


# ----------------------------------------------------
# YouTube (Async)
# ----------------------------------------------------
async def search_youtube(query: str) -> list[dict]:
    if not settings.YOUTUBE_API_KEY:
        return []
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            response = await client.get(
                "https://www.googleapis.com/youtube/v3/search",
                params={"q": query, "part": "snippet", "type": "video",
                        "relevanceLanguage": "hi", "regionCode": "IN",
                        "maxResults": 3, "key": settings.YOUTUBE_API_KEY})
        items = response.json().get("items", [])
        return [{
            "source": "youtube",
            "title": i["snippet"]["title"],
            "url": f"https://youtube.com/watch?v={i['id']['videoId']}",
            "snippet": i["snippet"]["description"][:200],
            "credibility": 0.7
        } for i in items]
    except Exception as e:
        print(f"YouTube search failed: {e}")
        return []


# ----------------------------------------------------
# Telegram (Async)
# ----------------------------------------------------
async def search_telegram(query: str) -> list[dict]:
    if not settings.TELEGRAM_API_ID or not settings.TELEGRAM_API_HASH:
        return []
    INDIA_CHANNELS = ["PIBFactCheck", "factcheckindia"]
    results = []
    try:
        async with TelegramClient("fracta_session",
            int(settings.TELEGRAM_API_ID), settings.TELEGRAM_API_HASH) as client:
            for channel in INDIA_CHANNELS:
                try:
                    msgs = await client(functions.messages.SearchRequest(
                        peer=channel, q=query, filter=None,
                        min_date=None, max_date=None, offset_id=0,
                        add_offset=0, limit=3, max_id=0, min_id=0, hash=0))
                    for msg in msgs.messages[:3]:
                        if getattr(msg, 'message', None):
                            results.append({
                                "source": f"telegram/{channel}",
                                "title": f"Telegram: {channel}",
                                "url": f"https://t.me/{channel}",
                                "snippet": msg.message[:300],
                                "credibility": 0.95 if channel == "PIBFactCheck" else 0.5
                            })
                except Exception:
                    continue
    except Exception as e:
        print(f"Telegram search failed: {e}")
    return results


# ----------------------------------------------------
# Evidence Aggregator
# ----------------------------------------------------
async def gather_evidence(claim: str, language: str = "en") -> dict:
    loop = asyncio.get_running_loop()
    
    # Gather all sources concurrently
    ddg, news, govt, reddit, youtube, telegram = await asyncio.gather(
        loop.run_in_executor(None, search_duckduckgo, claim),
        loop.run_in_executor(None, search_news, claim),
        loop.run_in_executor(None, search_government_sources, claim),
        search_reddit_async(claim),
        search_youtube(claim),
        search_telegram(claim)
    )

    batches = [ddg, news, govt, reddit, youtube, telegram]
    
    merged = []
    seen = set()

    for batch in batches:
        for item in batch:
            url = item["url"]
            if url in seen:
                continue
            seen.add(url)
            merged.append(item)

    merged.sort(key=lambda x: x.get("credibility", 0.0) or x.get("credibility_score", 0.0), reverse=True)
    top = merged[:12]

    summary = ["EVIDENCE SOURCES:"]
    for i, e in enumerate(top, 1):
        cred = e.get("credibility", e.get("credibility_score", 0))
        summary.append(
            f"{i}. [{e['source']}] {e['title']} — {e['snippet'][:120]} (cred:{cred})"
        )

    # Note: Groq check could be run here if desired, as requested in the prompt.
    # Currently just returning standard RAG format
    return {
        "all_evidence": merged,
        "top_sources": top,
        "evidence_summary": "\n".join(summary),
        "total_sources_found": len(merged),
        "source_count": len(merged)
    }