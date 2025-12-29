"""
Hour Jungle CRM - Billing Domain Tools
繳費流程管理工具（符合 SSD v1.2 定義）

Commands:
- billing_record_payment: 記錄繳費（含 MVP 嚴格金額驗證）
- billing_undo_payment: 撤銷繳費
- billing_request_waive: 申請免收
- billing_approve_waive: 核准免收
- billing_reject_waive: 駁回免收
- billing_send_reminder: 發送催繳（透過 Brain 轉發到 LINE）
- billing_batch_remind: 批量催繳
"""

import logging
import os
import uuid
from datetime import datetime
from typing import Dict, Any, Optional

import httpx

logger = logging.getLogger(__name__)

POSTGREST_URL = os.getenv("POSTGREST_URL", "http://postgrest:3000")
BRAIN_API_URL = os.getenv("BRAIN_API_URL", "https://brain.yourspce.org")


async def postgrest_get(endpoint: str, params: dict = None) -> Any:
    """PostgREST GET 請求"""
    url = f"{POSTGREST_URL}/{endpoint}"
    async with httpx.AsyncClient() as client:
        response = await client.get(url, params=params, timeout=30.0)
        response.raise_for_status()
        return response.json()


async def postgrest_post(endpoint: str, data: dict) -> Any:
    """PostgREST POST 請求"""
    url = f"{POSTGREST_URL}/{endpoint}"
    headers = {
        "Content-Type": "application/json",
        "Prefer": "return=representation"
    }
    async with httpx.AsyncClient() as client:
        response = await client.post(url, json=data, headers=headers, timeout=30.0)
        response.raise_for_status()
        return response.json()


async def postgrest_patch(endpoint: str, params: dict, data: dict) -> Any:
    """PostgREST PATCH 請求"""
    url = f"{POSTGREST_URL}/{endpoint}"
    headers = {
        "Content-Type": "application/json",
        "Prefer": "return=representation"
    }
    async with httpx.AsyncClient() as client:
        response = await client.patch(url, params=params, json=data, headers=headers, timeout=30.0)
        response.raise_for_status()
        return response.json()


# ============================================================================
# Billing Commands
# ============================================================================

async def billing_record_payment(
    payment_id: int,
    payment_method: str,
    amount: float,
    payment_date: str = None,
    notes: str = None
) -> Dict[str, Any]:
    """
    記錄繳費（SSD: billing_record_payment）

    Args:
        payment_id: 付款ID
        payment_method: 付款方式 (cash/transfer/credit_card/line_pay)
        amount: 繳費金額（MVP 嚴格模式：必須與應繳金額一致）
        payment_date: 付款日期 (YYYY-MM-DD)，預設今天
        notes: 備註

    Returns:
        繳費結果
    """
    valid_methods = ["cash", "transfer", "credit_card", "line_pay"]
    if payment_method not in valid_methods:
        return {
            "success": False,
            "error": f"無效的付款方式，允許: {', '.join(valid_methods)}",
            "code": "INVALID_PARAMS"
        }

    # 1. 取得付款記錄
    try:
        payments = await postgrest_get("payments", {"id": f"eq.{payment_id}"})
        if not payments:
            return {"success": False, "error": "找不到付款記錄", "code": "NOT_FOUND"}

        payment = payments[0]
    except Exception as e:
        logger.error(f"billing_record_payment - 取得付款記錄失敗: {e}")
        raise

    # 2. 驗證狀態
    current_status = payment.get("payment_status")
    if current_status not in ["pending", "overdue"]:
        return {
            "success": False,
            "error": f"只有待繳或逾期款項可記錄繳費，目前狀態: {current_status}",
            "code": "INVALID_STATUS"
        }

    # 3. 驗證金額（MVP 嚴格模式）
    amount_due = float(payment.get("amount", 0))
    if abs(amount - amount_due) > 0.01:  # 允許 0.01 的浮點誤差
        return {
            "success": False,
            "error": f"金額不符：應繳 {amount_due}，實收 {amount}",
            "code": "AMOUNT_MISMATCH"
        }

    # 4. 更新付款記錄
    paid_at = payment_date or datetime.now().strftime("%Y-%m-%d")
    update_data = {
        "payment_status": "paid",
        "payment_method": payment_method,
        "paid_at": f"{paid_at}T00:00:00+08:00"
    }

    if notes:
        existing_notes = payment.get("notes") or ""
        update_data["notes"] = f"{existing_notes}\n{notes}".strip()

    try:
        result = await postgrest_patch(
            "payments",
            {"id": f"eq.{payment_id}"},
            update_data
        )

        if not result:
            return {"success": False, "error": "更新失敗"}

        updated_payment = result[0] if isinstance(result, list) else result

        # 5. 記錄審計日誌
        try:
            await postgrest_post("audit_logs", {
                "table_name": "payments",
                "record_id": payment_id,
                "action": "UPDATE",
                "old_data": {"payment_status": current_status},
                "new_data": {"payment_status": "paid", "payment_method": payment_method},
                "changed_fields": ["payment_status", "payment_method", "paid_at"]
            })
        except Exception as audit_err:
            logger.warning(f"審計日誌記錄失敗（不影響主流程）: {audit_err}")

        return {
            "success": True,
            "message": f"付款 #{payment_id} 已標記為已付款",
            "payment": updated_payment
        }

    except Exception as e:
        logger.error(f"billing_record_payment error: {e}")
        raise


async def billing_undo_payment(
    payment_id: int,
    reason: str
) -> Dict[str, Any]:
    """
    撤銷繳費（SSD: billing_undo_payment）

    Args:
        payment_id: 付款ID
        reason: 撤銷原因（必填）

    Returns:
        撤銷結果
    """
    if not reason or not reason.strip():
        return {
            "success": False,
            "error": "必須提供撤銷原因",
            "code": "INVALID_PARAMS"
        }

    # 1. 取得付款記錄
    try:
        payments = await postgrest_get("payments", {"id": f"eq.{payment_id}"})
        if not payments:
            return {"success": False, "error": "找不到付款記錄", "code": "NOT_FOUND"}

        payment = payments[0]
    except Exception as e:
        logger.error(f"billing_undo_payment - 取得付款記錄失敗: {e}")
        raise

    # 2. 驗證狀態
    if payment.get("payment_status") != "paid":
        return {
            "success": False,
            "error": f"只有已付款的記錄才能撤銷，目前狀態: {payment.get('payment_status')}",
            "code": "INVALID_STATUS"
        }

    # 3. 判斷撤銷後的狀態（根據 due_date）
    due_date = payment.get("due_date")
    today = datetime.now().date()
    due_date_obj = datetime.fromisoformat(str(due_date)).date() if due_date else today

    new_status = "overdue" if due_date_obj < today else "pending"

    # 4. 記錄原始資訊
    original_info = {
        "paid_at": payment.get("paid_at"),
        "payment_method": payment.get("payment_method"),
        "undone_at": datetime.now().isoformat(),
        "undo_reason": reason.strip()
    }

    # 5. 更新付款記錄
    existing_notes = payment.get("notes") or ""
    undo_note = f"\n[撤銷] {datetime.now().strftime('%Y-%m-%d %H:%M')} - 原付款方式: {payment.get('payment_method')}, 原因: {reason.strip()}"

    update_data = {
        "payment_status": new_status,
        "payment_method": None,
        "paid_at": None,
        "notes": (existing_notes + undo_note).strip()
    }

    try:
        result = await postgrest_patch(
            "payments",
            {"id": f"eq.{payment_id}"},
            update_data
        )

        if not result:
            return {"success": False, "error": "更新失敗"}

        updated_payment = result[0] if isinstance(result, list) else result

        # 記錄審計日誌
        try:
            await postgrest_post("audit_logs", {
                "table_name": "payments",
                "record_id": payment_id,
                "action": "UPDATE",
                "old_data": {"payment_status": "paid"},
                "new_data": {"payment_status": new_status, "undo_reason": reason},
                "changed_fields": ["payment_status", "payment_method", "paid_at"]
            })
        except Exception as audit_err:
            logger.warning(f"審計日誌記錄失敗: {audit_err}")

        return {
            "success": True,
            "message": f"付款 #{payment_id} 已撤銷，狀態改為 {new_status}",
            "payment": updated_payment,
            "original_info": original_info
        }

    except Exception as e:
        logger.error(f"billing_undo_payment error: {e}")
        raise


async def billing_request_waive(
    payment_id: int,
    reason: str,
    requested_by: str,
    idempotency_key: str = None
) -> Dict[str, Any]:
    """
    申請免收（SSD: billing_request_waive）

    Args:
        payment_id: 付款ID
        reason: 申請原因（必填）
        requested_by: 申請人
        idempotency_key: 冪等性 Key（防止重複提交）

    Returns:
        申請結果
    """
    if not reason or not reason.strip():
        return {
            "success": False,
            "error": "必須提供申請原因",
            "code": "INVALID_PARAMS"
        }

    # 生成冪等性 Key
    if not idempotency_key:
        idempotency_key = f"waive-{payment_id}-{datetime.now().strftime('%Y%m%d%H%M%S')}"

    # 1. 取得付款記錄
    try:
        payments = await postgrest_get("payments", {"id": f"eq.{payment_id}"})
        if not payments:
            return {"success": False, "error": "找不到付款記錄", "code": "NOT_FOUND"}

        payment = payments[0]
    except Exception as e:
        logger.error(f"billing_request_waive - 取得付款記錄失敗: {e}")
        raise

    # 2. 驗證狀態
    if payment.get("payment_status") not in ["pending", "overdue"]:
        return {
            "success": False,
            "error": f"只有待繳或逾期款項可申請免收，目前狀態: {payment.get('payment_status')}",
            "code": "INVALID_STATUS"
        }

    # 3. 檢查是否已有待審核的申請
    existing = await postgrest_get("waive_requests", {
        "payment_id": f"eq.{payment_id}",
        "status": "eq.pending"
    })
    if existing:
        return {
            "success": False,
            "error": "此款項已有待審核的免收申請",
            "code": "DUPLICATE_REQUEST",
            "existing_request_id": existing[0]["id"]
        }

    # 4. 創建申請
    try:
        request_data = {
            "payment_id": payment_id,
            "requested_by": requested_by,
            "request_reason": reason.strip(),
            "request_amount": payment.get("amount"),
            "status": "pending",
            "idempotency_key": idempotency_key
        }

        result = await postgrest_post("waive_requests", request_data)
        waive_request = result[0] if isinstance(result, list) else result

        return {
            "success": True,
            "message": "免收申請已提交，等待主管核准",
            "request_id": waive_request["id"],
            "payment_id": payment_id,
            "amount": payment.get("amount")
        }

    except Exception as e:
        # 處理冪等性衝突
        if "duplicate key" in str(e).lower() or "unique" in str(e).lower():
            existing = await postgrest_get("waive_requests", {
                "idempotency_key": f"eq.{idempotency_key}"
            })
            if existing:
                return {
                    "success": True,
                    "message": "申請已存在（冪等性保護）",
                    "request_id": existing[0]["id"],
                    "idempotent": True
                }
        raise


async def billing_approve_waive(
    request_id: int,
    approved_by: str
) -> Dict[str, Any]:
    """
    核准免收（SSD: billing_approve_waive）

    Args:
        request_id: 免收申請ID
        approved_by: 核准人

    Returns:
        核准結果（可能返回 409 Conflict）
    """
    # 1. 取得申請
    try:
        requests = await postgrest_get("waive_requests", {"id": f"eq.{request_id}"})
        if not requests:
            return {"success": False, "error": "找不到免收申請", "code": "NOT_FOUND"}

        waive_request = requests[0]
    except Exception as e:
        logger.error(f"billing_approve_waive - 取得申請失敗: {e}")
        raise

    # 2. 驗證申請狀態
    if waive_request.get("status") != "pending":
        return {
            "success": False,
            "error": f"申請狀態為 {waive_request.get('status')}，無法核准",
            "code": "INVALID_STATUS"
        }

    # 3. 取得並驗證付款記錄狀態
    payment_id = waive_request.get("payment_id")
    payments = await postgrest_get("payments", {"id": f"eq.{payment_id}"})
    if not payments:
        return {"success": False, "error": "找不到關聯的付款記錄", "code": "NOT_FOUND"}

    payment = payments[0]

    # 4. 檢查付款狀態是否已變更（並發衝突）
    if payment.get("payment_status") not in ["pending", "overdue"]:
        # 自動駁回申請
        await postgrest_patch(
            "waive_requests",
            {"id": f"eq.{request_id}"},
            {"status": "rejected", "reject_reason": "款項狀態已變更"}
        )

        # 返回 409 Conflict（SSD v1.2 規定）
        return {
            "success": False,
            "error": "款項狀態已變更，無法核准",
            "code": "STATUS_CHANGED",
            "http_status": 409,
            "request_status": "rejected",
            "current_payment_status": payment.get("payment_status")
        }

    # 5. 執行核准（Transaction 模擬）
    now = datetime.now().isoformat()

    try:
        # 更新付款狀態為 waived
        await postgrest_patch(
            "payments",
            {"id": f"eq.{payment_id}"},
            {
                "payment_status": "waived",
                "notes": f"{payment.get('notes', '')}\n[免收] 核准人: {approved_by}, 原因: {waive_request.get('request_reason')}".strip()
            }
        )

        # 更新申請狀態
        await postgrest_patch(
            "waive_requests",
            {"id": f"eq.{request_id}"},
            {
                "status": "approved",
                "approved_by": approved_by,
                "approved_at": now
            }
        )

        # 記錄審計日誌
        try:
            await postgrest_post("audit_logs", {
                "table_name": "payments",
                "record_id": payment_id,
                "action": "UPDATE",
                "old_data": {"payment_status": payment.get("payment_status")},
                "new_data": {"payment_status": "waived", "approved_by": approved_by},
                "changed_fields": ["payment_status"]
            })
        except Exception as audit_err:
            logger.warning(f"審計日誌記錄失敗: {audit_err}")

        return {
            "success": True,
            "message": "免收申請已核准",
            "request_id": request_id,
            "payment_id": payment_id
        }

    except Exception as e:
        logger.error(f"billing_approve_waive error: {e}")
        raise


async def billing_reject_waive(
    request_id: int,
    rejected_by: str,
    reject_reason: str
) -> Dict[str, Any]:
    """
    駁回免收（SSD: billing_reject_waive）

    Args:
        request_id: 免收申請ID
        rejected_by: 駁回人
        reject_reason: 駁回原因

    Returns:
        駁回結果
    """
    if not reject_reason or not reject_reason.strip():
        return {
            "success": False,
            "error": "必須提供駁回原因",
            "code": "INVALID_PARAMS"
        }

    # 1. 取得並驗證申請
    try:
        requests = await postgrest_get("waive_requests", {"id": f"eq.{request_id}"})
        if not requests:
            return {"success": False, "error": "找不到免收申請", "code": "NOT_FOUND"}

        waive_request = requests[0]

        if waive_request.get("status") != "pending":
            return {
                "success": False,
                "error": f"申請狀態為 {waive_request.get('status')}，無法駁回",
                "code": "INVALID_STATUS"
            }

        # 2. 更新申請狀態
        await postgrest_patch(
            "waive_requests",
            {"id": f"eq.{request_id}"},
            {
                "status": "rejected",
                "approved_by": rejected_by,  # 欄位重用
                "approved_at": datetime.now().isoformat(),
                "reject_reason": reject_reason.strip()
            }
        )

        return {
            "success": True,
            "message": "免收申請已駁回",
            "request_id": request_id,
            "payment_id": waive_request.get("payment_id")
        }

    except Exception as e:
        logger.error(f"billing_reject_waive error: {e}")
        raise


async def billing_send_reminder(
    payment_id: int
) -> Dict[str, Any]:
    """
    發送催繳提醒（SSD: billing_send_reminder）

    透過 Brain 轉發到 LINE，前端不需知道通知管道。

    Args:
        payment_id: 付款ID

    Returns:
        發送結果
    """
    # 1. 取得付款資訊（使用視圖）
    try:
        payments = await postgrest_get("v_payments_due", {"id": f"eq.{payment_id}"})
        if not payments:
            return {"success": False, "error": "找不到付款記錄", "code": "NOT_FOUND"}

        payment = payments[0]
    except Exception as e:
        logger.error(f"billing_send_reminder - 取得付款記錄失敗: {e}")
        raise

    # 2. 檢查 LINE 綁定
    line_user_id = payment.get("line_user_id")
    if not line_user_id:
        return {
            "success": False,
            "error": f"客戶 {payment.get('customer_name')} 未綁定 LINE",
            "code": "LINE_NOT_BOUND"
        }

    # 3. 組合訊息
    customer_name = payment.get("customer_name", "客戶")
    period = payment.get("payment_period", "")
    amount = payment.get("total_due", 0)
    due_date = payment.get("due_date", "")
    status = payment.get("payment_status", "pending")

    if status == "overdue":
        overdue_days = payment.get("overdue_days", 0)
        message = (
            f"親愛的 {customer_name} 您好 ⚠️\n\n"
            f"您 {period} 的租金 ${amount:,.0f} 已逾期 {overdue_days} 天，"
            f"請儘速處理。\n\n"
            f"如有任何困難請聯繫我們協助處理 📞"
        )
    else:
        message = (
            f"親愛的 {customer_name} 您好 🙋‍♀️\n\n"
            f"提醒您 {period} 的租金 ${amount:,.0f} 將於 {due_date} 到期，"
            f"請記得繳費喔！\n\n"
            f"如有任何問題歡迎聯繫我們 💼"
        )

    # 4. 透過 Brain 發送（或直接 LINE API）
    try:
        # 嘗試透過 Brain 發送
        async with httpx.AsyncClient() as client:
            response = await client.post(
                f"{BRAIN_API_URL}/api/integration/send",
                json={
                    "line_user_id": line_user_id,
                    "message": message,
                    "source": "billing_reminder",
                    "metadata": {
                        "payment_id": payment_id,
                        "customer_name": customer_name
                    }
                },
                timeout=30.0
            )

            if response.status_code == 200:
                # 記錄通知日誌
                try:
                    await postgrest_post("notification_logs", {
                        "notification_type": "payment_reminder",
                        "customer_id": payment.get("customer_id"),
                        "payment_id": payment_id,
                        "recipient_name": customer_name,
                        "recipient_line_id": line_user_id,
                        "message_content": message[:200],
                        "status": "sent",
                        "triggered_by": "manual"
                    })
                except Exception as log_err:
                    logger.warning(f"記錄通知日誌失敗: {log_err}")

                return {
                    "success": True,
                    "message": f"已發送催繳提醒給 {customer_name}",
                    "payment_id": payment_id
                }
            else:
                return {
                    "success": False,
                    "error": f"Brain API 錯誤: {response.status_code}",
                    "code": "NOTIFICATION_FAILED"
                }

    except httpx.RequestError as e:
        # Brain 無法連接，嘗試直接使用 line_tools
        logger.warning(f"Brain 無法連接，嘗試直接發送: {e}")

        try:
            from tools.line_tools import send_payment_reminder
            result = await send_payment_reminder(payment_id, "overdue" if status == "overdue" else "upcoming")
            return result
        except Exception as fallback_err:
            logger.error(f"Fallback 發送也失敗: {fallback_err}")
            return {
                "success": False,
                "error": "訊息發送失敗",
                "code": "NOTIFICATION_FAILED"
            }


async def billing_batch_remind(
    payment_ids: list,
    created_by: str = None
) -> Dict[str, Any]:
    """
    批量催繳（SSD: billing_batch_remind）

    Args:
        payment_ids: 付款ID列表
        created_by: 建立者

    Returns:
        批量任務資訊（可用 PostgREST embed 查詢進度）
    """
    if not payment_ids:
        return {
            "success": False,
            "error": "請提供至少一個付款ID",
            "code": "INVALID_PARAMS"
        }

    # 1. 創建批量任務
    task_id = str(uuid.uuid4())

    try:
        await postgrest_post("batch_tasks", {
            "id": task_id,
            "task_type": "send_reminder",
            "status": "processing",
            "total_count": len(payment_ids),
            "created_by": created_by,
            "started_at": datetime.now().isoformat()
        })

        # 2. 創建任務項目
        for pid in payment_ids:
            await postgrest_post("batch_task_items", {
                "task_id": task_id,
                "target_id": pid,
                "target_type": "payment",
                "status": "pending"
            })

    except Exception as e:
        logger.error(f"創建批量任務失敗: {e}")
        raise

    # 3. 背景執行（同步處理，實際應用應改為非同步）
    success_count = 0
    failed_count = 0

    for pid in payment_ids:
        result = await billing_send_reminder(pid)

        if result.get("success"):
            success_count += 1
            item_status = "success"
            error_code = None
            error_message = None
        else:
            failed_count += 1
            item_status = "failed"
            error_code = result.get("code", "UNKNOWN")
            error_message = result.get("error")

        # 更新項目狀態
        try:
            await postgrest_patch(
                "batch_task_items",
                {"task_id": f"eq.{task_id}", "target_id": f"eq.{pid}"},
                {
                    "status": item_status,
                    "error_code": error_code,
                    "error_message": error_message,
                    "processed_at": datetime.now().isoformat()
                }
            )
        except Exception as update_err:
            logger.warning(f"更新任務項目失敗: {update_err}")

    # 4. 更新任務狀態
    final_status = "completed" if failed_count == 0 else ("partial_success" if success_count > 0 else "failed")

    await postgrest_patch(
        "batch_tasks",
        {"id": f"eq.{task_id}"},
        {
            "status": final_status,
            "success_count": success_count,
            "failed_count": failed_count,
            "completed_at": datetime.now().isoformat()
        }
    )

    return {
        "success": True,
        "task_id": task_id,
        "status": final_status,
        "total_count": len(payment_ids),
        "success_count": success_count,
        "failed_count": failed_count,
        "query_url": f"/api/db/batch_tasks?id=eq.{task_id}&select=*,items:batch_task_items(*)"
    }


async def billing_set_promise(
    payment_id: int,
    promised_pay_date: str,
    notes: str = None
) -> Dict[str, Any]:
    """
    設定客戶承諾付款日期

    Args:
        payment_id: 付款ID
        promised_pay_date: 承諾付款日期 (YYYY-MM-DD)
        notes: 備註（可選）

    Returns:
        更新結果
    """
    # 驗證日期格式
    try:
        promise_date = datetime.strptime(promised_pay_date, "%Y-%m-%d").date()
    except ValueError:
        return {
            "success": False,
            "error": "日期格式錯誤，請使用 YYYY-MM-DD 格式",
            "code": "INVALID_DATE_FORMAT"
        }

    # 驗證日期不能是過去
    from datetime import date
    if promise_date < date.today():
        return {
            "success": False,
            "error": "承諾付款日期不能是過去的日期",
            "code": "INVALID_DATE"
        }

    # 1. 取得付款記錄
    try:
        payments = await postgrest_get("payments", {"id": f"eq.{payment_id}"})
        if not payments:
            return {"success": False, "error": "找不到付款記錄", "code": "NOT_FOUND"}

        payment = payments[0]
    except Exception as e:
        logger.error(f"billing_set_promise - 取得付款記錄失敗: {e}")
        raise

    # 2. 驗證狀態（只有待繳款項可以設定承諾日期）
    if payment.get("payment_status") not in ["pending", "overdue"]:
        return {
            "success": False,
            "error": f"只有待繳款項可設定承諾日期，目前狀態: {payment.get('payment_status')}",
            "code": "INVALID_STATUS"
        }

    # 3. 更新付款記錄
    try:
        update_data = {
            "promised_pay_date": promised_pay_date
        }

        result = await postgrest_patch(
            "payments",
            {"id": f"eq.{payment_id}"},
            update_data
        )

        updated = result[0] if isinstance(result, list) else result

        # 4. 寫入操作日誌
        await postgrest_post("payment_logs", {
            "payment_id": payment_id,
            "action": "set_promise",
            "details": {
                "promised_pay_date": promised_pay_date,
                "notes": notes
            }
        })

        return {
            "success": True,
            "message": f"已設定承諾付款日期：{promised_pay_date}",
            "payment_id": payment_id,
            "promised_pay_date": promised_pay_date,
            "customer_name": payment.get("customer_name"),
            "amount": payment.get("amount")
        }

    except Exception as e:
        logger.error(f"billing_set_promise - 更新失敗: {e}")
        raise


async def billing_clear_promise(
    payment_id: int,
    reason: str = None
) -> Dict[str, Any]:
    """
    清除客戶承諾付款日期

    Args:
        payment_id: 付款ID
        reason: 清除原因（可選）

    Returns:
        更新結果
    """
    # 1. 取得付款記錄
    try:
        payments = await postgrest_get("payments", {"id": f"eq.{payment_id}"})
        if not payments:
            return {"success": False, "error": "找不到付款記錄", "code": "NOT_FOUND"}

        payment = payments[0]
    except Exception as e:
        logger.error(f"billing_clear_promise - 取得付款記錄失敗: {e}")
        raise

    if not payment.get("promised_pay_date"):
        return {
            "success": False,
            "error": "此付款沒有設定承諾日期",
            "code": "NO_PROMISE"
        }

    # 2. 清除承諾日期
    try:
        result = await postgrest_patch(
            "payments",
            {"id": f"eq.{payment_id}"},
            {"promised_pay_date": None}
        )

        # 3. 寫入操作日誌
        await postgrest_post("payment_logs", {
            "payment_id": payment_id,
            "action": "clear_promise",
            "details": {
                "previous_date": payment.get("promised_pay_date"),
                "reason": reason
            }
        })

        return {
            "success": True,
            "message": "已清除承諾付款日期",
            "payment_id": payment_id,
            "previous_date": payment.get("promised_pay_date")
        }

    except Exception as e:
        logger.error(f"billing_clear_promise - 更新失敗: {e}")
        raise
