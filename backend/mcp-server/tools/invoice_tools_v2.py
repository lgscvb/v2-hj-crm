"""
Hour Jungle CRM - Invoice Tools V2（冪等性保護）

解決的問題（來自 PRD-v2.5）：
- 呼叫光貿 API 成功後、更新本地 DB 前 Timeout
- 再次開票會在光貿產生重複發票

解法：
1. 開票前先建立 invoice_operations 記錄
2. 記錄唯一的 order_id
3. API 成功後透過 Transaction 同時更新 operations 和 payments
4. 重試時先檢查是否有已完成的操作
"""

import logging
import json
import hashlib
import time
from datetime import datetime
from typing import Optional, Dict, Any
import math

import httpx

logger = logging.getLogger(__name__)

# 環境變數設定
import os

# 光貿 API 設定
AMEGO_API_BASE = os.getenv("AMEGO_API_BASE", "https://invoice-api.amego.tw")
AMEGO_API_KEY_HUANRUI = os.getenv("AMEGO_API_KEY_HUANRUI", "")
AMEGO_API_SECRET_HUANRUI = os.getenv("AMEGO_API_SECRET_HUANRUI", "")
AMEGO_API_KEY_DAZHONG = os.getenv("AMEGO_API_KEY_DAZHONG", "")
AMEGO_API_SECRET_DAZHONG = os.getenv("AMEGO_API_SECRET_DAZHONG", "")
POSTGREST_URL = os.getenv("POSTGREST_URL", "http://postgrest:3000")

# 依賴注入
postgrest_rpc = None


def set_postgrest_rpc(func):
    """設置 postgrest_rpc 函數"""
    global postgrest_rpc
    postgrest_rpc = func


def get_amego_credentials(branch_id: int) -> tuple[str, str]:
    """根據 branch_id 取得對應的 API 憑證"""
    if branch_id == 3:
        return AMEGO_API_KEY_DAZHONG, AMEGO_API_SECRET_DAZHONG
    else:
        return AMEGO_API_KEY_HUANRUI, AMEGO_API_SECRET_HUANRUI


def generate_amego_signature(json_data: str, timestamp: int, app_key: str) -> str:
    """生成光貿 API 簽名"""
    hash_text = json_data + str(timestamp) + app_key
    m = hashlib.md5()
    m.update(hash_text.encode('utf-8'))
    return m.hexdigest()


async def postgrest_get(endpoint: str, params: dict = None) -> Any:
    """PostgREST GET 請求"""
    url = f"{POSTGREST_URL}/{endpoint}"
    async with httpx.AsyncClient() as client:
        response = await client.get(url, params=params, timeout=30.0)
        response.raise_for_status()
        return response.json()


# ============================================================================
# V2 發票工具（冪等性保護）
# ============================================================================

async def invoice_create_v2(
    payment_id: int,
    invoice_type: str = "personal",
    buyer_name: str = None,
    buyer_tax_id: str = None,
    carrier_type: str = None,
    carrier_number: str = None,
    donate_code: str = None,
    print_flag: bool = False,
    created_by: str = None
) -> Dict[str, Any]:
    """
    開立電子發票 V2（使用冪等性保護）

    流程：
    1. 檢查是否有已完成的操作（防止重複開票）
    2. 建立操作記錄
    3. 標記為「已發送」
    4. 呼叫光貿 API
    5. 成功：透過 Transaction 更新 operations + payments
    6. 失敗：記錄錯誤
    """
    # 1. 取得繳費記錄
    try:
        payments = await postgrest_get("payments", {"id": f"eq.{payment_id}"})
        if not payments:
            return {"success": False, "message": "找不到繳費記錄"}

        payment = payments[0]

        # 檢查是否已開發票
        if payment.get("invoice_number"):
            return {
                "success": False,
                "message": f"此繳費已開立發票：{payment['invoice_number']}",
                "invoice_number": payment['invoice_number']
            }

        # 檢查是否已付款
        if payment.get("payment_status") != "paid":
            return {
                "success": False,
                "message": "繳費尚未完成，無法開立發票"
            }

        branch_id = payment.get("branch_id")
        amount = payment.get("amount", 0)

    except Exception as e:
        logger.error(f"取得繳費記錄失敗: {e}")
        return {"success": False, "error": str(e)}

    # 2. 檢查是否有進行中或已完成的操作
    try:
        check_result = await postgrest_rpc("check_invoice_operation", {
            "p_payment_id": payment_id,
            "p_operation_type": "create"
        })

        if check_result.get("has_operation"):
            if check_result.get("status") == "completed":
                # 已完成，直接返回結果（冪等性）
                return {
                    "success": True,
                    "already_completed": True,
                    "invoice_number": check_result.get("invoice_number"),
                    "message": f"此付款已開立發票：{check_result.get('invoice_number')}"
                }
            else:
                # 進行中
                return {
                    "success": False,
                    "in_progress": True,
                    "message": "發票開立進行中，請稍候重試"
                }

    except Exception as e:
        logger.error(f"檢查發票操作失敗: {e}")
        return {"success": False, "error": str(e)}

    # 3. 取得 API 憑證
    api_key, api_secret = get_amego_credentials(branch_id)
    if not api_key or not api_secret:
        return {
            "success": False,
            "message": f"分館 {branch_id} 的發票 API 憑證未設定"
        }

    # 4. 準備發票資料
    timestamp = int(time.time())
    order_id = f"P{payment_id}_{timestamp}"  # 唯一訂單編號

    total_amount = int(amount)
    sales_amount = math.floor(total_amount / 1.05)
    tax_amount = total_amount - sales_amount

    invoice_data = {
        "OrderId": order_id,
        "BuyerIdentifier": buyer_tax_id if buyer_tax_id else "0000000000",
        "BuyerName": buyer_name if buyer_name else "消費者",
        "BuyerAddress": "",
        "BuyerTelephoneNumber": "",
        "BuyerEmailAddress": "",
        "MainRemark": f"Hour Jungle 繳費單 #{payment_id}",
        "ProductItem": [{
            "Description": "共享空間租賃服務",
            "Quantity": "1",
            "UnitPrice": str(sales_amount),
            "Amount": str(sales_amount),
            "Remark": "",
            "TaxType": "1"
        }],
        "SalesAmount": str(sales_amount),
        "FreeTaxSalesAmount": "0",
        "ZeroTaxSalesAmount": "0",
        "TaxType": "1",
        "TaxRate": "0.05",
        "TaxAmount": str(tax_amount),
        "TotalAmount": str(total_amount)
    }

    # 載具設定
    if carrier_type == "mobile" and carrier_number:
        invoice_data["CarrierType"] = "3J0002"
        invoice_data["CarrierId1"] = carrier_number
        invoice_data["CarrierId2"] = carrier_number
    elif carrier_type == "natural_person" and carrier_number:
        invoice_data["CarrierType"] = "CQ0001"
        invoice_data["CarrierId1"] = carrier_number
        invoice_data["CarrierId2"] = carrier_number
    elif carrier_type == "donate" and donate_code:
        invoice_data["NPOBAN"] = donate_code

    json_data = json.dumps(invoice_data, ensure_ascii=False, separators=(',', ':'))
    sign = generate_amego_signature(json_data, timestamp, api_key)

    # 5. 建立操作記錄
    try:
        create_result = await postgrest_rpc("create_invoice_operation", {
            "p_payment_id": payment_id,
            "p_order_id": order_id,
            "p_operation_type": "create",
            "p_api_request": invoice_data,
            "p_created_by": created_by
        })

        if not create_result.get("success"):
            if create_result.get("code") == "ALREADY_COMPLETED":
                return {
                    "success": True,
                    "already_completed": True,
                    "invoice_number": create_result.get("invoice_number"),
                    "message": create_result.get("message")
                }
            return create_result

        operation_id = create_result.get("operation_id")

    except Exception as e:
        logger.error(f"建立操作記錄失敗: {e}")
        return {"success": False, "error": str(e)}

    # 6. 標記為「已發送」
    try:
        await postgrest_rpc("update_invoice_operation_sent", {
            "p_operation_id": operation_id
        })
    except Exception as e:
        logger.warning(f"標記已發送失敗（不影響操作）: {e}")

    # 7. 呼叫光貿 API
    try:
        import urllib.parse
        post_data = {
            "invoice": api_secret,
            "data": json_data,
            "time": timestamp,
            "sign": sign
        }
        payload = urllib.parse.urlencode(post_data)

        async with httpx.AsyncClient() as client:
            response = await client.post(
                f"{AMEGO_API_BASE}/json/f0401",
                content=payload,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
                timeout=30.0
            )

            raw_text = response.text
            logger.info(f"發票 API 回應: {raw_text[:500]}")

            if not raw_text.strip():
                # 記錄失敗
                await postgrest_rpc("fail_invoice_operation", {
                    "p_operation_id": operation_id,
                    "p_error_message": "API 回傳空回應"
                })
                return {"success": False, "message": "發票 API 回傳空回應"}

            try:
                result = response.json()
            except Exception as json_err:
                await postgrest_rpc("fail_invoice_operation", {
                    "p_operation_id": operation_id,
                    "p_error_message": f"JSON 解析失敗: {json_err}",
                    "p_api_response": {"raw": raw_text[:500]}
                })
                return {"success": False, "message": "發票 API 回應格式錯誤"}

            # 8. 檢查結果
            if str(result.get("code")) == "0":
                invoice_number = result.get("invoiceNumber") or result.get("invoice_number")

                # 透過 Transaction 完成操作
                complete_result = await postgrest_rpc("complete_invoice_operation", {
                    "p_operation_id": operation_id,
                    "p_invoice_number": invoice_number,
                    "p_api_response": result
                })

                return {
                    "success": True,
                    "message": "發票開立成功",
                    "invoice_number": invoice_number,
                    "amount": amount,
                    "operation_id": operation_id
                }
            else:
                error_msg = result.get("message") or result.get("msg") or str(result)
                await postgrest_rpc("fail_invoice_operation", {
                    "p_operation_id": operation_id,
                    "p_error_message": error_msg,
                    "p_api_response": result
                })
                return {
                    "success": False,
                    "message": f"發票開立失敗: {error_msg}",
                    "api_response": result
                }

    except httpx.HTTPError as e:
        logger.error(f"發票 API 呼叫失敗: {e}")
        try:
            await postgrest_rpc("fail_invoice_operation", {
                "p_operation_id": operation_id,
                "p_error_message": str(e)
            })
        except:
            pass
        return {"success": False, "message": f"發票 API 呼叫失敗: {str(e)}"}


async def invoice_recover_operation(
    payment_id: int
) -> Dict[str, Any]:
    """
    恢復發票操作

    如果之前的操作被中斷（status=sent），嘗試查詢光貿系統確認結果
    """
    try:
        check_result = await postgrest_rpc("check_invoice_operation", {
            "p_payment_id": payment_id,
            "p_operation_type": "create"
        })

        if not check_result.get("has_operation"):
            return {"success": False, "message": "沒有需要恢復的操作"}

        if check_result.get("status") == "completed":
            return {
                "success": True,
                "already_completed": True,
                "invoice_number": check_result.get("invoice_number"),
                "message": "操作已完成"
            }

        # status = 'sent'，需要手動查詢光貿系統確認
        return {
            "success": False,
            "needs_manual_check": True,
            "operation_id": check_result.get("operation_id"),
            "message": "操作狀態為「已發送」，請手動查詢光貿系統確認是否已開票"
        }

    except Exception as e:
        logger.error(f"恢復操作失敗: {e}")
        return {"success": False, "error": str(e)}
