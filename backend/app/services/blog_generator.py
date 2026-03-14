import asyncio
import logging
import os
import re
from typing import Optional

import httpx
import replicate

from app.config import settings
from app.database.queries import insert_blog_post
from app.services.cloudinary_service import upload_blog_image
from app.services.gemini_verify_service import generate_blog_content

logger = logging.getLogger(__name__)

if settings.REPLICATE_API_TOKEN:
    os.environ["REPLICATE_API_TOKEN"] = settings.REPLICATE_API_TOKEN

# Replicate: google/imagen-4 (prompt, aspect_ratio, safety_filter_level, output_format)
# Do not use SDXL params: guidance_scale, num_inference_steps, negative_prompt
IMAGE_MODEL = "google/imagen-4"
MAX_IMAGE_DOWNLOAD = 10 * 1024 * 1024  # 10MB


def _safe_slug(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower())
    slug = slug.strip("-")
    return slug[:80]


async def _download_image(url: str) -> bytes:
    try:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.get(url)

            resp.raise_for_status()

            if len(resp.content) > MAX_IMAGE_DOWNLOAD:
                logger.warning("Image too large from replicate")
                return b""

            return resp.content

    except Exception as exc:
        logger.error("Image download error: %s", exc)
        return b""


async def _generate_image(prompt: str) -> bytes:
    """Run blocking replicate.run in executor to avoid blocking event loop."""
    loop = asyncio.get_event_loop()
    retries = 2

    for attempt in range(retries):
        try:
            output = await asyncio.wait_for(
                loop.run_in_executor(
                    None,
                    lambda _p=prompt: replicate.run(
                        IMAGE_MODEL,
                        input={
                            "prompt": _p,
                            "aspect_ratio": "16:9",
                            "safety_filter_level": "block_only_high",
                            "output_format": "jpg",
                        },
                    ),
                ),
                timeout=120,
            )

            image_url = None

            if isinstance(output, list) and output:
                image_url = output[0]

            elif isinstance(output, str):
                image_url = output

            elif isinstance(output, dict):
                image_url = output.get("url")

            if not image_url:
                return b""

            return await _download_image(image_url)

        except asyncio.TimeoutError:
            logger.warning("Replicate image gen timed out")
        except Exception as exc:
            logger.error("Replicate generation error: %s", exc)

        if attempt < retries - 1:
            await asyncio.sleep(2)

    return b""


async def auto_generate_blog(claim_data: dict) -> Optional[dict]:

    risk_score = claim_data.get("risk_score", 0)
    verdict = claim_data.get("llm_verdict", "UNVERIFIED")

    if risk_score < settings.RISK_BLOG_THRESHOLD:
        logger.info(
            "Skipping blog generation: risk_score %.2f below threshold",
            risk_score,
        )
        return None

    if verdict == "TRUE":
        logger.info("Skipping blog generation: claim verified TRUE")
        return None

    try:

        blog_content = await generate_blog_content(claim_data)

        if not blog_content:
            logger.warning("Blog content generation returned empty")
            return None

        title = blog_content.get("title", "")
        summary = blog_content.get("summary", "")
        content = blog_content.get("content", "")
        tags = blog_content.get("tags", [])

        slug = blog_content.get("slug") or _safe_slug(
            claim_data.get("extracted_claim", "fact-check")
        )

        image_prompt = blog_content.get(
            "image_prompt",
            "Indian fact-check journalism illustration newsroom style",
        )

        image_bytes = await _generate_image(image_prompt)

        cloudinary_result = {"url": "", "public_id": ""}

        if image_bytes:

            try:
                cloudinary_result = await upload_blog_image(
                    image_bytes,
                    slug,
                )
            except Exception as exc:
                logger.error("Cloudinary upload error: %s", exc)

        blog_row = {
            "claim_id": claim_data.get("id"),
            "title": title,
            "slug": slug,
            "summary": summary,
            "content": content,
            "cover_image": cloudinary_result.get("url", ""),
            "cloudinary_public_id": cloudinary_result.get("public_id", ""),
            "verdict": verdict,
            "risk_score": risk_score,
            "sources": claim_data.get("sources", []),
            "tags": tags,
            "category": claim_data.get("ml_category", "UNKNOWN"),
            "published": True,
            "auto_generated": True,
        }

        inserted = insert_blog_post(blog_row)

        logger.info("Blog generated successfully: %s", slug)

        return inserted

    except Exception as exc:

        logger.error("auto_generate_blog failed: %s", exc)

        return None