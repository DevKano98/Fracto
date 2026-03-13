# backend/app/routes/auth_routes.py

from fastapi import APIRouter, HTTPException, Request, Depends
from pydantic import BaseModel, EmailStr
from app.services.auth_service import (
    hash_password, verify_password,
    create_access_token, create_refresh_token,
    refresh_access_token, revoke_refresh_token
)
from app.middleware.auth_middleware import require_admin, require_operator, get_current_user
from app.database.supabase_client import supabase
from datetime import datetime

router = APIRouter(prefix="/auth", tags=["auth"])

# ── Request models ─────────────────────────────────────────────
class RegisterRequest(BaseModel):
    name:     str
    email:    str
    password: str
    city:     str = ""

class LoginRequest(BaseModel):
    email:    str
    password: str

class RefreshRequest(BaseModel):
    refresh_token: str

class CreateOperatorRequest(BaseModel):
    name:     str
    email:    str
    password: str

# ── Register (mobile app users) ───────────────────────────────
@router.post("/register")
async def register(body: RegisterRequest):
    # Check email already exists
    existing = supabase.table("users") \
        .select("id") \
        .eq("email", body.email) \
        .execute()

    if existing.data:
        raise HTTPException(status_code=400, detail="Email already registered")

    user = supabase.table("users").insert({
        "name":          body.name,
        "email":         body.email,
        "password_hash": hash_password(body.password),
        "city":          body.city,
        "role":          "user"
    }).execute().data[0]

    access_token  = create_access_token(user["id"], user["role"])
    refresh_token = create_refresh_token(user["id"])

    return {
        "access_token":  access_token,
        "refresh_token": refresh_token,
        "token_type":    "bearer",
        "user": {
            "id":   user["id"],
            "name": user["name"],
            "role": user["role"]
        }
    }


# ── Login ──────────────────────────────────────────────────────
@router.post("/login")
async def login(body: LoginRequest, request: Request):
    result = supabase.table("users") \
        .select("*") \
        .eq("email", body.email) \
        .single() \
        .execute()

    user = result.data
    if not user or not verify_password(body.password, user["password_hash"]):
        raise HTTPException(status_code=401, detail="Invalid email or password")

    if not user["is_active"]:
        raise HTTPException(status_code=403, detail="Account deactivated")

    # Update last login
    supabase.table("users") \
        .update({"last_login": datetime.utcnow().isoformat()}) \
        .eq("id", user["id"]) \
        .execute()

    access_token  = create_access_token(user["id"], user["role"])
    refresh_token = create_refresh_token(user["id"])

    return {
        "access_token":  access_token,
        "refresh_token": refresh_token,
        "token_type":    "bearer",
        "user": {
            "id":   user["id"],
            "name": user["name"],
            "role": user["role"],
            "city": user["city"]
        }
    }


# ── Refresh ────────────────────────────────────────────────────
@router.post("/refresh")
async def refresh(body: RefreshRequest):
    result = refresh_access_token(body.refresh_token)
    if not result:
        raise HTTPException(status_code=401, detail="Invalid or expired refresh token")
    return result


# ── Logout ─────────────────────────────────────────────────────
@router.post("/logout")
async def logout(body: RefreshRequest):
    revoke_refresh_token(body.refresh_token)
    return {"message": "Logged out successfully"}


# ── Me — get current user profile ─────────────────────────────
@router.get("/me")
async def me(user: dict = Depends(get_current_user)):
    return user


# ── Admin: create operator account ────────────────────────────
@router.post("/admin/create-operator")
async def create_operator(
    body: CreateOperatorRequest,
    admin: dict = Depends(require_admin)
):
    existing = supabase.table("users") \
        .select("id").eq("email", body.email).execute()

    if existing.data:
        raise HTTPException(status_code=400, detail="Email already exists")

    operator = supabase.table("users").insert({
        "name":          body.name,
        "email":         body.email,
        "password_hash": hash_password(body.password),
        "role":          "operator",
        "created_by":    admin["id"]
    }).execute().data[0]

    return {
        "message":  "Operator created successfully",
        "operator": {"id": operator["id"], "name": operator["name"], "email": body.email}
    }


# ── Admin: list all operators ──────────────────────────────────
@router.get("/admin/operators")
async def list_operators(admin: dict = Depends(require_admin)):
    result = supabase.table("users") \
        .select("id, name, email, role, is_active, last_login, created_at") \
        .in_("role", ["operator", "super_admin"]) \
        .order("created_at", desc=False) \
        .execute()
    return result.data


# ── Admin: deactivate operator ─────────────────────────────────
@router.patch("/admin/operators/{user_id}/deactivate")
async def deactivate_operator(
    user_id: str,
    admin: dict = Depends(require_admin)
):
    if user_id == admin["id"]:
        raise HTTPException(status_code=400, detail="Cannot deactivate yourself")

    supabase.table("users") \
        .update({"is_active": False}) \
        .eq("id", user_id) \
        .execute()

    # Revoke all their refresh tokens immediately
    supabase.table("refresh_tokens") \
        .delete().eq("user_id", user_id).execute()

    return {"message": "Operator deactivated"}


# ── Admin: operator activity log ──────────────────────────────
@router.get("/admin/operator-log")
async def operator_log(admin: dict = Depends(require_admin)):
    result = supabase.table("operator_log") \
        .select("*, users(name, email)") \
        .order("created_at", desc=True) \
        .limit(100) \
        .execute()
    return result.data