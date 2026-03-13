"""
tests/test_ml.py — Test ML Classifier in isolation.
Run: python tests/test_ml.py
Requires: app/ml/claim_classifier.pkl + vectorizer.pkl
Create them: python -m app.ml.train_classifier
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from app.ml.classifier import classify_claim, is_loaded

TEST_CLAIMS = [
    ("Drinking cow urine cures COVID-19",                           "HEALTH_FAKE"),
    ("Onion in room absorbs all viruses and protects from disease", "HEALTH_FAKE"),
    ("Send OTP to claim your KBC 10 lakh prize",                    "SCAM"),
    ("Your SBI account will be blocked. Update KYC immediately",    "SCAM"),
    ("RBI has announced new 2000 rupee note with gold coating",     "FINANCIAL_FAKE"),
    ("Buy this crypto coin: guaranteed 10x returns in 30 days",     "FINANCIAL_FAKE"),
    ("EVMs were hacked during election results manipulated",        "POLITICAL_FAKE"),
    ("Opposition party leader arrested for corruption",             "POLITICAL_FAKE"),
    ("Religious group distributing poisoned food at festival",      "COMMUNAL"),
    ("Members of one community attacked temple in city",            "COMMUNAL"),
    ("India wins cricket World Cup defeating Australia",            "TRUE"),
    ("ISRO successfully launches satellite into orbit today",       "TRUE"),
]

def test_classifier():
    print("=" * 70)
    print("FRACTA ML CLASSIFIER TEST")
    print("=" * 70)

    if not is_loaded():
        print("\nFAIL: ML models not loaded.")
        print("Run this first: python -m app.ml.train_classifier")
        sys.exit(1)

    print(f"\n{'Claim':<48} {'Expected':<16} {'Got':<16} {'Conf':>6}  Status")
    print("-" * 100)

    passed = 0
    for claim, expected in TEST_CLAIMS:
        result = classify_claim(claim)
        got = result["category"]
        conf = result["confidence"]
        ok = got == expected
        if ok:
            passed += 1
        status = "PASS" if ok else "FAIL"
        print(f"{claim[:47]:<48} {expected:<16} {got:<16} {conf:>6.2f}  {status}")

    pct = passed / len(TEST_CLAIMS) * 100
    print(f"\nResult: {passed}/{len(TEST_CLAIMS)} passed ({pct:.0f}%)")

    if pct < 75:
        print("\nWARNING: Accuracy below 75%.")
        print("Add more rows to app/ml/labeled_claims.csv and retrain.")
        print("Aim for at least 200 examples, ~33 per category.")
    elif pct < 90:
        print("\nOK: Decent accuracy. More data will improve it further.")
    else:
        print("\nEXCELLENT: High accuracy. Model is well-trained.")

    print("\nTesting edge cases:")
    edge_cases = [
        "गाय का मूत्र पीने से कैंसर ठीक हो जाता है",   # Hindi HEALTH_FAKE
        "WhatsApp pe forward karo 5000 rupees milenge",   # Hinglish SCAM
        "Unknown claim with no clear category",            # UNKNOWN expected
    ]
    for ec in edge_cases:
        result = classify_claim(ec)
        print(f"  [{result['category']} {result['confidence']:.2f}] {ec[:60]}")

    sys.exit(0 if passed >= len(TEST_CLAIMS) * 0.75 else 1)


if __name__ == "__main__":
    test_classifier()