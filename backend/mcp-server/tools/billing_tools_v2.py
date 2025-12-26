"""
Billing Tools V2 - Transaction 保護

解決的問題（來自 PRD-v2.5）：
- billing_approve_waive 先更新付款狀態，再更新申請狀態
- Timeout 造成付款已免收但申請仍為 pending

解法：使用 PostgreSQL Function 封裝多表操作
"""

from typing import Dict, Any
import logging

logger = logging.getLogger(__name__)

# 依賴注入
postgrest_rpc = None


def set_postgrest_rpc(func):
    """設置 postgrest_rpc 函數"""
    global postgrest_rpc
    postgrest_rpc = func


async def billing_approve_waive_v2(
    request_id: int,
    approved_by: str
) -> Dict[str, Any]:
    """
    核准免收申請 V2（使用 Transaction 保護）

    使用 PostgreSQL Function 確保：
    1. 更新 payments.payment_status = 'waived'
    2. 更新 waive_requests.status = 'approved'

    兩個操作在同一 Transaction 內，要麼全成功、要麼全失敗
    """
    if not approved_by or not approved_by.strip():
        return {
            "success": False,
            "error": "必須提供核准人",
            "code": "APPROVER_REQUIRED"
        }

    try:
        result = await postgrest_rpc("approve_waive_request", {
            "p_request_id": request_id,
            "p_approved_by": approved_by.strip()
        })
        return result

    except Exception as e:
        logger.error(f"核准免收失敗: {e}")
        return {"success": False, "error": str(e)}


async def billing_reject_waive_v2(
    request_id: int,
    rejected_by: str,
    reject_reason: str
) -> Dict[str, Any]:
    """
    駁回免收申請 V2（使用 Transaction 保護）
    """
    if not rejected_by or not rejected_by.strip():
        return {
            "success": False,
            "error": "必須提供駁回人",
            "code": "REJECTOR_REQUIRED"
        }

    if not reject_reason or not reject_reason.strip():
        return {
            "success": False,
            "error": "必須提供駁回原因",
            "code": "REASON_REQUIRED"
        }

    try:
        result = await postgrest_rpc("reject_waive_request", {
            "p_request_id": request_id,
            "p_rejected_by": rejected_by.strip(),
            "p_reject_reason": reject_reason.strip()
        })
        return result

    except Exception as e:
        logger.error(f"駁回免收失敗: {e}")
        return {"success": False, "error": str(e)}
