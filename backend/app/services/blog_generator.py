import logging
import os

import replicate
import requests

from app.config import settings
from app.database.queries import insert_blog_post
from app.services.cloudinary_service import upload_blog_image
from app.services.gemini_verify_service import generate_blog_content

logger = logging.getLogger(__name__)

os.environ["REPLICATE_API_TOKEN"] = settings.REPLICATE_API_TOKEN

SDXL_MODEL = "stability-ai/sdxl:39ed52f2319f9b4e0436ea9de02823f89de39c44"


async def auto_generate_blog(claim_data: dict) -> dict | None:
    risk_score = claim_data.get("risk_score", 0)
    verdict = claim_data.get("llm_verdict", "UNVERIFIED")

    if risk_score < settings.RISK_BLOG_THRESHOLD:
        logger.info("Skipping blog generation: risk_score=%.1f below threshold", risk_score)
        return None

    if verdict == "TRUE":
        logger.info("Skipping blog generation: verdict is TRUE")
        return None

    try:
        # Step 1: Generate blog content via Gemini
        blog_content = await generate_blog_content(claim_data)
        slug = blog_content.get("slug", "")
        image_prompt = blog_content.get("image_prompt", "India fact-check journalism illustration")

        # Step 2: Generate image via Replicate SDXL
        image_bytes = b""
        try:
            output = replicate.run(
                SDXL_MODEL,
                input={
                    "prompt": image_prompt,
                    "negative_prompt": "text, words, letters, watermark, logo",
                    "width": 1200,
                    "height": 630,
                    "num_outputs": 1,
                },
            )
            image_url_from_replicate = output[0] if output else None

            # Step 3: Download image bytes
            if image_url_from_replicate:
                resp = requests.get(image_url_from_replicate, timeout=30)
                resp.raise_for_status()
                image_bytes = resp.content
        except Exception as exc:
            logger.error("Replicate image generation error: %s", exc)

        # Step 4: Upload to Cloudinary
        cloudinary_result = {"url": "", "public_id": ""}
        if image_bytes:
            cloudinary_result = await upload_blog_image(image_bytes, slug)

        # Step 5: Insert blog post to Supabase
        blog_row = {
            "claim_id": claim_data.get("id"),
            "title": blog_content.get("title", ""),
            "slug": slug,
            "summary": blog_content.get("summary", ""),
            "content": blog_content.get("content", ""),
            "cover_image": cloudinary_result.get("url", ""),
            "cloudinary_public_id": cloudinary_result.get("public_id", ""),
            "verdict": verdict,
            "risk_score": risk_score,
            "sources": claim_data.get("sources", []),
            "tags": blog_content.get("tags", []),
            "category": claim_data.get("ml_category", "UNKNOWN"),
            "published": True,
            "auto_generated": True,
        }
        inserted = insert_blog_post(blog_row)
        logger.info("Blog post created: slug=%s", slug)
        return inserted

    except Exception as exc:
        logger.error("auto_generate_blog failed: %s", exc)
        return None