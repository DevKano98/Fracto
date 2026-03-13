import logging

from fastapi import APIRouter

from app.database.queries import get_claim_by_id, get_feed, get_stats_today
from app.database.supabase_client import supabase

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/")
async def get_feed_endpoint(limit: int = 50, offset: int = 0):
    claims = get_feed(limit=limit, offset=offset)
    return {"claims": claims, "count": len(claims)}


@router.get("/high-risk")
async def get_high_risk_feed():
    response = (
        supabase.table("claims")
        .select("*")
        .gte("risk_score", 7.0)
        .eq("status", "PENDING")
        .order("created_at", desc=True)
        .limit(50)
        .execute()
    )
    claims = response.data or []
    return {"claims": claims, "count": len(claims)}


@router.get("/stats")
async def get_stats():
    stats = get_stats_today()
    return stats


@router.get("/{claim_id}")
async def get_claim(claim_id: str):
    claim = get_claim_by_id(claim_id)
    if not claim:
        from fastapi import HTTPException
        raise HTTPException(status_code=404, detail="Claim not found")
    return claim