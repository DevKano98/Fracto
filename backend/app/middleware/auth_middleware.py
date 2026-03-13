# backend/app/middleware/auth_middleware.py

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from app.services.auth_service import verify_access_token
from app.database.supabase_client import supabase
from app.database.queries import insert_operator_log

bearer_scheme = HTTPBearer()

def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme)
) -> dict:
    token = credentials.credentials
    payload = verify_access_token(token)

    if not payload:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token"
        )

    # Fetch fresh user from DB — catches deactivated accounts mid-session
    result = supabase.table("users") \
        .select("id, name, role, is_active") \
        .eq("id", payload["sub"]) \
        .single() \
        .execute()

    user = result.data
    if not user or not user["is_active"]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Account deactivated"
        )

    return user


# ── Role guards — use as FastAPI dependencies ──────────────────

def require_user(user: dict = Depends(get_current_user)) -> dict:
    """Any logged-in user."""
    return user


def require_operator(user: dict = Depends(get_current_user)) -> dict:
    """Operators and super admins."""
    if user["role"] not in ("operator", "super_admin"):
        raise HTTPException(status_code=403, detail="Operator access required")
    return user


def require_admin(user: dict = Depends(get_current_user)) -> dict:
    """Super admin only."""
    if user["role"] != "super_admin":
        raise HTTPException(status_code=403, detail="Admin access required")
    return user


# ── Operator activity logger ───────────────────────────────────
def log_operator_action(
    operator_id: str,
    action: str,
    target_type: str = None,
    target_id: str = None,
    detail: str = None,
    ip: str = None
):
    insert_operator_log(
        operator_id=operator_id,
        action=action,
        target_type=target_type,
        target_id=target_id,
        detail=detail,
        ip=ip
    )