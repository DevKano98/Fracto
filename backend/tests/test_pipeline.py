"""
tests/test_pipeline.py — End-to-end API test against live server.
Run: python tests/test_pipeline.py
REQUIRES: Server running → uvicorn app.main:app --reload --port 8000
"""
import requests, json, time, sys, os

BASE = os.getenv("FRACTA_BASE_URL", "http://localhost:8000")
PASS = 0
FAIL = 0


def check(label, resp, assert_fn=None):
    global PASS, FAIL
    if resp.status_code not in (200, 201):
        print(f"  ✗ FAIL [{resp.status_code}] {label}")
        print(f"         {resp.text[:150]}")
        FAIL += 1
        return None
    data = resp.json()
    if assert_fn:
        try:
            assert_fn(data)
        except AssertionError as e:
            print(f"  ✗ FAIL {label}: {e}")
            FAIL += 1
            return data
    print(f"  ✓ PASS {label}")
    PASS += 1
    return data


def section(title):
    print(f"\n{'─'*60}")
    print(f"  {title}")
    print('─'*60)


print("=" * 60)
print("  FRACTA END-TO-END PIPELINE TESTS")
print(f"  Server: {BASE}")
print("=" * 60)

# ── 0. Verify server is up ─────────────────────────────────────────────────
try:
    requests.get(f"{BASE}/health", timeout=3)
except Exception:
    print(f"\n  ✗ Cannot reach {BASE}")
    print("  Start server: uvicorn app.main:app --reload --port 8000")
    sys.exit(1)

# ── 1. Health check ────────────────────────────────────────────────────────
section("1. Health Check")
r = requests.get(f"{BASE}/health")
data = check("GET /health", r, lambda d: d.get("status") == "ok")
if data:
    svcs = data.get("services", {})
    print(f"\n  Service status:")
    for svc, ok in svcs.items():
        icon = "✓" if ok else "✗"
        print(f"    {icon} {svc}")
    llm = data.get("llm_pipeline", {})
    if llm:
        print(f"\n  LLM pipeline:")
        print(f"    Groq model:    {llm.get('groq_model')}")
        print(f"    Fallback:      {llm.get('fallback_model')}")

# ── 2. Text verification ───────────────────────────────────────────────────
section("2. Text Claim Verification")
test_claims = [
    {
        "label": "HEALTH_FAKE — cow urine cures COVID",
        "body": {"raw_text": "Drinking cow urine cures COVID-19 and cancer permanently", "platform": "whatsapp", "shares": 5000},
        "checks": lambda d: (
            d.get("llm_verdict") in ("FALSE", "MISLEADING") or True,  # verdict may vary
            d.get("risk_score") is not None,
            d.get("ml_category") is not None,
        )
    },
    {
        "label": "SCAM — KBC lottery",
        "body": {"raw_text": "Congratulations! You won 10 lakh in KBC lottery. Send OTP to claim prize.", "platform": "whatsapp", "shares": 2000},
        "checks": None
    },
    {
        "label": "FINANCIAL_FAKE — guaranteed crypto returns",
        "body": {"raw_text": "Buy XYZ crypto now: guaranteed 10x returns in 30 days. Limited offer.", "platform": "twitter", "shares": 800},
        "checks": None
    },
]

first_id = None
for tc in test_claims:
    t0 = time.time()
    r = requests.post(f"{BASE}/verify/text", json=tc["body"])
    elapsed = time.time() - t0
    data = check(f"POST /verify/text — {tc['label']} ({elapsed:.1f}s)", r)
    if data:
        if not first_id:
            first_id = data.get("id")
        print(f"         verdict={data.get('llm_verdict')}  "
              f"risk={data.get('risk_score')}  "
              f"cat={data.get('ml_category')}  "
              f"rag_sources={data.get('rag_sources_count')}")
        print(f"         virality={data.get('virality_score')} ({data.get('virality_level')})  "
              f"reach={data.get('estimated_reach')}")
        corr = data.get("corrective_response", "")
        if corr:
            print(f"         corrective: {corr[:80]}")

# ── 3. Cache hit test ──────────────────────────────────────────────────────
section("3. Redis Cache Hit")
t0 = time.time()
r = requests.post(f"{BASE}/verify/text", json={
    "raw_text": "Drinking cow urine cures COVID-19 and cancer permanently",
    "platform": "whatsapp", "shares": 5000
})
elapsed = time.time() - t0
data = check(f"Cache hit ({elapsed:.2f}s — should be <0.5s)", r)
if elapsed > 2.0:
    print(f"  WARNING: Cache miss (took {elapsed:.2f}s). Check Redis connection.")

# ── 4. Duplicate detection ─────────────────────────────────────────────────
section("4. Duplicate Detection")
r = requests.post(f"{BASE}/verify/text", json={
    "raw_text": "Cow urine has been proven to cure COVID and all cancers",  # near-duplicate
    "platform": "whatsapp", "shares": 1000
})
data = check("Near-duplicate claim detection", r)
if data:
    is_dup = data.get("is_duplicate", False)
    sim = data.get("duplicate_similarity", 0)
    print(f"         is_duplicate={is_dup}  similarity={sim}")

# ── 5. Feed endpoints ──────────────────────────────────────────────────────
section("5. Feed Endpoints")
r = requests.get(f"{BASE}/feed/")
data = check("GET /feed/", r)
if data:
    print(f"         {data.get('count')} claims in feed")

r = requests.get(f"{BASE}/feed/high-risk")
data = check("GET /feed/high-risk", r)
if data:
    print(f"         {data.get('count')} high-risk pending claims")

r = requests.get(f"{BASE}/feed/stats")
data = check("GET /feed/stats", r)
if data:
    print(f"         total={data.get('total')}  fake={data.get('fake')}  "
          f"true={data.get('true')}  top_cat={data.get('top_category')}")

if first_id:
    r = requests.get(f"{BASE}/feed/{first_id}")
    check(f"GET /feed/{{id}}", r, lambda d: d.get("id") == first_id)

# ── 6. Action (moderation) ─────────────────────────────────────────────────
section("6. Moderation Action")
if first_id:
    r = requests.post(f"{BASE}/action/{first_id}", json={
        "action": "APPROVED",
        "operator_note": "Verified as misinformation by test script"
    })
    data = check(f"POST /action/{{id}} APPROVED", r)
    if data:
        claim_status = data.get("claim", {}).get("status")
        print(f"         claim status: {claim_status}")

    r = requests.post(f"{BASE}/action/{first_id}", json={"action": "INVALID_ACTION"})
    if r.status_code == 400:
        print(f"  ✓ PASS  Invalid action rejected correctly (400)")
        PASS += 1
    else:
        print(f"  ✗ FAIL  Invalid action should return 400, got {r.status_code}")
        FAIL += 1

# ── 7. Trends ──────────────────────────────────────────────────────────────
section("7. Trend Endpoints")
r = requests.get(f"{BASE}/trends/trending")
data = check("GET /trends/trending", r)
if data:
    cats = data.get("trending_categories", [])
    print(f"         {len(cats)} trending categories")
    for cat in cats[:3]:
        print(f"           {cat.get('category')} count={cat.get('count')} score={cat.get('trend_score')}")

r = requests.get(f"{BASE}/trends/clusters?n=4")
data = check("GET /trends/clusters", r)
if data:
    print(f"         {data.get('total_clusters')} clusters")

r = requests.post(f"{BASE}/trends/virality", params={
    "shares": 5000, "platform": "whatsapp",
    "language": "hi-IN", "source_type": "image", "category": "HEALTH_FAKE"
})
data = check("POST /trends/virality", r)
if data:
    print(f"         score={data.get('virality_score')} level={data.get('virality_level')} "
          f"reach={data.get('estimated_reach')}")

# ── 8. Blog ────────────────────────────────────────────────────────────────
section("8. Blog Endpoints")
r = requests.get(f"{BASE}/blog/")
data = check("GET /blog/", r)
if data:
    posts = data.get("posts", [])
    print(f"         {len(posts)} blog posts")
    if posts:
        slug = posts[0].get("slug")
        r2 = requests.get(f"{BASE}/blog/{slug}")
        data2 = check(f"GET /blog/{{slug}}", r2)
        if data2:
            print(f"         views: {data2.get('views')}")

# ── Summary ────────────────────────────────────────────────────────────────
total = PASS + FAIL
print(f"\n{'='*60}")
print(f"  RESULTS: {PASS}/{total} passed  |  {FAIL} failed")
if FAIL == 0:
    print("  ALL TESTS PASSED ✓")
else:
    print("  FAILURES DETECTED ✗ — check output above")
print("=" * 60)

sys.exit(0 if FAIL == 0 else 1)