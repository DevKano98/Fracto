# backend/app/services/auth_service.py

from datetime import datetime, timedelta
from jose import JWTError, jwt
from passlib.context import CryptContext
import hashlib, secrets, os
from app.config import settings
from app.database.supabase_client import supabase

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

ACCESS_TOKEN_EXPIRE_MINUTES  = 30
REFRESH_TOKEN_EXPIRE_DAYS    = 7
ALGORITHM                    = "HS256"

# ── Password ───────────────────────────────────────────────────
def hash_password(password: str) -> str:
    return pwd_context.hash(password)

def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)

# ── Access token — short lived (30 min) ───────────────────────
def create_access_token(user_id: str, role: str) -> str:
    payload = {
        "sub":  user_id,
        "role": role,
        "exp":  datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES),
        "type": "access"
    }
    return jwt.encode(payload, settings.APP_SECRET_KEY, algorithm=ALGORITHM)

# ── Refresh token — long lived (7 days) ───────────────────────
def create_refresh_token(user_id: str) -> str:
    raw_token = secrets.token_hex(32)
    token_hash = hashlib.sha256(raw_token.encode()).hexdigest()

    supabase.table("refresh_tokens").insert({
        "user_id":    user_id,
        "token_hash": token_hash,
        "expires_at": (datetime.utcnow() + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)).isoformat()
    }).execute()

    return raw_token   # return raw — store hash only in DB

# ── Verify access token ────────────────────────────────────────
def verify_access_token(token: str) -> dict:
    try:
        payload = jwt.decode(token, settings.APP_SECRET_KEY, algorithms=[ALGORITHM])
        if payload.get("type") != "access":
            raise ValueError("Wrong token type")
        return payload
    except JWTError:
        return None

# ── Refresh access token ───────────────────────────────────────
def refresh_access_token(raw_refresh_token: str) -> dict | None:
    token_hash = hashlib.sha256(raw_refresh_token.encode()).hexdigest()

    result = supabase.table("refresh_tokens") \
        .select("*, users(id, role, is_active)") \
        .eq("token_hash", token_hash) \
        .gt("expires_at", datetime.utcnow().isoformat()) \
        .single() \
        .execute()

    if not result.data:
        return None

    user = result.data["users"]
    if not user["is_active"]:
        return None

    new_access_token = create_access_token(user["id"], user["role"])
    return {
        "access_token": new_access_token,
        "token_type":   "bearer"
    }

# ── Revoke refresh token (logout) ─────────────────────────────
def revoke_refresh_token(raw_refresh_token: str) -> None:
    token_hash = hashlib.sha256(raw_refresh_token.encode()).hexdigest()
    supabase.table("refresh_tokens") \
        .delete() \
        .eq("token_hash", token_hash) \
        .execute()