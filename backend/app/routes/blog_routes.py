import logging

from fastapi import APIRouter, HTTPException

from app.database.queries import get_blog_by_slug, get_blog_posts
from app.database.supabase_client import supabase

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/")
async def list_blogs(limit: int = 20):
    posts = get_blog_posts(limit=limit)
    return {"posts": posts, "count": len(posts)}


@router.get("/category/{category}")
async def get_blogs_by_category(category: str, limit: int = 20):
    response = (
        supabase.table("blog_posts")
        .select("*")
        .eq("published", True)
        .eq("category", category.upper())
        .order("created_at", desc=True)
        .limit(limit)
        .execute()
    )
    posts = response.data or []
    return {"posts": posts, "count": len(posts), "category": category.upper()}


@router.get("/{slug}")
async def get_blog(slug: str):
    post = get_blog_by_slug(slug)
    if not post:
        raise HTTPException(status_code=404, detail="Blog post not found")

    # Increment views counter
    current_views = post.get("views", 0) or 0
    try:
        supabase.table("blog_posts").update({"views": current_views + 1}).eq("slug", slug).execute()
        post["views"] = current_views + 1
    except Exception as exc:
        logger.warning("Could not increment views for slug=%s: %s", slug, exc)

    return post