"""
trends_routes.py — Trend detection, duplicate clusters, virality data.
"""
import logging

from fastapi import APIRouter, Query

from app.services.trend_detector import (
    duplicate_clusterer,
    social_signal_scorer,
    trend_detector,
    virality_estimator,
)

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/trending")
async def get_trending():
    """Trending misinformation categories in the last 6 hours."""
    categories = trend_detector.get_trending_categories()
    claims = trend_detector.get_trending_claims(limit=10)
    return {
        "trending_categories": categories,
        "trending_claims": claims,
        "window_hours": 6,
    }


@router.get("/clusters")
async def get_clusters(n: int = Query(default=8, ge=2, le=20)):
    """K-Means clusters of recent claims — shows dominant narratives."""
    clusters = duplicate_clusterer.cluster_recent_claims(n_clusters=n)
    return {"clusters": clusters, "total_clusters": len(clusters)}


@router.post("/virality")
async def estimate_virality(
    shares: int = Query(default=0),
    platform: str = Query(default="unknown"),
    language: str = Query(default="en-IN"),
    source_type: str = Query(default="text"),
    category: str = Query(default="UNKNOWN"),
):
    """Estimate virality for a claim before or after verification."""
    result = virality_estimator.estimate(
        shares=shares,
        platform=platform,
        language=language,
        source_type=source_type,
        category=category,
    )
    return result


@router.post("/social-signals")
async def score_social_signals(
    whatsapp_forwards: int = Query(default=0),
    twitter_retweets: int = Query(default=0),
    twitter_likes: int = Query(default=0),
    instagram_shares: int = Query(default=0),
    instagram_views: int = Query(default=0),
    facebook_shares: int = Query(default=0),
    youtube_views: int = Query(default=0),
    telegram_forwards: int = Query(default=0),
    reddit_upvotes: int = Query(default=0),
):
    """Compute unified social threat score from cross-platform signals."""
    result = social_signal_scorer.score(
        whatsapp_forwards=whatsapp_forwards,
        twitter_retweets=twitter_retweets,
        twitter_likes=twitter_likes,
        instagram_shares=instagram_shares,
        instagram_views=instagram_views,
        facebook_shares=facebook_shares,
        youtube_views=youtube_views,
        telegram_forwards=telegram_forwards,
        reddit_upvotes=reddit_upvotes,
    )
    return result