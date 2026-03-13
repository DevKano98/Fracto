"""
tests/test_all.py — Master test runner for Fracta backend.
Run: python tests/test_all.py
Runs all tests in order. Stops at pipeline test if server is not running.
"""
import subprocess, sys, time, os

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

TESTS = [
    ("ML Classifier",   os.path.join(BASE_DIR, "test_ml.py"),       False),
    ("Groq / Qwen",     os.path.join(BASE_DIR, "test_groq.py"),     False),
    ("Web Scraper",     os.path.join(BASE_DIR, "test_scraper.py"),  False),
    ("Full Pipeline",   os.path.join(BASE_DIR, "test_pipeline.py"), True),   # needs server
]

results = []
print("=" * 65)
print("  FRACTA — FULL TEST SUITE")
print("=" * 65)

for name, path, needs_server in TESTS:
    print(f"\n{'─'*65}")
    print(f"  RUNNING: {name}")
    if needs_server:
        import requests as req
        try:
            req.get("http://localhost:8000/health", timeout=2)
        except Exception:
            print("  SKIP: Server not running on localhost:8000")
            print("  Start: uvicorn app.main:app --reload --port 8000")
            results.append((name, "SKIP", 0))
            continue
    print('─'*65)

    t0 = time.time()
    proc = subprocess.run([sys.executable, path])
    elapsed = time.time() - t0
    status = "PASS" if proc.returncode == 0 else "FAIL"
    results.append((name, status, elapsed))

print(f"\n{'='*65}")
print("  SUMMARY")
print('─'*65)
for name, status, elapsed in results:
    icon = "✓" if status == "PASS" else ("~" if status == "SKIP" else "✗")
    t = f"{elapsed:.1f}s" if elapsed > 0 else "skipped"
    print(f"  {icon}  {name:<25} {status:<6}  ({t})")

failed = sum(1 for _, s, _ in results if s == "FAIL")
skipped = sum(1 for _, s, _ in results if s == "SKIP")
passed = sum(1 for _, s, _ in results if s == "PASS")

print(f"\n  {passed} passed  |  {failed} failed  |  {skipped} skipped")
print("=" * 65)
sys.exit(0 if failed == 0 else 1)