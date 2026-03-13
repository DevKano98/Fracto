import logging
from datetime import date, datetime, timezone

from app.database.supabase_client import supabase

logger = logging.getLogger(__name__)


def insert_claim(claim_data: dict) -> dict:
    response = supabase.table("claims").insert(claim_data).execute()
    return response.data[0] if response.data else {}


def get_feed(limit: int = 50, offset: int = 0) -> list:
    response = (
        supabase.table("claims")
        .select("*")
        .order("created_at", desc=True)
        .range(offset, offset + limit - 1)
        .execute()
    )
    return response.data or []


def get_claim_by_id(claim_id: str) -> dict:
    response = (
        supabase.table("claims").select("*").eq("id", claim_id).execute()
    )
    return response.data[0] if response.data else {}


def update_claim_status(claim_id: str, status: str, operator_id: str, note: str) -> None:
    supabase.table("claims").update({"status": status}).eq("id", claim_id).execute()


def insert_audit_log(claim_id: str, action: str, operator_id: str, note: str) -> None:
    supabase.table("audit_log").insert(
        {"claim_id": claim_id, "action": action, "reviewed_by": operator_id, "operator_note": note}
    ).execute()


def insert_operator_log(operator_id: str, action: str, target_type: str, target_id: str, detail: str, ip: str) -> None:
    supabase.table("operator_log").insert({
        "operator_id": operator_id,
        "action": action,
        "target_type": target_type,
        "target_id": target_id,
        "detail": detail,
        "ip_address": ip
    }).execute()


def insert_blog_post(blog_data: dict) -> dict:
    response = supabase.table("blog_posts").insert(blog_data).execute()
    return response.data[0] if response.data else {}


def get_blog_posts(limit: int = 20, offset: int = 0) -> list:
    response = (
        supabase.table("blog_posts")
        .select("*")
        .eq("published", True)
        .order("created_at", desc=True)
        .range(offset, offset + limit - 1)
        .execute()
    )
    return response.data or []


def get_blog_by_slug(slug: str) -> dict:
    response = (
        supabase.table("blog_posts").select("*").eq("slug", slug).execute()
    )
    return response.data[0] if response.data else {}


def get_blog_by_category(category: str, limit: int = 20) -> list:
    response = (
        supabase.table("blog_posts")
        .select("*")
        .eq("published", True)
        .eq("category", category)
        .order("created_at", desc=True)
        .limit(limit)
        .execute()
    )
    return response.data or []


def increment_blog_views(blog_id: str) -> None:
    res = supabase.table("blog_posts").select("views").eq("id", blog_id).execute()
    if res.data:
        views = res.data[0].get("views", 0) + 1
        supabase.table("blog_posts").update({"views": views}).eq("id", blog_id).execute()


def get_stats_today() -> dict:
    today_start = datetime.now(timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    ).isoformat()

    response = (
        supabase.table("claims")
        .select("llm_verdict, status, ml_category")
        .gte("created_at", today_start)
        .execute()
    )
    rows = response.data or []

    total = len(rows)
    fake = sum(1 for r in rows if r.get("llm_verdict") in ("FALSE", "MISLEADING"))
    true = sum(1 for r in rows if r.get("llm_verdict") == "TRUE")
    actioned = sum(1 for r in rows if r.get("status") in ("APPROVED", "REJECTED", "OVERRIDDEN"))

    category_counts: dict = {}
    for r in rows:
        cat = r.get("ml_category") or "UNKNOWN"
        category_counts[cat] = category_counts.get(cat, 0) + 1

    top_category = max(category_counts, key=lambda k: category_counts[k]) if category_counts else None

    return {
        "total": total,
        "fake": fake,
        "true": true,
        "actioned": actioned,
        "top_category": top_category,
        "category_breakdown": category_counts,
        "date": date.today().isoformat(),
    }


def get_users_by_role(role: str) -> list:
    response = supabase.table("users").select("*").eq("role", role).execute()
    return response.data or []


def create_user(user_data: dict) -> dict:
    response = supabase.table("users").insert(user_data).execute()
    return response.data[0] if response.data else {}


def get_user_by_email(email: str) -> dict:
    response = supabase.table("users").select("*").eq("email", email).execute()
    return response.data[0] if response.data else {}


def get_user_by_id(user_id: str) -> dict:
    response = supabase.table("users").select("*").eq("id", user_id).execute()
    return response.data[0] if response.data else {}


def update_user(user_id: str, updates: dict) -> None:
    supabase.table("users").update(updates).eq("id", user_id).execute()


def insert_refresh_token(user_id: str, token_hash: str, expires_at: str) -> None:
    supabase.table("refresh_tokens").insert({
        "user_id": user_id,
        "token_hash": token_hash,
        "expires_at": expires_at
    }).execute()


def get_refresh_token(token_hash: str) -> dict:
    response = supabase.table("refresh_tokens").select("*").eq("token_hash", token_hash).execute()
    return response.data[0] if response.data else {}


def delete_refresh_token(token_hash: str) -> None:
    supabase.table("refresh_tokens").delete().eq("token_hash", token_hash).execute()


def delete_all_refresh_tokens(user_id: str) -> None:
    supabase.table("refresh_tokens").delete().eq("user_id", user_id).execute()


def insert_user_report(claim_id: str, reported_by: str, report_type: str, note: str) -> None:
    supabase.table("user_reports").insert({
        "claim_id": claim_id,
        "reported_by": reported_by,
        "report_type": report_type,
        "user_note": note
    }).execute()