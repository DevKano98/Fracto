# backend/app/routes/admin_routes.py

import asyncio
import base64
from typing import Optional

from fastapi import APIRouter, HTTPException, Depends, BackgroundTasks, UploadFile, File
from pydantic import BaseModel
from app.middleware.auth_middleware import require_admin, require_operator, log_operator_action
from app.database.supabase_client import supabase
from app.services.gemini_verify_service import verify_claim
from app.services.web_scraper import gather_evidence
from app.ml.classifier import classify_claim
from app.services.risk_scorer import compute_risk
from datetime import datetime, timedelta

router = APIRouter(prefix="/admin", tags=["admin"])

# ── Analytics ──────────────────────────────────────────────────
@router.get("/analytics")
async def analytics(operator: dict = Depends(require_operator)):
    today = datetime.utcnow().date().isoformat()

    # Today's counts
    all_today = supabase.table("claims") \
        .select("id, llm_verdict, status, risk_score, ml_category") \
        .gte("created_at", today) \
        .execute().data

    total          = len(all_today)
    fake_count     = sum(1 for r in all_today if r["llm_verdict"] in ("FALSE", "MISLEADING"))
    true_count     = sum(1 for r in all_today if r["llm_verdict"] == "TRUE")
    actioned       = sum(1 for r in all_today if r["status"] != "PENDING")
    high_risk      = sum(1 for r in all_today if r["risk_score"] and r["risk_score"] >= 7.0)
    avg_risk       = sum(r["risk_score"] or 0 for r in all_today) / total if total else 0

    # Category breakdown
    categories = {}
    for r in all_today:
        cat = r["ml_category"] or "UNKNOWN"
        categories[cat] = categories.get(cat, 0) + 1

    # Last 7 days trend
    week_ago = (datetime.utcnow() - timedelta(days=7)).isoformat()
    week_data = supabase.table("claims") \
        .select("created_at, llm_verdict") \
        .gte("created_at", week_ago) \
        .execute().data

    return {
        "today": {
            "total":       total,
            "fake":        fake_count,
            "true":        true_count,
            "actioned":    actioned,
            "high_risk":   high_risk,
            "avg_risk":    round(float(avg_risk), 1) if avg_risk else 0.0
        },
        "categories": categories,
        "week_count": len(week_data)
    }


# ── Blog management ────────────────────────────────────────────
class BlogEditRequest(BaseModel):
    title:   Optional[str] = None
    content: Optional[str] = None
    summary: Optional[str] = None
    published: Optional[bool] = None

@router.get("/blogs")
async def list_blogs(operator: dict = Depends(require_operator)):
    result = supabase.table("blog_posts") \
        .select("id, title, slug, verdict, category, published, views, created_at") \
        .order("created_at", desc=True) \
        .limit(50) \
        .execute()
    return result.data


@router.patch("/blogs/{blog_id}")
async def edit_blog(
    blog_id: str,
    body: BlogEditRequest,
    admin: dict = Depends(require_admin)   # only super_admin can edit
):
    updates = {k: v for k, v in body.dict().items() if v is not None}
    if not updates:
        raise HTTPException(status_code=400, detail="No fields to update")

    supabase.table("blog_posts") \
        .update(updates).eq("id", blog_id).execute()

    log_operator_action(
        admin["id"], "EDIT_BLOG", "blog_post", blog_id,
        f"Fields updated: {list(updates.keys())}"
    )
    return {"message": "Blog updated"}


@router.delete("/blogs/{blog_id}")
async def delete_blog(
    blog_id: str,
    admin: dict = Depends(require_admin)   # only super_admin can delete
):
    # Get cloudinary public_id before deleting for cleanup
    result = supabase.table("blog_posts") \
        .select("cloudinary_public_id, title") \
        .eq("id", blog_id).single().execute()

    if not result.data:
        raise HTTPException(status_code=404, detail="Blog not found")

    # Delete from Cloudinary if image exists
    if result.data.get("cloudinary_public_id"):
        try:
            import cloudinary.uploader
            cloudinary.uploader.destroy(result.data["cloudinary_public_id"])
        except Exception:
            pass   # don't fail deletion if Cloudinary cleanup fails

    supabase.table("blog_posts").delete().eq("id", blog_id).execute()

    log_operator_action(
        admin["id"], "DELETE_BLOG", "blog_post", blog_id,
        f"Deleted: {result.data['title']}"
    )
    return {"message": "Blog deleted"}


# ── Manual claim submission (for testing) ──────────────────────
class ManualClaimRequest(BaseModel):
    raw_text:    str
    platform:    str = "manual"
    source_type: str = "text"
    shares:      int = 0

@router.post("/submit-claim")
async def manual_submit(
    body: ManualClaimRequest,
    operator: dict = Depends(require_operator)
):
    """
    Operators and admin can manually submit claims for testing.
    Runs the full pipeline — ML → scrape → Gemini → risk → save.
    Useful for demo prep and edge case testing.
    """
    ml_result  = classify_claim(body.raw_text)
    evidence   = await gather_evidence(body.raw_text, ml_result["category"])
    gemini_result = await verify_claim(body.raw_text, ml_result, evidence)
    risk = compute_risk(
        ml_result["confidence"],
        gemini_result["llm_confidence"],
        ml_result["category"],
        body.platform,
        body.shares,
        []
    )

    claim_data = {
        "raw_text":           body.raw_text,
        "extracted_claim":    body.raw_text,
        "source_type":        body.source_type,
        "platform":           body.platform,
        "ml_category":        ml_result["category"],
        "ml_confidence":      ml_result["confidence"],
        "llm_verdict":        gemini_result["verdict"],
        "llm_confidence":     gemini_result["llm_confidence"],
        "evidence":           gemini_result["evidence"],
        "sources":            gemini_result["sources"],
        "reasoning_steps":    gemini_result["reasoning_steps"],
        "corrective_response":gemini_result["corrective_response"],
        "risk_score":         risk["score"],
        "risk_level":         risk["level"],
        "status":             "PENDING",
        "submitted_by":       operator["id"]   # track who submitted
    }

    result = supabase.table("claims").insert(claim_data).execute()

    log_operator_action(
        operator["id"], "MANUAL_SUBMIT", "claim",
        result.data[0]["id"], f"Manual test: {body.raw_text[:80]}"
    )

    return result.data[0]


# ── Operator log view ──────────────────────────────────────────
@router.get("/activity-log")
async def activity_log(admin: dict = Depends(require_admin)):
    result = supabase.table("operator_log") \
        .select("*, users(name, email)") \
        .order("created_at", desc=True) \
        .limit(200) \
        .execute()
    return result.data  