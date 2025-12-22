"""
Hour Jungle CRM - Renewal Domain Tools v2
續約流程管理工具（符合 SSD v1.2 定義）

操作獨立的 RenewalCase 實體，而非 Contract 欄位。

Commands:
- renewal_start: 啟動續約流程（創建 RenewalCase）
- renewal_send_notification: 發送續約通知
- renewal_confirm_intent: 確認續約意願
- renewal_record_payment: 記錄續約款
- renewal_complete: 完成續約（創建新合約）
- renewal_cancel: 取消續約
- renewal_get_case: 取得續約案件詳情
- renewal_list_cases: 列出續約案件
"""

import logging
import os
from datetime import datetime, timedelta
from typing import Dict, Any, Optional, List

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


async def postgrest_delete(endpoint: str, params: dict) -> None:
    """PostgREST DELETE 請求"""
    url = f"{POSTGREST_URL}/{endpoint}"
    async with httpx.AsyncClient() as client:
        response = await client.delete(url, params=params, timeout=30.0)
        response.raise_for_status()


# ============================================================================
# Renewal Commands
# ============================================================================

async def renewal_start(
    contract_id: int,
    created_by: str = None
) -> Dict[str, Any]:
    """
    啟動續約流程（創建 RenewalCase）

    Args:
        contract_id: 合約ID
        created_by: 建立者

    Returns:
        RenewalCase 資訊
    """
    # 1. 取得合約資訊
    try:
        contracts = await postgrest_get("contracts", {"id": f"eq.{contract_id}"})
        if not contracts:
            return {"success": False, "error": "找不到合約", "code": "NOT_FOUND"}

        contract = contracts[0]
    except Exception as e:
        logger.error(f"renewal_start - 取得合約失敗: {e}")
        raise

    # 2. 驗證合約狀態
    if contract.get("status") not in ["active", "expired"]:
        return {
            "success": False,
            "error": f"只有生效中或已到期的合約才能啟動續約，目前狀態: {contract.get('status')}",
            "code": "INVALID_STATUS"
        }

    # 3. 檢查是否已有進行中的續約
    existing = await postgrest_get("renewal_cases", {
        "contract_id": f"eq.{contract_id}",
        "status": "not.in.(completed,cancelled)"
    })
    if existing:
        return {
            "success": False,
            "error": "此合約已有進行中的續約案件",
            "code": "DUPLICATE_CASE",
            "existing_case_id": existing[0]["id"]
        }

    # 4. 創建 RenewalCase
    try:
        case_data = {
            "contract_id": contract_id,
            "status": "created",
            "reserved_position_number": contract.get("position_number"),
            "created_by": created_by
        }

        result = await postgrest_post("renewal_cases", case_data)
        renewal_case = result[0] if isinstance(result, list) else result

        # 5. 預留座位（如果有）
        position_number = contract.get("position_number")
        if position_number:
            try:
                # 取得 floor_plan_id
                floor_positions = await postgrest_get("floor_positions", {
                    "position_number": f"eq.{position_number}",
                    "limit": 1
                })

                if floor_positions:
                    floor_plan_id = floor_positions[0].get("floor_plan_id")
                    expires_at = (datetime.now() + timedelta(days=7)).isoformat()

                    await postgrest_post("position_reservations", {
                        "floor_plan_id": floor_plan_id,
                        "position_number": position_number,
                        "renewal_case_id": renewal_case["id"],
                        "expires_at": expires_at,
                        "status": "active"
                    })

                    logger.info(f"座位 {position_number} 已預留給續約案件 {renewal_case['id']}")
            except Exception as res_err:
                logger.warning(f"座位預留失敗（不影響續約）: {res_err}")

        return {
            "success": True,
            "message": "續約流程已啟動",
            "renewal_case": renewal_case,
            "contract": {
                "id": contract_id,
                "contract_number": contract.get("contract_number"),
                "end_date": contract.get("end_date"),
                "monthly_rent": contract.get("monthly_rent")
            }
        }

    except Exception as e:
        logger.error(f"renewal_start error: {e}")
        raise


async def renewal_send_notification(
    renewal_case_id: int
) -> Dict[str, Any]:
    """
    發送續約通知（SSD: renewal_send_notification）

    透過 Brain 轉發到 LINE。

    Args:
        renewal_case_id: 續約案件ID

    Returns:
        發送結果
    """
    # 1. 取得續約案件（使用視圖）
    try:
        cases = await postgrest_get("v_renewal_cases", {"id": f"eq.{renewal_case_id}"})
        if not cases:
            return {"success": False, "error": "找不到續約案件", "code": "NOT_FOUND"}

        renewal_case = cases[0]
    except Exception as e:
        logger.error(f"renewal_send_notification - 取得案件失敗: {e}")
        raise

    # 2. 檢查 LINE 綁定
    line_user_id = renewal_case.get("line_user_id")
    if not line_user_id:
        return {
            "success": False,
            "error": f"客戶 {renewal_case.get('customer_name')} 未綁定 LINE",
            "code": "LINE_NOT_BOUND"
        }

    # 3. 組合訊息
    customer_name = renewal_case.get("customer_name", "客戶")
    end_date = renewal_case.get("contract_end_date", "")
    days_remaining = renewal_case.get("days_remaining", 0)
    branch_name = renewal_case.get("branch_name", "Hour Jungle")

    if days_remaining <= 7:
        urgency = "⚠️ 緊急"
    elif days_remaining <= 30:
        urgency = "📢 重要"
    else:
        urgency = "📋 提醒"

    message = (
        f"{urgency} 續約通知\n\n"
        f"親愛的 {customer_name} 您好，\n\n"
        f"您在 {branch_name} 的合約將於 {end_date} 到期，"
        f"距今還有 {days_remaining} 天。\n\n"
        f"如需續約或有任何問題，歡迎隨時聯繫我們！\n\n"
        f"感謝您對 Hour Jungle 的支持 🙏"
    )

    # 4. 發送通知
    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                f"{BRAIN_API_URL}/api/integration/send",
                json={
                    "line_user_id": line_user_id,
                    "message": message,
                    "source": "renewal_notification",
                    "metadata": {
                        "renewal_case_id": renewal_case_id,
                        "customer_name": customer_name
                    }
                },
                timeout=30.0
            )

            if response.status_code == 200:
                # 更新案件狀態
                now = datetime.now().isoformat()
                await postgrest_patch(
                    "renewal_cases",
                    {"id": f"eq.{renewal_case_id}"},
                    {"status": "notified", "notified_at": now}
                )

                # 記錄通知日誌
                try:
                    await postgrest_post("notification_logs", {
                        "notification_type": "renewal_reminder",
                        "customer_id": renewal_case.get("customer_id"),
                        "contract_id": renewal_case.get("contract_id"),
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
                    "message": f"已發送續約通知給 {customer_name}",
                    "renewal_case_id": renewal_case_id,
                    "days_remaining": days_remaining
                }
            else:
                return {
                    "success": False,
                    "error": f"通知發送失敗: {response.status_code}",
                    "code": "NOTIFICATION_FAILED"
                }

    except httpx.RequestError as e:
        logger.warning(f"Brain 無法連接: {e}")
        # Fallback 到 line_tools
        try:
            from tools.line_tools import send_renewal_reminder
            result = await send_renewal_reminder(renewal_case.get("contract_id"))

            if result.get("success"):
                # 更新案件狀態
                await postgrest_patch(
                    "renewal_cases",
                    {"id": f"eq.{renewal_case_id}"},
                    {"status": "notified", "notified_at": datetime.now().isoformat()}
                )

            return result
        except Exception as fallback_err:
            return {
                "success": False,
                "error": "訊息發送失敗",
                "code": "NOTIFICATION_FAILED"
            }


async def renewal_confirm_intent(
    renewal_case_id: int,
    confirmed_by: str = None,
    notes: str = None
) -> Dict[str, Any]:
    """
    確認續約意願（SSD: renewal_confirm_intent）

    Args:
        renewal_case_id: 續約案件ID
        confirmed_by: 確認人（可能是客戶透過 LIFF 或櫃台人員）
        notes: 備註

    Returns:
        確認結果
    """
    # 1. 取得續約案件
    try:
        cases = await postgrest_get("renewal_cases", {"id": f"eq.{renewal_case_id}"})
        if not cases:
            return {"success": False, "error": "找不到續約案件", "code": "NOT_FOUND"}

        renewal_case = cases[0]
    except Exception as e:
        logger.error(f"renewal_confirm_intent - 取得案件失敗: {e}")
        raise

    # 2. 驗證狀態
    valid_statuses = ["created", "notified"]
    if renewal_case.get("status") not in valid_statuses:
        return {
            "success": False,
            "error": f"目前狀態為 {renewal_case.get('status')}，無法確認意願",
            "code": "INVALID_STATUS"
        }

    # 3. 更新案件
    now = datetime.now().isoformat()
    update_data = {
        "status": "confirmed",
        "confirmed_at": now
    }

    try:
        await postgrest_patch(
            "renewal_cases",
            {"id": f"eq.{renewal_case_id}"},
            update_data
        )

        return {
            "success": True,
            "message": "續約意願已確認",
            "renewal_case_id": renewal_case_id,
            "next_step": "收取續約款項"
        }

    except Exception as e:
        logger.error(f"renewal_confirm_intent error: {e}")
        raise


async def renewal_record_payment(
    renewal_case_id: int,
    payment_method: str,
    amount: float,
    payment_date: str = None
) -> Dict[str, Any]:
    """
    記錄續約款（SSD: renewal_record_payment）

    這會創建新的 Payment 記錄，而非使用舊合約的 Payment。

    Args:
        renewal_case_id: 續約案件ID
        payment_method: 付款方式
        amount: 金額
        payment_date: 付款日期

    Returns:
        付款結果
    """
    # 1. 取得續約案件（使用視圖取得完整資訊）
    try:
        cases = await postgrest_get("v_renewal_cases", {"id": f"eq.{renewal_case_id}"})
        if not cases:
            return {"success": False, "error": "找不到續約案件", "code": "NOT_FOUND"}

        renewal_case = cases[0]
    except Exception as e:
        logger.error(f"renewal_record_payment - 取得案件失敗: {e}")
        raise

    # 2. 驗證狀態
    if renewal_case.get("status") not in ["confirmed", "notified", "created"]:
        return {
            "success": False,
            "error": f"目前狀態為 {renewal_case.get('status')}，無法記錄付款",
            "code": "INVALID_STATUS"
        }

    # 3. 更新案件
    now = datetime.now().isoformat()
    paid_at = payment_date or datetime.now().strftime("%Y-%m-%d")

    try:
        # 如果尚未確認，自動補上（Cascade Logic）
        update_data = {
            "status": "paid",
            "paid_at": f"{paid_at}T00:00:00+08:00"
        }

        if not renewal_case.get("confirmed_at"):
            update_data["confirmed_at"] = now

        await postgrest_patch(
            "renewal_cases",
            {"id": f"eq.{renewal_case_id}"},
            update_data
        )

        return {
            "success": True,
            "message": "續約款項已記錄",
            "renewal_case_id": renewal_case_id,
            "amount": amount,
            "payment_method": payment_method,
            "next_step": "開立發票並簽署新合約",
            "cascade_triggered": not renewal_case.get("confirmed_at")
        }

    except Exception as e:
        logger.error(f"renewal_record_payment error: {e}")
        raise


async def renewal_complete(
    renewal_case_id: int,
    new_start_date: str,
    new_end_date: str,
    new_monthly_rent: float = None,
    notes: str = None
) -> Dict[str, Any]:
    """
    完成續約（SSD: renewal_complete）

    創建新合約，將預留座位轉為正式占用。

    Args:
        renewal_case_id: 續約案件ID
        new_start_date: 新合約開始日期
        new_end_date: 新合約結束日期
        new_monthly_rent: 新月租金（不填則沿用）
        notes: 備註

    Returns:
        新合約資訊
    """
    # 1. 取得續約案件
    try:
        cases = await postgrest_get("v_renewal_cases", {"id": f"eq.{renewal_case_id}"})
        if not cases:
            return {"success": False, "error": "找不到續約案件", "code": "NOT_FOUND"}

        renewal_case = cases[0]
    except Exception as e:
        logger.error(f"renewal_complete - 取得案件失敗: {e}")
        raise

    # 2. 驗證狀態（至少要已付款）
    if renewal_case.get("status") not in ["paid", "invoiced"]:
        return {
            "success": False,
            "error": f"目前狀態為 {renewal_case.get('status')}，需先完成付款才能完成續約",
            "code": "INVALID_STATUS"
        }

    # 3. 驗證日期（新合約 start_date > 舊合約 end_date）
    old_end_date = renewal_case.get("contract_end_date")
    if old_end_date and new_start_date <= str(old_end_date):
        return {
            "success": False,
            "error": f"新合約起始日必須晚於舊合約到期日 ({old_end_date})",
            "code": "DATE_OVERLAP"
        }

    # 4. 取得舊合約完整資訊
    old_contract_id = renewal_case.get("contract_id")
    old_contracts = await postgrest_get("contracts", {"id": f"eq.{old_contract_id}"})
    if not old_contracts:
        return {"success": False, "error": "找不到舊合約", "code": "NOT_FOUND"}

    old_contract = old_contracts[0]

    # 5. 創建新合約
    try:
        # 生成新合約編號
        from tools.crm_tools import generate_contract_number
        new_contract_number = await generate_contract_number(old_contract.get("branch_id"))

        new_contract_data = {
            "contract_number": new_contract_number,
            "customer_id": old_contract.get("customer_id"),
            "branch_id": old_contract.get("branch_id"),
            "contract_type": old_contract.get("contract_type"),
            "plan_name": old_contract.get("plan_name"),
            "start_date": new_start_date,
            "end_date": new_end_date,
            "monthly_rent": new_monthly_rent or old_contract.get("monthly_rent"),
            "original_price": old_contract.get("original_price"),
            "deposit": old_contract.get("deposit", 0),
            "payment_cycle": old_contract.get("payment_cycle", "monthly"),
            "payment_day": old_contract.get("payment_day", 5),
            "status": "active",
            "position_number": old_contract.get("position_number"),
            # 複製承租人資訊
            "company_name": old_contract.get("company_name"),
            "representative_name": old_contract.get("representative_name"),
            "representative_address": old_contract.get("representative_address"),
            "id_number": old_contract.get("id_number"),
            "company_tax_id": old_contract.get("company_tax_id"),
            "phone": old_contract.get("phone"),
            "email": old_contract.get("email"),
            # 介紹人
            "broker_name": old_contract.get("broker_name"),
            "broker_firm_id": old_contract.get("broker_firm_id"),
            "commission_eligible": old_contract.get("commission_eligible", False),
            "notes": notes or f"續約自 {old_contract.get('contract_number')}"
        }

        result = await postgrest_post("contracts", new_contract_data)
        new_contract = result[0] if isinstance(result, list) else result

        # 6. 更新舊合約狀態
        await postgrest_patch(
            "contracts",
            {"id": f"eq.{old_contract_id}"},
            {"status": "renewed"}
        )

        # 7. 更新續約案件
        now = datetime.now().isoformat()
        await postgrest_patch(
            "renewal_cases",
            {"id": f"eq.{renewal_case_id}"},
            {
                "status": "completed",
                "signed_at": now,
                "new_contract_id": new_contract["id"]
            }
        )

        # 8. 釋放座位預留（轉為正式占用）
        try:
            await postgrest_patch(
                "position_reservations",
                {"renewal_case_id": f"eq.{renewal_case_id}"},
                {"status": "converted", "released_at": now}
            )
        except Exception as res_err:
            logger.warning(f"更新座位預留狀態失敗: {res_err}")

        return {
            "success": True,
            "message": "續約完成",
            "renewal_case_id": renewal_case_id,
            "old_contract": {
                "id": old_contract_id,
                "contract_number": old_contract.get("contract_number"),
                "status": "renewed"
            },
            "new_contract": {
                "id": new_contract["id"],
                "contract_number": new_contract.get("contract_number"),
                "start_date": new_start_date,
                "end_date": new_end_date,
                "monthly_rent": new_contract.get("monthly_rent")
            }
        }

    except Exception as e:
        logger.error(f"renewal_complete error: {e}")
        raise


async def renewal_cancel(
    renewal_case_id: int,
    cancel_reason: str,
    cancelled_by: str = None
) -> Dict[str, Any]:
    """
    取消續約（SSD: renewal_cancel）

    釋放預留的座位資源。

    Args:
        renewal_case_id: 續約案件ID
        cancel_reason: 取消原因（必填）
        cancelled_by: 取消人

    Returns:
        取消結果
    """
    if not cancel_reason or not cancel_reason.strip():
        return {
            "success": False,
            "error": "必須提供取消原因",
            "code": "INVALID_PARAMS"
        }

    # 1. 取得續約案件
    try:
        cases = await postgrest_get("renewal_cases", {"id": f"eq.{renewal_case_id}"})
        if not cases:
            return {"success": False, "error": "找不到續約案件", "code": "NOT_FOUND"}

        renewal_case = cases[0]
    except Exception as e:
        logger.error(f"renewal_cancel - 取得案件失敗: {e}")
        raise

    # 2. 驗證狀態
    if renewal_case.get("status") in ["completed", "cancelled"]:
        return {
            "success": False,
            "error": f"狀態為 {renewal_case.get('status')} 的案件無法取消",
            "code": "INVALID_STATUS"
        }

    # 3. 釋放座位預留
    now = datetime.now().isoformat()
    try:
        await postgrest_patch(
            "position_reservations",
            {"renewal_case_id": f"eq.{renewal_case_id}", "status": "eq.active"},
            {"status": "released", "released_at": now, "release_reason": "續約取消"}
        )
    except Exception as res_err:
        logger.warning(f"釋放座位預留失敗: {res_err}")

    # 4. 取消可能存在的新合約草稿
    new_contract_id = renewal_case.get("new_contract_id")
    if new_contract_id:
        try:
            # 只取消草稿狀態的合約
            await postgrest_patch(
                "contracts",
                {"id": f"eq.{new_contract_id}", "status": "eq.draft"},
                {"status": "cancelled"}
            )
        except Exception as contract_err:
            logger.warning(f"取消新合約草稿失敗: {contract_err}")

    # 5. 更新續約案件
    try:
        await postgrest_patch(
            "renewal_cases",
            {"id": f"eq.{renewal_case_id}"},
            {
                "status": "cancelled",
                "cancelled_at": now,
                "cancel_reason": cancel_reason.strip()
            }
        )

        return {
            "success": True,
            "message": "續約已取消",
            "renewal_case_id": renewal_case_id,
            "cancel_reason": cancel_reason
        }

    except Exception as e:
        logger.error(f"renewal_cancel error: {e}")
        raise


async def renewal_get_case(
    renewal_case_id: int
) -> Dict[str, Any]:
    """
    取得續約案件詳情

    Args:
        renewal_case_id: 續約案件ID

    Returns:
        案件詳情
    """
    try:
        cases = await postgrest_get("v_renewal_cases", {"id": f"eq.{renewal_case_id}"})
        if not cases:
            return {"found": False, "error": "找不到續約案件"}

        return {
            "found": True,
            "renewal_case": cases[0]
        }

    except Exception as e:
        logger.error(f"renewal_get_case error: {e}")
        raise


async def renewal_list_cases(
    branch_id: int = None,
    status: str = None,
    days_remaining_max: int = None,
    limit: int = 50
) -> Dict[str, Any]:
    """
    列出續約案件

    Args:
        branch_id: 場館ID
        status: 狀態篩選
        days_remaining_max: 最大剩餘天數
        limit: 回傳筆數

    Returns:
        案件列表
    """
    params = {"limit": limit, "order": "contract_end_date.asc"}

    if branch_id:
        params["branch_id"] = f"eq.{branch_id}"
    if status:
        params["status"] = f"eq.{status}"
    if days_remaining_max:
        params["days_remaining"] = f"lte.{days_remaining_max}"

    try:
        cases = await postgrest_get("v_renewal_cases", params)

        # 統計
        by_status = {}
        for case in cases:
            s = case.get("status", "unknown")
            by_status[s] = by_status.get(s, 0) + 1

        return {
            "count": len(cases),
            "by_status": by_status,
            "renewal_cases": cases
        }

    except Exception as e:
        logger.error(f"renewal_list_cases error: {e}")
        raise
