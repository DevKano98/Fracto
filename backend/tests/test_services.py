"""
tests/test_services.py — Validate every API key and service individually.
Run: python tests/test_services.py
Use this BEFORE starting the server to confirm all keys are working.
No server needed — hits external APIs directly.
"""
import sys, os, asyncio, time, requests as req
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(__file__), '..', '.env'))

# Load settings after dotenv
os.environ.setdefault("GEMINI_KEY_1", "")
os.environ.setdefault("GEMINI_KEY_2", "")
os.environ.setdefault("SARVAM_API_KEY", "")
os.environ.setdefault("SUPABASE_URL", "")
os.environ.setdefault("SUPABASE_ANON_KEY", "")
os.environ.setdefault("CLOUDINARY_CLOUD_NAME", "")
os.environ.setdefault("CLOUDINARY_API_KEY", "")
os.environ.setdefault("CLOUDINARY_API_SECRET", "")
os.environ.setdefault("NEWS_API_KEY", "")
os.environ.setdefault("REPLICATE_API_TOKEN", "")
os.environ.setdefault("UPSTASH_REDIS_URL", "")
os.environ.setdefault("UPSTASH_REDIS_TOKEN", "")

RESULTS = {}
TIMEOUT = 8


def check(name, ok, detail="", required=True):
    tag = "REQUIRED" if required else "OPTIONAL"
    icon = "✓" if ok else ("✗" if required else "~")
    status = "OK" if ok else ("MISSING" if required else "SKIP")
    RESULTS[name] = (ok, required)
    line = f"  {icon}  [{tag}]  {name:<28} {status}"
    if detail:
        line += f"  — {detail}"
    print(line)
    return ok


# ── Gemini ────────────────────────────────────────────────────────────────────
def test_gemini():
    print("\n  ── Gemini (Google AI Studio) ─────────────────────────")
    for key_name, env_var in [("GEMINI_KEY_1 (OCR)", "GEMINI_KEY_1"), ("GEMINI_KEY_2 (Verify)", "GEMINI_KEY_2")]:
        key = os.getenv(env_var, "")
        if not key:
            check(key_name, False, f"{env_var} not set — get free key at aistudio.google.com")
            continue
        try:
            import google.generativeai as genai
            genai.configure(api_key=key)
            model = genai.GenerativeModel("gemini-2.5-flash")
            resp = model.generate_content("Say OK", request_options={"timeout": TIMEOUT})
            ok = "ok" in resp.text.lower() or len(resp.text) > 0
            check(key_name, ok, f"response: {resp.text[:30]}")
        except Exception as e:
            check(key_name, False, str(e)[:60])


# ── Groq ─────────────────────────────────────────────────────────────────────
def test_groq():
    print("\n  ── Groq (qwen-qwq-32b — free) ───────────────────────")
    key = os.getenv("GROQ_API_KEY", "")
    if not key:
        check("GROQ_API_KEY", False, "Not set — get FREE key at console.groq.com", required=False)
        return
    try:
        t0 = time.time()
        resp = req.post(
            "https://api.groq.com/openai/v1/chat/completions",
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
            json={"model": "qwen-qwq-32b", "messages": [{"role": "user", "content": "Say OK"}], "max_tokens": 20},
            timeout=TIMEOUT,
        )
        elapsed = time.time() - t0
        if resp.status_code == 200:
            text = resp.json()["choices"][0]["message"]["content"]
            check("GROQ_API_KEY (qwen-qwq-32b)", True, f"{elapsed:.1f}s — {text[:30]}", required=False)
        else:
            check("GROQ_API_KEY", False, f"HTTP {resp.status_code}: {resp.text[:60]}", required=False)
    except Exception as e:
        check("GROQ_API_KEY", False, str(e)[:60], required=False)


# ── Sarvam ────────────────────────────────────────────────────────────────────
def test_sarvam():
    print("\n  ── Sarvam AI (STT/TTS/Language Detect) ──────────────")
    key = os.getenv("SARVAM_API_KEY", "")
    if not key:
        check("SARVAM_API_KEY", False, "Not set — get at sarvam.ai")
        return
    try:
        resp = req.post(
            "https://api.sarvam.ai/text-lid",
            headers={"api-subscription-key": key, "Content-Type": "application/json"},
            json={"input": "Hello this is a test"},
            timeout=TIMEOUT,
        )
        if resp.status_code == 200:
            lang = resp.json().get("language_code", "?")
            check("SARVAM_API_KEY", True, f"language_code returned: {lang}")
        else:
            check("SARVAM_API_KEY", False, f"HTTP {resp.status_code}: {resp.text[:60]}")
    except Exception as e:
        check("SARVAM_API_KEY", False, str(e)[:60])


# ── Supabase ──────────────────────────────────────────────────────────────────
def test_supabase():
    print("\n  ── Supabase (Database) ───────────────────────────────")
    url = os.getenv("SUPABASE_URL", "")
    key = os.getenv("SUPABASE_ANON_KEY", "")
    if not url or not key:
        check("SUPABASE", False, "SUPABASE_URL or SUPABASE_ANON_KEY not set")
        return
    try:
        resp = req.get(
            f"{url}/rest/v1/claims?select=id&limit=1",
            headers={"apikey": key, "Authorization": f"Bearer {key}"},
            timeout=TIMEOUT,
        )
        if resp.status_code == 200:
            check("SUPABASE (claims table)", True, f"table accessible, {len(resp.json())} rows returned")
        elif resp.status_code == 404 or "relation" in resp.text.lower():
            check("SUPABASE (claims table)", False,
                  "Table not found — run SQL schema from supabase_client.py in Supabase SQL Editor")
        else:
            check("SUPABASE", False, f"HTTP {resp.status_code}: {resp.text[:80]}")
    except Exception as e:
        check("SUPABASE", False, str(e)[:60])


# ── Cloudinary ────────────────────────────────────────────────────────────────
def test_cloudinary():
    print("\n  ── Cloudinary (Image CDN) ────────────────────────────")
    cloud = os.getenv("CLOUDINARY_CLOUD_NAME", "")
    api_key = os.getenv("CLOUDINARY_API_KEY", "")
    secret = os.getenv("CLOUDINARY_API_SECRET", "")
    if not all([cloud, api_key, secret]):
        check("CLOUDINARY", False, "CLOUDINARY_CLOUD_NAME/API_KEY/API_SECRET not set")
        return
    try:
        import hashlib
        ts = str(int(time.time()))
        sig_str = f"timestamp={ts}{secret}"
        sig = hashlib.sha1(sig_str.encode()).hexdigest()
        resp = req.get(
            f"https://api.cloudinary.com/v1_1/{cloud}/resources/image",
            params={"max_results": 1, "timestamp": ts, "signature": sig, "api_key": api_key},
            timeout=TIMEOUT,
        )
        if resp.status_code == 200:
            check("CLOUDINARY", True, f"cloud={cloud}, authenticated OK")
        else:
            check("CLOUDINARY", False, f"HTTP {resp.status_code}: {resp.text[:60]}")
    except Exception as e:
        check("CLOUDINARY", False, str(e)[:60])


# ── NewsAPI ───────────────────────────────────────────────────────────────────
def test_newsapi():
    print("\n  ── NewsAPI (100 free/day) ────────────────────────────")
    key = os.getenv("NEWS_API_KEY", "")
    if not key:
        check("NEWS_API_KEY", False, "Not set — get free key at newsapi.org")
        return
    try:
        resp = req.get(
            "https://newsapi.org/v2/everything",
            params={"q": "India", "pageSize": 1, "apiKey": key},
            timeout=TIMEOUT,
        )
        data = resp.json()
        if data.get("status") == "ok":
            total = data.get("totalResults", 0)
            check("NEWS_API_KEY", True, f"{total} articles available")
        else:
            check("NEWS_API_KEY", False, data.get("message", "unknown error")[:60])
    except Exception as e:
        check("NEWS_API_KEY", False, str(e)[:60])


# ── Replicate ─────────────────────────────────────────────────────────────────
def test_replicate():
    print("\n  ── Replicate (SDXL for blog images) ─────────────────")
    token = os.getenv("REPLICATE_API_TOKEN", "")
    if not token:
        check("REPLICATE_API_TOKEN", False, "Not set — get at replicate.com")
        return
    try:
        resp = req.get(
            "https://api.replicate.com/v1/account",
            headers={"Authorization": f"Token {token}"},
            timeout=TIMEOUT,
        )
        if resp.status_code == 200:
            username = resp.json().get("username", "?")
            check("REPLICATE_API_TOKEN", True, f"authenticated as: {username}")
        else:
            check("REPLICATE_API_TOKEN", False, f"HTTP {resp.status_code}: {resp.text[:60]}")
    except Exception as e:
        check("REPLICATE_API_TOKEN", False, str(e)[:60])


# ── Upstash Redis ─────────────────────────────────────────────────────────────
def test_redis():
    print("\n  ── Upstash Redis (Caching) ───────────────────────────")
    url = os.getenv("UPSTASH_REDIS_URL", "")
    token = os.getenv("UPSTASH_REDIS_TOKEN", "")
    if not url or not token:
        check("UPSTASH_REDIS", False, "UPSTASH_REDIS_URL or UPSTASH_REDIS_TOKEN not set")
        return
    try:
        # Write
        resp = req.post(
            f"{url}/set/fracta:test/hello/ex/60",
            headers={"Authorization": f"Bearer {token}"},
            timeout=TIMEOUT,
        )
        if resp.status_code != 200:
            check("UPSTASH_REDIS", False, f"SET failed: {resp.text[:60]}")
            return
        # Read
        resp = req.get(
            f"{url}/get/fracta:test",
            headers={"Authorization": f"Bearer {token}"},
            timeout=TIMEOUT,
        )
        val = resp.json().get("result")
        check("UPSTASH_REDIS", val == "hello", f"SET/GET cycle: {'OK' if val == 'hello' else 'mismatch'}")
    except Exception as e:
        check("UPSTASH_REDIS", False, str(e)[:60])


# ── Optional: Google CSE ──────────────────────────────────────────────────────
def test_google_cse():
    print("\n  ── Google CSE (100 free/day — optional) ─────────────")
    key = os.getenv("GOOGLE_CSE_KEY", "")
    cx = os.getenv("GOOGLE_CSE_CX", "")
    if not key or not cx:
        check("GOOGLE_CSE", False, "GOOGLE_CSE_KEY or GOOGLE_CSE_CX not set (optional)", required=False)
        return
    try:
        resp = req.get(
            "https://www.googleapis.com/customsearch/v1",
            params={"key": key, "cx": cx, "q": "India news", "num": 1},
            timeout=TIMEOUT,
        )
        data = resp.json()
        if "items" in data:
            check("GOOGLE_CSE", True, f"{len(data['items'])} results returned", required=False)
        else:
            check("GOOGLE_CSE", False, data.get("error", {}).get("message", "no items")[:60], required=False)
    except Exception as e:
        check("GOOGLE_CSE", False, str(e)[:60], required=False)


# ── Optional: SearXNG ─────────────────────────────────────────────────────────
def test_searxng():
    print("\n  ── SearXNG (unlimited free — optional) ──────────────")
    base = os.getenv("SEARXNG_BASE_URL", "")
    if not base:
        check("SEARXNG", False, "SEARXNG_BASE_URL not set. docker run searxng/searxng", required=False)
        return
    try:
        resp = req.get(
            f"{base}/search",
            params={"q": "India news", "format": "json", "categories": "news"},
            headers={"Accept": "application/json"},
            timeout=TIMEOUT,
        )
        if resp.status_code == 200:
            count = len(resp.json().get("results", []))
            check("SEARXNG", True, f"{count} results from {base}", required=False)
        else:
            check("SEARXNG", False, f"HTTP {resp.status_code} from {base}", required=False)
    except Exception as e:
        check("SEARXNG", False, f"Cannot reach {base}: {str(e)[:40]}", required=False)


# ── Run all ───────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("=" * 65)
    print("  FRACTA — SERVICE KEY VALIDATION")
    print("  Checking every API key before server start")
    print("=" * 65)

    test_gemini()
    test_groq()
    test_sarvam()
    test_supabase()
    test_cloudinary()
    test_newsapi()
    test_replicate()
    test_redis()
    test_google_cse()
    test_searxng()

    # Summary
    required_ok = sum(1 for name, (ok, req_) in RESULTS.items() if ok and req_)
    required_fail = sum(1 for name, (ok, req_) in RESULTS.items() if not ok and req_)
    optional_ok = sum(1 for name, (ok, req_) in RESULTS.items() if ok and not req_)
    optional_fail = sum(1 for name, (ok, req_) in RESULTS.items() if not ok and not req_)

    print(f"\n{'=' * 65}")
    print(f"  REQUIRED:  {required_ok} OK  |  {required_fail} failing")
    print(f"  OPTIONAL:  {optional_ok} OK  |  {optional_fail} not configured")

    if required_fail == 0:
        print("\n  ✓ All required services configured — safe to start server")
        print("    Run: make dev  OR  uvicorn app.main:app --reload --port 8000")
    else:
        print(f"\n  ✗ {required_fail} required service(s) failing — fix before starting")
        failing = [n for n, (ok, r) in RESULTS.items() if not ok and r]
        for f in failing:
            print(f"    → {f}")
    print("=" * 65)

    sys.exit(0 if required_fail == 0 else 1)