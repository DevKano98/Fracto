import logging

from fastapi import APIRouter, HTTPException, Depends

from app.database.queries import get_claim_by_id, insert_audit_log, update_claim_status
from app.middleware.auth_middleware import require_operator, log_operator_action
from app.models.claim_model import ActionInput

logger = logging.getLogger(__name__)
router = APIRouter()

VALID_ACTIONS = {"APPROVED", "REJECTED", "OVERRIDDEN"}


@router.post("/{claim_id}")
async def action_claim(
    claim_id: str, 
    body: ActionInput,
    operator: dict = Depends(require_operator)
):
    action = body.action.upper()
    if action not in VALID_ACTIONS:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid action '{action}'. Must be one of: {', '.join(VALID_ACTIONS)}",
        )

    claim = get_claim_by_id(claim_id)
    if not claim:
        raise HTTPException(status_code=404, detail="Claim not found")

    update_claim_status(claim_id, action, operator["id"], body.operator_note)
    insert_audit_log(claim_id, action, operator["id"], body.operator_note)
    log_operator_action(operator["id"], f"CLAIM_{action}", "claim", claim_id, body.operator_note)

    updated = get_claim_by_id(claim_id)
    return {
        "message": f"Claim {claim_id} status updated to {action}",
        "claim": updated,
    }