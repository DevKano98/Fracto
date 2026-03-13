"""
tests/test_scraper.py — Test RAG web scraper sources individually + full pipeline.
Run: python tests/test_scraper.py
No server needed. Tests live HTTP scraping.
"""
import sys, os, asyncio, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(__file__), '..', '.env'))

from app.services.qwen_scraper import (
    _scrape_duckduckgo,
    _scrape_google_cse,
    _scrape_searxng,
    _scrape_wikipedia,
    _scrape_newsapi_free,
    _scrape_reddit_free,
    _scrape_india_factcheckers,
    _scrape_govt_pib,
    _scrape_telegram_public,
    gather_evidence_free,
)

QUERY = "cow urine cure COVID India misinformation"
RESULTS = {}


def test_source(name, fn, query=QUERY, needs_key=False, key_name=""):
    t0 = time.time()
    try:
        results = fn(query)
        elapsed = time.time() - t0
        count = len(results) if results else 0
        if count > 0:
            status = f"OK  — {count} result(s)"
            RESULTS[name] = ("OK", count, elapsed)
            print(f"  ✓ {name:<25} {status}  ({elapsed:.1f}s)")
            for r in results[:2]:
                cred = r.get("credibility_score", 0)
                title = r.get("title", "")[:55]
                print(f"      [{cred:.2f}] {title}")
        else:
            status = "SKIP — 0 results"
            if needs_key:
                status += f" (check {key_name} in .env)"
            RESULTS[name] = ("SKIP", 0, elapsed)
            print(f"  ~ {name:<25} {status}  ({elapsed:.1f}s)")
    except Exception as e:
        elapsed = time.time() - t0
        RESULTS[name] = ("ERROR", 0, elapsed)
        print(f"  ✗ {name:<25} ERROR: {str(e)[:60]}  ({elapsed:.1f}s)")


async def test_full_pipeline():
    print(f"\n{'─'*60}")
    print("  FULL PIPELINE: gather_evidence_free()")
    print('─'*60)

    claims = [
        ("Cow urine cures COVID-19 and cancer permanently", "en-IN"),
        ("गाय का मूत्र पीने से कैंसर ठीक हो जाता है",      "hi-IN"),
        ("KBC lottery winner — send OTP to claim 10 lakh",   "en-IN"),
    ]

    for claim, lang in claims:
        print(f"\n  Claim: {claim[:60]}")
        t0 = time.time()
        evidence = await gather_evidence_free(claim, lang)
        elapsed = time.time() - t0

        total = evidence.get("total_sources_found", 0)
        print(f"  ✓ Completed in {elapsed:.1f}s")
        print(f"    Total sources:      {total}")
        print(f"    Has govt source:    {evidence.get('has_govt_source')}")
        print(f"    Has factchecker:    {evidence.get('has_factchecker_source')}")
        print(f"    Has news source:    {evidence.get('has_news_source')}")
        print(f"    Qwen pre-verdict:   {evidence.get('qwen_pre_verdict')}  "
              f"(conf: {evidence.get('qwen_pre_confidence', 0):.2f})")
        print(f"    Source breakdown:   {evidence.get('source_counts', {})}")

        if total == 0:
            print("    WARNING: No evidence found — check network/API keys")


if __name__ == "__main__":
    print("=" * 60)
    print("  FRACTA WEB SCRAPER TEST SUITE")
    print(f"  Query: {QUERY}")
    print("=" * 60)
    print("\nIndividual sources:")

    test_source("DuckDuckGo",         _scrape_duckduckgo,         needs_key=False)
    test_source("Wikipedia",          _scrape_wikipedia,          needs_key=False)
    test_source("NewsAPI",            _scrape_newsapi_free,       needs_key=True,  key_name="NEWS_API_KEY")
    test_source("Reddit",             _scrape_reddit_free,        needs_key=False)
    test_source("India Factcheckers", _scrape_india_factcheckers, needs_key=False)
    test_source("PIB FactCheck",      _scrape_govt_pib,           needs_key=False)
    test_source("Telegram",           _scrape_telegram_public,    needs_key=False)
    test_source("Google CSE",         _scrape_google_cse,         needs_key=True,  key_name="GOOGLE_CSE_KEY + GOOGLE_CSE_CX")
    test_source("SearXNG",            _scrape_searxng,            needs_key=False)

    print(f"\n{'─'*60}")
    print("  SUMMARY")
    print('─'*60)
    ok_count = sum(1 for v in RESULTS.values() if v[0] == "OK")
    skip_count = sum(1 for v in RESULTS.values() if v[0] == "SKIP")
    err_count = sum(1 for v in RESULTS.values() if v[0] == "ERROR")
    print(f"  OK: {ok_count}  SKIP: {skip_count}  ERROR: {err_count}")
    if ok_count == 0:
        print("  WARNING: All sources failed — check internet connection")
    elif ok_count < 3:
        print("  WARNING: Few sources working — RAG evidence will be limited")
    else:
        print("  RAG evidence gathering is functional")

    asyncio.run(test_full_pipeline())

    print("\n" + "=" * 60)
    print("  SCRAPER TESTS DONE")
    print("=" * 60)