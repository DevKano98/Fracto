from dotenv import load_dotenv
load_dotenv()

import os


class Settings:
    # ── Core required ──────────────────────────────────────────────────────
    GEMINI_KEY_1: str = os.getenv("GEMINI_KEY_1", "")
    GEMINI_KEY_2: str = os.getenv("GEMINI_KEY_2", "")
    SARVAM_API_KEY: str = os.getenv("SARVAM_API_KEY", "")
    SUPABASE_URL: str = os.getenv("SUPABASE_URL", "")
    SUPABASE_ANON_KEY: str = os.getenv("SUPABASE_ANON_KEY", "")
    SUPABASE_STORAGE_BUCKET: str = os.getenv("SUPABASE_STORAGE_BUCKET", "fracta-media")
    CLOUDINARY_CLOUD_NAME: str = os.getenv("CLOUDINARY_CLOUD_NAME", "")
    CLOUDINARY_API_KEY: str = os.getenv("CLOUDINARY_API_KEY", "")
    CLOUDINARY_API_SECRET: str = os.getenv("CLOUDINARY_API_SECRET", "")
    NEWS_API_KEY: str = os.getenv("NEWS_API_KEY", "")
    REPLICATE_API_TOKEN: str = os.getenv("REPLICATE_API_TOKEN", "")
    UPSTASH_REDIS_URL: str = os.getenv("UPSTASH_REDIS_URL", "")
    UPSTASH_REDIS_TOKEN: str = os.getenv("UPSTASH_REDIS_TOKEN", "")
    RISK_BLOG_THRESHOLD: float = float(os.getenv("RISK_BLOG_THRESHOLD", "6.0"))
    RISK_ACTION_THRESHOLD: float = float(os.getenv("RISK_ACTION_THRESHOLD", "7.0"))
    CONFLICT_THRESHOLD: float = float(os.getenv("CONFLICT_THRESHOLD", "0.20"))

    @property
    def ocr_key(self):
        return self.GEMINI_KEY_1

    @property
    def verify_key(self):
        return self.GEMINI_KEY_2

    # ── Qwen backends — pick ONE (all free) ────────────────────────────────
    # Option A: Groq (RECOMMENDED — fastest, free 14400 req/day)
    #   Sign up: console.groq.com  |  Model used: qwen-qwq-32b
    GROQ_API_KEY: str = os.getenv("GROQ_API_KEY", "")

    # Option B: HuggingFace Inference API (free, slower)
    #   Sign up: huggingface.co/settings/tokens  |  Model: Qwen2.5-72B-Instruct
    HF_API_KEY: str = os.getenv("HF_API_KEY", "")

    # Option C: Together AI ($25 free credit on signup)
    #   Sign up: api.together.ai  |  Model: Qwen2.5-72B-Instruct-Turbo
    TOGETHER_API_KEY: str = os.getenv("TOGETHER_API_KEY", "")

    # Option D: Ollama local (completely free, offline, no key)
    #   Install: https://ollama.ai  |  Then: ollama pull qwen2.5:7b
    OLLAMA_BASE_URL: str = os.getenv("OLLAMA_BASE_URL", "")
    OLLAMA_MODEL: str = os.getenv("OLLAMA_MODEL", "qwen2.5:7b")

    # ── Free search enhancements ───────────────────────────────────────────
    # Google Custom Search: 100 free/day
    #   Get at: console.cloud.google.com → enable Custom Search API
    #   Create CX at: cse.google.com
    GOOGLE_CSE_KEY: str = os.getenv("GOOGLE_CSE_KEY", "")
    GOOGLE_CSE_CX: str = os.getenv("GOOGLE_CSE_CX", "")
    REDDIT_CLIENT_ID: str = os.getenv("REDDIT_CLIENT_ID", "")
    REDDIT_CLIENT_SECRET: str = os.getenv("REDDIT_CLIENT_SECRET", "")
    TELEGRAM_API_ID: str = os.getenv("TELEGRAM_API_ID", "")
    TELEGRAM_API_HASH: str = os.getenv("TELEGRAM_API_HASH", "")

    # SearXNG: self-hosted (free) or use public instance
    #   Self-host: docker run -d -p 8888:8080 searxng/searxng
    #   Public instances: https://searx.space (pick fastest)
    SEARXNG_BASE_URL: str = os.getenv("SEARXNG_BASE_URL", "https://searx.be")

    # ── Optional paid enhancements (skip if not available) ─────────────────
    PERPLEXITY_API_KEY: str = os.getenv("PERPLEXITY_API_KEY", "")
    YOUTUBE_API_KEY: str = os.getenv("YOUTUBE_API_KEY", "")

    def __init__(self):
        required = [
            "GEMINI_KEY_1", "GEMINI_KEY_2", "SARVAM_API_KEY",
            "SUPABASE_URL", "SUPABASE_ANON_KEY",
            "CLOUDINARY_CLOUD_NAME", "CLOUDINARY_API_KEY", "CLOUDINARY_API_SECRET",
            "REPLICATE_API_TOKEN", "UPSTASH_REDIS_URL", "UPSTASH_REDIS_TOKEN",
            "GROQ_API_KEY"
        ]
        missing = [k for k in required if not getattr(self, k)]
        if missing:
            raise RuntimeError(
                f"Missing required environment variables: {', '.join(missing)}"
            )

        # Warn if no Qwen backend configured
        qwen_backends = [self.GROQ_API_KEY, self.HF_API_KEY, self.TOGETHER_API_KEY, self.OLLAMA_BASE_URL]
        if not any(qwen_backends):
            import warnings
            warnings.warn(
                "No Qwen backend configured. RAG will gather evidence but skip LLM pre-analysis. "
                "Add GROQ_API_KEY (free at console.groq.com) for best results.",
                UserWarning,
                stacklevel=2,
            )


settings = Settings()