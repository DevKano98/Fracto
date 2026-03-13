from app.config import settings

HARM_WEIGHTS = {
    "HEALTH_FAKE": 2.0,
    "SCAM": 1.8,
    "FINANCIAL_FAKE": 1.7,
    "POLITICAL_FAKE": 1.6,
    "COMMUNAL": 2.0,
    "TRUE": 0.0,
    "UNKNOWN": 1.0,
}

PLATFORM_MULTIPLIERS = {
    "whatsapp": 1.3,
    "twitter": 1.2,
    "instagram": 1.1,
    "unknown": 1.0,
}


def compute_risk(
    ml_confidence: float,
    llm_confidence: float,
    category: str,
    platform: str,
    shares: int,
    visual_flags: list,
) -> dict:
    harm = HARM_WEIGHTS.get(category.upper(), 1.0)
    platform_multiplier = PLATFORM_MULTIPLIERS.get(platform.lower(), 1.0)

    virality = min(shares / 10000, 1.0) * 3
    confidence = ((ml_confidence + llm_confidence) / 2) * 4

    raw = (virality + confidence) * harm * platform_multiplier

    # Apply visual boosts
    visual_boost = 0.0
    if "manipulation_detected" in visual_flags:
        visual_boost += 1.5
    if "fake_govt_logo" in visual_flags:
        visual_boost += 1.0
    if "morphed_person" in visual_flags:
        visual_boost += 0.5

    raw += visual_boost
    score = round(min(raw / 8 * 10, 10), 1)

    if score >= 7.0:
        level = "HIGH"
    elif score >= 4.0:
        level = "MEDIUM"
    else:
        level = "LOW"

    breakdown = (
        f"virality={virality:.2f} + confidence={confidence:.2f}) "
        f"* harm_weight={harm} * platform_multiplier={platform_multiplier} "
        f"+ visual_boost={visual_boost} → raw={raw:.2f} → score={score}"
    )

    return {
        "score": score,
        "level": level,
        "breakdown": breakdown,
        "action_required": score >= settings.RISK_ACTION_THRESHOLD,
    }