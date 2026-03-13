from datetime import datetime
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field


class ClaimInput(BaseModel):
    raw_text: str = Field(..., min_length=1)
    source_type: str = Field(default="text")
    platform: str = Field(default="unknown")
    shares: int = Field(default=0, ge=0)
    # Optional cross-platform signal overrides
    extra_signals: Optional[Dict[str, int]] = Field(default=None)


class ClaimResponse(BaseModel):
    id: Optional[str] = None
    raw_text: Optional[str] = None
    extracted_claim: Optional[str] = None
    source_type: Optional[str] = None
    platform: Optional[str] = None
    language: Optional[str] = None
    ml_category: Optional[str] = None
    ml_confidence: Optional[float] = None
    llm_verdict: Optional[str] = None
    llm_confidence: Optional[float] = None
    evidence: Optional[str] = None
    sources: Optional[List[str]] = None
    reasoning_steps: Optional[List[str]] = None
    corrective_response: Optional[str] = None
    risk_score: Optional[float] = None
    risk_level: Optional[str] = None
    visual_flags: Optional[List[str]] = None
    status: Optional[str] = None
    created_at: Optional[datetime] = None
    # Enrichment fields
    conflict_flag: Optional[bool] = None
    govt_source_corroborated: Optional[bool] = None
    ai_audio_b64: str = ""
    # Virality
    virality_score: Optional[float] = None
    virality_level: Optional[str] = None
    estimated_reach: Optional[str] = None
    # Social signals
    social_threat_score: Optional[float] = None
    social_recommended_action: Optional[str] = None
    # RAG
    rag_sources_count: Optional[int] = None
    # Duplicate detection
    is_duplicate: Optional[bool] = None
    duplicate_similarity: Optional[float] = None

    class Config:
        from_attributes = True


class ActionInput(BaseModel):
    action: str = Field(..., description="APPROVED | REJECTED | OVERRIDDEN")
    operator_note: str = Field(default="")