"""
tests/test_groq.py — Test Groq API + Qwen integration.
Run: python tests/test_groq.py
Requires: GROQ_API_KEY in .env (free at console.groq.com)
"""
import sys, os, asyncio, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from dotenv import load_dotenv
load_dotenv(os.path.join(os.path.dirname(__file__), '..', '.env'))

from app.services.groq_service import (
    health_check, analyze_evidence, translate_to_english,
    extract_core_claim, generate_corrective_in_language,
    get_available_models, GROQ_MODELS,
)


def section(title):
    print(f"\n{'─' * 60}")
    print(f"  {title}")
    print('─' * 60)


def result(label, ok, detail=""):
    icon = "✓ PASS" if ok else "✗ FAIL"
    line = f"  {icon}  {label}"
    if detail:
        line += f"\n         {detail}"
    print(line)
    return ok


async def run_tests():
    all_passed = True
    print("=" * 60)
    print("  FRACTA GROQ / QWEN-3-32B TEST SUITE")
    print("=" * 60)

    # ── Test 1: Health check ──────────────────────────────────────────────
    section("1. Health Check + Model Availability")
    t0 = time.time()
    status = health_check()
    elapsed = time.time() - t0

    connected = status.get("groq", False)
    ok = result(f"Groq connected ({elapsed:.2f}s)", connected,
                detail=status.get("reason", "") if not connected else "")
    all_passed &= ok

    if not connected:
        print("\n  STOP: Add GROQ_API_KEY to .env — free at console.groq.com")
        sys.exit(1)

    qwen_ok = status.get("qwen_qwq_available", False)
    result("qwen-3-32b available", qwen_ok,
           detail="Model may still work even if not listed" if not qwen_ok else "")

    # ── Test 2: Model catalogue ───────────────────────────────────────────
    section("2. Free Model Catalogue")
    models = get_available_models()
    for name, info in models.items():
        print(f"  {'●'} {name:<35} ctx:{info['context_window']:>7,}  {info['cost']}")
        print(f"    {info['strength']}")
    result("Models listed", len(models) >= 4)

    # ── Test 3: Translation ───────────────────────────────────────────────
    section("3. Hindi → English Translation (llama-3.1-8b-instant)")
    test_cases = [
        ("गाय का मूत्र पीने से कैंसर ठीक हो जाता है", "cow urine"),
        ("आपका आधार कार्ड ब्लॉक हो जाएगा", "aadhaar"),
        ("This is already English",  "english"),  # should be unchanged
    ]
    for hindi, expect_word in test_cases:
        t0 = time.time()
        translated = await translate_to_english(hindi)
        elapsed = time.time() - t0
        ok = len(translated) > 5
        result(
            f"Translate ({elapsed:.1f}s): {hindi[:40]}",
            ok,
            detail=f"→ {translated[:80]}"
        )
        all_passed &= ok

    # ── Test 4: Claim extraction ──────────────────────────────────────────
    section("4. Core Claim Extraction (llama-3.3-70b)")
    long_texts = [
        (
            "Breaking news from Delhi today. Markets fell 2%. The government announced "
            "new highway projects. Also, scientists confirm that drinking bleach can cure "
            "COVID-19 instantly, according to a viral WhatsApp message. Weather is sunny.",
            "bleach"
        ),
        (
            "KBC mein aapka naam chuna gaya hai. 10 lakh rupees jeete hain aapne. "
            "Claim karne ke liye abhi OTP bhejein. Offer sirf aaj ke liye hai.",
            "KBC"
        ),
    ]
    for text, keyword in long_texts:
        t0 = time.time()
        claim = await extract_core_claim(text)
        elapsed = time.time() - t0
        ok = len(claim) > 10
        result(
            f"Extract ({elapsed:.1f}s): {text[:45]}...",
            ok,
            detail=f"→ {claim[:100]}"
        )
        all_passed &= ok

    # ── Test 5: Evidence analysis ─────────────────────────────────────────
    section("5. Evidence Analysis — qwen-3-32b Chain-of-Thought")
    scenarios = [
        {
            "claim": "Cow urine cures COVID-19 and cancer",
            "evidence": """
SOURCE 1: [govt:PIB_FactCheck] PIB Fact Check
URL: https://pib.gov.in/factcheck/123
CONTENT: Ministry of Health has confirmed: no scientific evidence supports cow urine as
a cure for COVID-19, cancer, or any disease. This claim is FALSE.
Credibility: 0.97

SOURCE 2: [newsapi] WHO warns against fake COVID cures
URL: https://who.int/news/items/123
CONTENT: WHO has repeatedly stated: drink only safe water, seek medical advice,
avoid unproven remedies. Cow urine has no antiviral properties.
Credibility: 0.90

SOURCE 3: [factchecker:AltNews] AltNews fact-check
URL: https://altnews.in/cow-urine-covid-fact-check/
CONTENT: We checked this viral WhatsApp claim. Multiple doctors confirmed it is
baseless and potentially dangerous. Verdict: FALSE.
Credibility: 0.95
            """,
            "expected_verdict": ["FALSE", "MISLEADING"],
            "min_confidence": 0.70,
        },
        {
            "claim": "ISRO successfully launched a satellite today",
            "evidence": """
SOURCE 1: [newsapi] ISRO PSLV launch success
URL: https://isro.gov.in/news/123
CONTENT: ISRO successfully placed the EOS-06 satellite into sun-synchronous orbit.
Launch from Sriharikota was nominal.
Credibility: 0.95

SOURCE 2: [newsapi] The Hindu: ISRO mission success
URL: https://thehindu.com/isro-launch
CONTENT: India's space agency confirmed the successful launch at 9:02 AM IST.
Credibility: 0.85
            """,
            "expected_verdict": ["TRUE"],
            "min_confidence": 0.65,
        },
    ]

    for s in scenarios:
        t0 = time.time()
        result_data = await analyze_evidence(s["evidence"], s["claim"], "en-IN")
        elapsed = time.time() - t0

        verdict_ok = result_data.get("qwen_verdict") in s["expected_verdict"]
        conf_ok = result_data.get("qwen_confidence", 0) >= s["min_confidence"]
        has_thinking = bool(result_data.get("qwen_thinking"))
        backend_ok = result_data.get("qwen_backend_used") not in ("none", "")

        ok = verdict_ok and conf_ok and backend_ok
        all_passed &= ok

        result(
            f"Analyze ({elapsed:.1f}s): {s['claim'][:50]}",
            ok,
            detail=(
                f"verdict={result_data.get('qwen_verdict')} "
                f"confidence={result_data.get('qwen_confidence', 0):.2f} "
                f"backend={result_data.get('qwen_backend_used')}"
            )
        )
        if result_data.get("qwen_summary"):
            print(f"         summary: {result_data['qwen_summary'][:100]}")
        if has_thinking:
            print(f"         thinking: {result_data['qwen_thinking'][:80]}...")

    # ── Test 6: Multilingual corrective ──────────────────────────────────
    section("6. Generate Corrective in Hindi (mixtral-8x7b)")
    correction_en = "Cow urine has no medicinal properties. Consult a real doctor."
    t0 = time.time()
    hindi_correction = await generate_corrective_in_language(correction_en, "hi-IN")
    elapsed = time.time() - t0
    ok = len(hindi_correction) > 10 and hindi_correction != correction_en
    all_passed &= result(
        f"Hindi corrective ({elapsed:.1f}s)",
        ok,
        detail=f"→ {hindi_correction}"
    )

    # ── Summary ───────────────────────────────────────────────────────────
    print(f"\n{'=' * 60}")
    if all_passed:
        print("  ALL GROQ TESTS PASSED ✓")
        print(f"  Models: {', '.join(GROQ_MODELS.values())}")
    else:
        print("  SOME TESTS FAILED ✗  — check output above")
    print("=" * 60)

    sys.exit(0 if all_passed else 1)


if __name__ == "__main__":
    asyncio.run(run_tests())