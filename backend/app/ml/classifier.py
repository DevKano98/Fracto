import logging
import os
import re

logger = logging.getLogger(__name__)

CATEGORIES = ["HEALTH_FAKE", "SCAM", "FINANCIAL_FAKE", "POLITICAL_FAKE", "COMMUNAL", "TRUE"]

_pipeline = None
_loaded = False

MODEL_PATH = os.path.join(os.path.dirname(__file__), "claim_classifier.pkl")

def _load_models():
    global _pipeline, _loaded
    try:
        import joblib
        _pipeline = joblib.load(MODEL_PATH)
        _loaded = True
        logger.info("ML classifier pipeline loaded successfully.")
    except FileNotFoundError:
        logger.warning(
            "ML model pipeline not found at %s. "
            "Run ml/train_classifier.py to generate it. Degrading gracefully.",
            MODEL_PATH,
        )
        _loaded = False
    except Exception as exc:
        logger.error("Failed to load ML models: %s", exc)
        _loaded = False

_load_models()

def clean_text(text: str) -> str:
    # basic cleaning logic as requested
    text = re.sub(r'https?://[^\s\n\r]+', '', text)
    text = text.replace('\n', ' ')
    return text.strip()

def classify_claim(text: str) -> dict:
    if not _loaded or _pipeline is None:
        return {"category": "UNKNOWN", "confidence": 0.5, "passed_to_llm": True, "all_scores": {}}

    try:
        cleaned = clean_text(text)
        category = _pipeline.predict([cleaned])[0]
        probas = _pipeline.predict_proba([cleaned])[0]
        confidence = float(max(probas))
        
        all_scores = {str(cls): round(float(p), 3) for cls, p in zip(_pipeline.classes_, probas)}
        passed_to_llm = not (category == "TRUE" and confidence > 0.97)

        return {
            "category": str(category), 
            "confidence": confidence, 
            "passed_to_llm": passed_to_llm, 
            "all_scores": all_scores
        }
    except Exception as exc:
        logger.error("classify_claim error: %s", exc)
        return {"category": "UNKNOWN", "confidence": 0.5, "passed_to_llm": True, "all_scores": {}}

def is_loaded() -> bool:
    return _loaded