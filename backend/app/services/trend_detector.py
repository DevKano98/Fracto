"""
trend_detector.py — Real-time trend detection, duplicate clustering,
virality estimation, and social signal scoring.

Modules:
  TrendDetector      — detects emerging claim clusters in the last N hours
  DuplicateClustered — groups near-duplicate claims using TF-IDF cosine similarity
  ViralityEstimator  — predicts virality score from shares/platform/language/timing
  SocialSignalScorer — aggregates cross-platform signals into a unified score
"""

import hashlib
import logging
import math
from datetime import datetime, timedelta, timezone
from typing import Optional

from app.config import settings
from app.database.supabase_client import supabase

logger = logging.getLogger(__name__)


# ============================================================================
# TREND DETECTOR
# ============================================================================

class TrendDetector:
    """
    Identifies claims that are spiking in frequency over a rolling time window.
    Uses a sliding window count stored in Upstash Redis.
    Also queries Supabase for cluster summaries.
    """

    WINDOW_HOURS = 6        # rolling window for trend detection
    SPIKE_THRESHOLD = 3     # min claims in window to count as a trend
    MAX_TRENDS = 10

    def _redis_get(self, key: str):
        import requests as rq
        try:
            resp = rq.get(
                f"{settings.UPSTASH_REDIS_URL}/get/{key}",
                headers={"Authorization": f"Bearer {settings.UPSTASH_REDIS_TOKEN}"},
                timeout=5,
            )
            return resp.json().get("result")
        except Exception:
            return None

    def _redis_incr_with_expiry(self, key: str, ex_seconds: int = 21600):
        import requests as rq
        try:
            rq.post(
                f"{settings.UPSTASH_REDIS_URL}/incr/{key}",
                headers={"Authorization": f"Bearer {settings.UPSTASH_REDIS_TOKEN}"},
                timeout=5,
            )
            rq.post(
                f"{settings.UPSTASH_REDIS_URL}/expire/{key}/{ex_seconds}",
                headers={"Authorization": f"Bearer {settings.UPSTASH_REDIS_TOKEN}"},
                timeout=5,
            )
        except Exception as exc:
            logger.debug("Redis incr failed: %s", exc)

    def record_claim_category(self, category: str, platform: str):
        """Call this every time a new claim is verified."""
        hour_bucket = datetime.now(timezone.utc).strftime("%Y%m%d%H")
        key = f"fracta:trend:{category}:{platform}:{hour_bucket}"
        self._redis_incr_with_expiry(key, ex_seconds=self.WINDOW_HOURS * 3600 + 3600)

    def get_trending_categories(self) -> list[dict]:
        """
        Pull recent claims from Supabase and count category frequency
        in the last WINDOW_HOURS hours. Returns sorted trending list.
        """
        since = (
            datetime.now(timezone.utc) - timedelta(hours=self.WINDOW_HOURS)
        ).isoformat()

        try:
            resp = (
                supabase.table("claims")
                .select("ml_category, platform, risk_level, created_at")
                .gte("created_at", since)
                .execute()
            )
            rows = resp.data or []
        except Exception as exc:
            logger.error("TrendDetector Supabase query failed: %s", exc)
            return []

        # Count by category
        counts: dict[str, dict] = {}
        for row in rows:
            cat = row.get("ml_category") or "UNKNOWN"
            plat = row.get("platform") or "unknown"
            risk = row.get("risk_level") or "LOW"

            if cat not in counts:
                counts[cat] = {
                    "category": cat,
                    "count": 0,
                    "platforms": {},
                    "high_risk_count": 0,
                }
            counts[cat]["count"] += 1
            counts[cat]["platforms"][plat] = counts[cat]["platforms"].get(plat, 0) + 1
            if risk == "HIGH":
                counts[cat]["high_risk_count"] += 1

        trending = [
            v for v in counts.values() if v["count"] >= self.SPIKE_THRESHOLD
        ]
        trending.sort(key=lambda x: (x["high_risk_count"], x["count"]), reverse=True)

        for t in trending:
            t["top_platform"] = max(t["platforms"], key=lambda k: t["platforms"][k])
            t["trend_score"] = round(
                (t["count"] * 0.6 + t["high_risk_count"] * 2.0), 2
            )

        return trending[: self.MAX_TRENDS]

    def get_trending_claims(self, limit: int = 10) -> list[dict]:
        """Returns the actual claims that are currently trending (high risk + recent)."""
        since = (
            datetime.now(timezone.utc) - timedelta(hours=self.WINDOW_HOURS)
        ).isoformat()
        try:
            resp = (
                supabase.table("claims")
                .select("*")
                .gte("created_at", since)
                .gte("risk_score", 6.0)
                .order("risk_score", desc=True)
                .limit(limit)
                .execute()
            )
            return resp.data or []
        except Exception as exc:
            logger.error("get_trending_claims failed: %s", exc)
            return []


# ============================================================================
# DUPLICATE CLUSTERER
# ============================================================================

class DuplicateClusterer:
    """
    Clusters near-duplicate claims using TF-IDF cosine similarity.
    Prevents the same viral claim from being fact-checked multiple times.
    Returns the canonical claim ID if a near-duplicate is found.
    """

    SIMILARITY_THRESHOLD = 0.72   # cosine similarity to count as duplicate
    LOOKBACK_HOURS = 48

    def _get_recent_claims(self) -> list[dict]:
        since = (
            datetime.now(timezone.utc) - timedelta(hours=self.LOOKBACK_HOURS)
        ).isoformat()
        try:
            resp = (
                supabase.table("claims")
                .select("id, raw_text, extracted_claim, llm_verdict, risk_score")
                .gte("created_at", since)
                .order("created_at", desc=True)
                .limit(500)
                .execute()
            )
            return resp.data or []
        except Exception as exc:
            logger.error("DuplicateClusterer fetch failed: %s", exc)
            return []

    def find_duplicate(self, new_text: str) -> Optional[dict]:
        """
        Returns the most similar existing claim if similarity >= threshold,
        otherwise returns None.
        """
        try:
            from sklearn.feature_extraction.text import TfidfVectorizer
            from sklearn.metrics.pairwise import cosine_similarity
            import numpy as np
        except ImportError:
            logger.warning("scikit-learn not available for duplicate detection.")
            return None

        existing = self._get_recent_claims()
        if not existing:
            return None

        corpus = [
            (r.get("extracted_claim") or r.get("raw_text") or "")
            for r in existing
        ]
        corpus_with_new = corpus + [new_text]

        try:
            vec = TfidfVectorizer(max_features=3000, ngram_range=(1, 2))
            tfidf_matrix = vec.fit_transform(corpus_with_new)
            # Compare new_text (last row) against all existing
            new_vec = tfidf_matrix[-1]
            existing_matrix = tfidf_matrix[:-1]
            sims = cosine_similarity(new_vec, existing_matrix).flatten()
            best_idx = int(np.argmax(sims))
            best_score = float(sims[best_idx])

            if best_score >= self.SIMILARITY_THRESHOLD:
                match = existing[best_idx]
                match["similarity_score"] = round(best_score, 3)
                logger.info(
                    "Duplicate detected: similarity=%.3f for claim_id=%s",
                    best_score,
                    match.get("id"),
                )
                return match
        except Exception as exc:
            logger.warning("Similarity computation failed: %s", exc)

        return None

    def cluster_recent_claims(self, n_clusters: int = 8) -> list[dict]:
        """
        Groups all recent claims into clusters using K-Means.
        Useful for dashboard overview of dominant narratives.
        """
        try:
            from sklearn.feature_extraction.text import TfidfVectorizer
            from sklearn.cluster import KMeans
            import numpy as np
        except ImportError:
            return []

        existing = self._get_recent_claims()
        if len(existing) < n_clusters:
            return []

        texts = [
            (r.get("extracted_claim") or r.get("raw_text") or "")
            for r in existing
        ]

        try:
            vec = TfidfVectorizer(max_features=2000, ngram_range=(1, 2))
            X = vec.fit_transform(texts)
            k = min(n_clusters, len(existing))
            km = KMeans(n_clusters=k, random_state=42, n_init=5)
            labels = km.fit_predict(X)

            clusters: dict[int, list] = {}
            for idx, label in enumerate(labels):
                clusters.setdefault(int(label), []).append(existing[idx])

            result = []
            for cluster_id, members in clusters.items():
                avg_risk = sum(m.get("risk_score") or 0 for m in members) / len(members)
                # Representative claim = highest risk in cluster
                rep = max(members, key=lambda m: m.get("risk_score") or 0)
                result.append({
                    "cluster_id": cluster_id,
                    "size": len(members),
                    "avg_risk_score": round(avg_risk, 2),
                    "representative_claim": rep.get("extracted_claim") or rep.get("raw_text"),
                    "representative_id": rep.get("id"),
                    "verdicts": {
                        v: sum(1 for m in members if m.get("llm_verdict") == v)
                        for v in ["TRUE", "FALSE", "MISLEADING", "UNVERIFIED"]
                    },
                })
            result.sort(key=lambda x: x["avg_risk_score"], reverse=True)
            return result
        except Exception as exc:
            logger.error("cluster_recent_claims failed: %s", exc)
            return []


# ============================================================================
# VIRALITY ESTIMATOR
# ============================================================================

class ViralityEstimator:
    """
    Estimates a virality score (0.0–10.0) for a claim based on:
      - Explicit share count
      - Platform virality coefficient
      - Language reach (Hindi/regional = larger India audience)
      - Time of day (peak hours multiply virality)
      - Content type (image/video spread faster)
      - Historical virality of same category
    """

    PLATFORM_BASE = {
        "whatsapp": 8.5,    # WhatsApp has massive organic spread in India
        "twitter": 6.0,
        "instagram": 5.5,
        "facebook": 6.5,
        "youtube": 5.0,
        "telegram": 4.5,
        "unknown": 4.0,
    }

    LANGUAGE_MULTIPLIER = {
        "hi-IN": 1.4,   # Hindi = largest reach
        "en-IN": 1.0,
        "bn-IN": 1.2,   # Bengali
        "ta-IN": 1.2,   # Tamil
        "te-IN": 1.2,   # Telugu
        "mr-IN": 1.2,   # Marathi
        "gu-IN": 1.1,
        "kn-IN": 1.1,
        "ml-IN": 1.1,
        "pa-IN": 1.1,
        "ur-IN": 1.3,
    }

    CONTENT_TYPE_MULTIPLIER = {
        "image": 1.3,
        "voice": 1.2,
        "video": 1.4,
        "text": 1.0,
        "url": 1.0,
    }

    # India peak misinformation hours (IST offset UTC+5:30)
    PEAK_HOURS_IST = {7, 8, 9, 12, 13, 18, 19, 20, 21, 22}

    def estimate(
        self,
        shares: int,
        platform: str,
        language: str,
        source_type: str,
        category: str,
        created_at: Optional[datetime] = None,
    ) -> dict:
        platform_base = self.PLATFORM_BASE.get(platform.lower(), 4.0)
        lang_mult = self.LANGUAGE_MULTIPLIER.get(language, 1.0)
        content_mult = self.CONTENT_TYPE_MULTIPLIER.get(source_type.lower(), 1.0)

        # Share-based signal (log scale to avoid extreme dominance)
        share_signal = math.log10(shares + 1) * 1.5 if shares > 0 else 0.0

        # Time-of-day boost
        time_mult = 1.0
        if created_at:
            # Convert UTC to IST
            ist_hour = (created_at.hour + 5) % 24
            if ist_hour in self.PEAK_HOURS_IST:
                time_mult = 1.25

        # Category danger multiplier (dangerous categories spread faster)
        category_mult = {
            "COMMUNAL": 1.5,
            "HEALTH_FAKE": 1.4,
            "SCAM": 1.3,
            "POLITICAL_FAKE": 1.3,
            "FINANCIAL_FAKE": 1.2,
            "TRUE": 0.5,
            "UNKNOWN": 1.0,
        }.get(category.upper(), 1.0)

        raw = (platform_base + share_signal) * lang_mult * content_mult * time_mult * category_mult
        score = round(min(raw / 15 * 10, 10.0), 2)

        return {
            "virality_score": score,
            "virality_level": "VIRAL" if score >= 7 else "HIGH" if score >= 5 else "MODERATE" if score >= 3 else "LOW",
            "breakdown": {
                "platform_base": platform_base,
                "share_signal": round(share_signal, 2),
                "lang_multiplier": lang_mult,
                "content_multiplier": content_mult,
                "time_multiplier": time_mult,
                "category_multiplier": category_mult,
                "raw_score": round(raw, 2),
            },
            "peak_hour_detected": time_mult > 1.0,
            "estimated_reach": _estimate_reach(score, platform, shares),
        }


def _estimate_reach(virality_score: float, platform: str, shares: int) -> str:
    """Rough human-readable reach estimate for operators."""
    base = {
        "whatsapp": 250,   # avg contacts per forward chain
        "twitter": 500,
        "instagram": 300,
        "facebook": 200,
        "telegram": 400,
        "unknown": 150,
    }.get(platform, 150)

    if shares == 0:
        shares = 1

    estimated = shares * base * (virality_score / 5.0)
    if estimated > 10_000_000:
        return f"~{estimated / 1_000_000:.1f}Cr people"
    elif estimated > 100_000:
        return f"~{estimated / 100_000:.1f}L people"
    elif estimated > 1000:
        return f"~{estimated / 1000:.0f}K people"
    else:
        return f"~{int(estimated)} people"


# ============================================================================
# SOCIAL SIGNAL SCORER
# ============================================================================

class SocialSignalScorer:
    """
    Aggregates signals from multiple platforms into a unified
    social threat score and actionability recommendation.

    Inputs (all optional, default to 0/unknown):
      - whatsapp_forwards
      - twitter_retweets, twitter_likes, twitter_replies
      - instagram_shares, instagram_views
      - facebook_shares, facebook_reactions
      - youtube_views, youtube_comments
      - telegram_forwards
      - reddit_upvotes, reddit_comments

    Output:
      social_threat_score (0–10)
      dominant_platform
      cross_platform_spread (bool)
      recommended_action
      signal_breakdown
    """

    def score(
        self,
        whatsapp_forwards: int = 0,
        twitter_retweets: int = 0,
        twitter_likes: int = 0,
        instagram_shares: int = 0,
        instagram_views: int = 0,
        facebook_shares: int = 0,
        youtube_views: int = 0,
        telegram_forwards: int = 0,
        reddit_upvotes: int = 0,
    ) -> dict:

        # Weighted signals — WhatsApp most dangerous in India context
        platform_scores = {
            "whatsapp":  _normalize(whatsapp_forwards, 5000) * 10 * 1.5,
            "twitter":   (_normalize(twitter_retweets, 10000) + _normalize(twitter_likes, 50000)) / 2 * 10 * 1.2,
            "instagram": (_normalize(instagram_shares, 5000) + _normalize(instagram_views, 500000)) / 2 * 10 * 1.1,
            "facebook":  _normalize(facebook_shares, 8000) * 10 * 1.15,
            "youtube":   _normalize(youtube_views, 500000) * 10 * 0.9,
            "telegram":  _normalize(telegram_forwards, 3000) * 10 * 1.2,
            "reddit":    _normalize(reddit_upvotes, 5000) * 10 * 0.7,
        }

        active_platforms = {k: v for k, v in platform_scores.items() if v > 0}
        cross_platform = len(active_platforms) >= 3

        if not active_platforms:
            raw_score = 0.0
        else:
            # Weighted average of platform scores
            total_weight = sum(active_platforms.values())
            # Cross-platform bonus: content spreading across platforms is more dangerous
            cross_bonus = 1.5 if cross_platform else 1.0
            raw_score = min((total_weight / len(active_platforms)) * cross_bonus, 10.0)

        social_threat_score = round(raw_score, 2)
        dominant = max(platform_scores, key=lambda k: platform_scores[k]) if platform_scores else "unknown"

        # Recommended action
        if social_threat_score >= 8.0:
            action = "ESCALATE_IMMEDIATELY — Contact platform trust & safety teams"
        elif social_threat_score >= 6.0:
            action = "FLAG_FOR_REVIEW — Prepare corrective content for all platforms"
        elif social_threat_score >= 4.0:
            action = "MONITOR — Post correction on top 2 platforms"
        elif social_threat_score >= 2.0:
            action = "LOW_PRIORITY — Add to knowledge base"
        else:
            action = "MINIMAL_SIGNAL — Standard processing"

        return {
            "social_threat_score": social_threat_score,
            "dominant_platform": dominant,
            "cross_platform_spread": cross_platform,
            "active_platforms": list(active_platforms.keys()),
            "recommended_action": action,
            "signal_breakdown": {k: round(v, 2) for k, v in platform_scores.items()},
        }


def _normalize(value: int, ceiling: int) -> float:
    """Normalize a raw count to 0–1 with soft ceiling."""
    if value <= 0:
        return 0.0
    return min(math.log10(value + 1) / math.log10(ceiling + 1), 1.0)


# ============================================================================
# Convenience singletons
# ============================================================================
trend_detector = TrendDetector()
duplicate_clusterer = DuplicateClusterer()
virality_estimator = ViralityEstimator()
social_signal_scorer = SocialSignalScorer()