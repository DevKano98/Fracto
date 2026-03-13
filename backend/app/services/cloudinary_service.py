import logging

import cloudinary
import cloudinary.uploader

from app.config import settings

logger = logging.getLogger(__name__)

cloudinary.config(
    cloud_name=settings.CLOUDINARY_CLOUD_NAME,
    api_key=settings.CLOUDINARY_API_KEY,
    api_secret=settings.CLOUDINARY_API_SECRET,
)


async def upload_blog_image(image_bytes: bytes, slug: str) -> dict:
    try:
        result = cloudinary.uploader.upload(
            image_bytes,
            public_id=f"fracta/{slug}",
            overwrite=True,
            resource_type="image",
            format="jpg",
            transformation=[{"width": 1200, "height": 630, "crop": "fill"}],
        )
        return {
            "url": result["secure_url"],
            "public_id": result["public_id"],
        }
    except Exception as exc:
        logger.error("Cloudinary upload error for slug=%s: %s", slug, exc)
        return {"url": "", "public_id": ""}


def delete_blog_image(public_id: str) -> None:
    try:
        cloudinary.uploader.destroy(public_id)
    except Exception as exc:
        logger.error("Cloudinary delete error for public_id=%s: %s", public_id, exc)