import logging

import cloudinary
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address

from app.config import settings
from app.database.supabase_client import supabase
from app.ml.classifier import is_loaded as ml_is_loaded
from app.services.groq_service import health_check as groq_health_check, get_available_models
from app.routes.action_routes import router as action_router
from app.routes.blog_routes import router as blog_router
from app.routes.feed_routes import router as feed_router
from app.routes.verify_routes import router as verify_router
from app.routes.trends_routes import router as trends_router
from app.routes.auth_routes import router as auth_router
from app.routes.admin_routes import router as admin_router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
)
logger = logging.getLogger(__name__)

limiter = Limiter(key_func=get_remote_address)

app = FastAPI(
    title="Fracta API",
    description="Real-time AI misinformation defense platform for India",
    version="2.0.0",
)

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(verify_router, prefix="/verify", tags=["Verification"])
app.include_router(feed_router, prefix="/feed", tags=["Feed"])
app.include_router(action_router, prefix="/action", tags=["Actions"])
app.include_router(blog_router, prefix="/blog", tags=["Blog"])
app.include_router(trends_router, prefix="/trends", tags=["Trends"])
app.include_router(auth_router)
app.include_router(admin_router)

_service_status = {
    "supabase": False,
    "gemini_key_1": False,
    "gemini_key_2": False,
    "groq": False,
    "sarvam": False,
    "cloudinary": False,
    "upstash_redis": False,
    "replicate": False,
    "ml_model": False,
    "reddit": False,
    "youtube": False,
    "telegram": False,
    "newsapi": False,
    "google_cse": False,
}


@app.on_event("startup")
async def startup_event():
    logger.info("🚀 Starting Fracta API v2.0.0")

    try:
        cloudinary.config(
            cloud_name=settings.CLOUDINARY_CLOUD_NAME,
            api_key=settings.CLOUDINARY_API_KEY,
            api_secret=settings.CLOUDINARY_API_SECRET,
        )
        _service_status["cloudinary"] = True
        logger.info("✅ Cloudinary configured")
    except Exception as exc:
        logger.error("❌ Cloudinary config failed: %s", exc)

    try:
        supabase.table("claims").select("id").limit(1).execute()
        supabase.table("users").select("id").limit(1).execute()
        _service_status["supabase"] = True
        logger.info("✅ Supabase connected")
    except Exception as exc:
        logger.error("❌ Supabase connection failed: %s", exc)

    _service_status["ml_model"] = ml_is_loaded()
    if _service_status["ml_model"]:
        logger.info("✅ ML classifier loaded")
    else:
        logger.warning("⚠️  ML classifier not loaded — run ml/train_classifier.py")

    _service_status["gemini_key_1"] = bool(settings.GEMINI_KEY_1)
    _service_status["gemini_key_2"] = bool(settings.GEMINI_KEY_2)
    _service_status["sarvam"] = bool(settings.SARVAM_API_KEY)
    _service_status["replicate"] = bool(settings.REPLICATE_API_TOKEN)
    _service_status["upstash_redis"] = bool(settings.UPSTASH_REDIS_URL and settings.UPSTASH_REDIS_TOKEN)
    _service_status["newsapi"] = bool(settings.NEWS_API_KEY)
    _service_status["youtube"] = bool(getattr(settings, "YOUTUBE_API_KEY", ""))
    _service_status["reddit"] = bool(getattr(settings, "REDDIT_CLIENT_ID", "") and getattr(settings, "REDDIT_CLIENT_SECRET", ""))
    _service_status["telegram"] = bool(getattr(settings, "TELEGRAM_API_ID", "") and getattr(settings, "TELEGRAM_API_HASH", ""))
    _service_status["google_cse"] = bool(getattr(settings, "GOOGLE_CSE_KEY", "") and getattr(settings, "GOOGLE_CSE_CX", ""))

    # Groq health check
    groq_status = groq_health_check()
    _service_status["groq"] = groq_status.get("groq", False)
    if _service_status["groq"]:
        qwen_ok = groq_status.get("qwen_qwq_available", False)
        logger.info("✅ Groq connected — qwen-qwq-32b available: %s", qwen_ok)
    else:
        logger.warning("⚠️  Groq not available: %s", groq_status.get("reason", "unknown"))
        logger.warning("    Add GROQ_API_KEY (free at console.groq.com) for RAG pre-analysis")

    logger.info("Service status: %s", _service_status)
    logger.info("🟢 Fracta API v2.0.0 ready — RAG pipeline active")


@app.api_route("/health", methods=["GET", "HEAD"], tags=["Health"])
async def health_check():
    return {
        "status": "ok",
        "version": "2.0.0",
        "services": _service_status
    }