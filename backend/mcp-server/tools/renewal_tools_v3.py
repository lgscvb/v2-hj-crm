"""
Hour Jungle CRM - Renewal Domain Tools v3
續約流程管理工具（草稿機制 + Transaction 保護）

設計原則：
1. 兩階段提交：先建草稿，確認後啟用
2. 草稿不影響業務：renewal_draft 狀態不會產生應收帳款
3. Transaction 保護：啟用操作使用 DB Transaction
4. 冪等性：使用 idempotency_key 防止重複提交

Commands:
- renewal_create_draft: 建立續約草稿
- renewal_update_draft: 更新續約草稿
- renewal_activate: 啟用續約草稿（Transaction）
- renewal_cancel_draft: 取消續約草稿
- renewal_check_draft: 檢查是否有未完成的草稿
"""

import logging
import os
import uuid
from datetime import datetime, timedelta
from typing import Dict, Any, Optional

import httpx

logger = logging.getLogger(__name__)

POSTGREST_URL = os.getenv("POSTGREST_URL", "http://postgrest:3000")


async def postgrest_get(endpoint: str, params: dict = None) -> Any:
    """PostgREST GET 請求"""
    url = f"{POSTGREST_URL}/{endpoint}"
    async with httpx.AsyncClient() as client:
        response = await client.get(url, params=params, timeout=30.0)
        response.raise_for_status()
        return response.json()


async def postgrest_post(endpoint: str, data: dict, headers: dict = None) -> Any:
    """PostgREST POST 請求"""
    url = f"{POSTGREST_URL}/{endpoint}"
    default_headers = {
        "Content-Type": "application/json",
        "Prefer": "return=representation"
    }
    if headers:
        default_headers.update(headers)
    async with httpx.AsyncClient() as client:
        response = await client.post(url, json=data, headers=default_headers, timeout=30.0)
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


async def postgrest_rpc(function_name: str, params: dict) -> Any:
    """PostgREST RPC 呼叫（用於調用 PostgreSQL 函數）"""
    url = f"{POSTGREST_URL}/rpc/{function_name}"
    headers = {"Content-Type": "application/json"}
    async with httpx.AsyncClient() as client:
        response = await client.post(url, json=params, headers=headers, timeout=30.0)
        response.raise_for_status()
        return response.json()


# ============================================================================
# 續約草稿機制
# ============================================================================

async def renewal_check_draft(
    contract_id: int
) -> Dict[str, Any]:
    """
    檢查是否有未完成的續約草稿

    Args:
        contract_id: 原合約 ID

    Returns:
        草稿資訊（如果有）
    """
    try:
        # 查詢是否有續約草稿
        drafts = await postgrest_get("contracts", {
            "renewed_from_id": f"eq.{contract_id}",
            "status": "eq.renewal_draft",
            "select": "id,contract_number,start_date,end_date,monthly_rent,created_at"
        })

        if drafts:
            return {
                "has_draft": True,
                "draft": drafts[0],
                "message": "發現未完成的續約草稿，您可以繼續編輯或取消"
            }

        return {
            "has_draft": False,
            "message": "沒有未完成的續約草稿"
        }

    except Exception as e:
        logger.error(f"renewal_check_draft error: {e}")
        return {"has_draft": False, "error": str(e)}


async def renewal_create_draft(
    contract_id: int,
    new_start_date: str,
    new_end_date: str,
    # 可選修改項
    plan_name: str = None,
    monthly_rent: float = None,
    payment_cycle: str = None,
    payment_day: int = None,
    position_number: str = None,
    branch_id: int = None,
    deposit: float = None,
    original_price: float = None,
    # 承租人資訊
    company_name: str = None,
    company_tax_id: str = None,
    representative_name: str = None,
    representative_address: str = None,
    id_number: str = None,
    phone: str = None,
    email: str = None,
    # 系統
    idempotency_key: str = None,
    created_by: str = None,
    notes: str = None
) -> Dict[str, Any]:
    """
    建立續約草稿

    草稿狀態（renewal_draft）不會：
    - 出現在應收帳款
    - 影響原合約的狀態
    - 觸發任何自動化流程

    Args:
        contract_id: 原合約 ID
        new_start_date: 新合約開始日期
        new_end_date: 新合約結束日期
        其他參數: 不填則沿用原合約

    Returns:
        草稿資訊
    """
    # 1. 生成或驗證冪等性 Key
    if not idempotency_key:
        idempotency_key = str(uuid.uuid4())

    # 檢查冪等性（是否已建立過相同的草稿）
    existing_ops = await postgrest_get("renewal_operations", {
        "idempotency_key": f"eq.{idempotency_key}"
    })
    if existing_ops:
        existing = existing_ops[0]
        if existing.get("new_contract_id"):
            # 返回已存在的草稿
            drafts = await postgrest_get("contracts", {
                "id": f"eq.{existing['new_contract_id']}"
            })
            if drafts:
                return {
                    "success": True,
                    "draft_id": existing["new_contract_id"],
                    "draft": drafts[0],
                    "is_existing": True,
                    "message": "使用已存在的續約草稿"
                }

    # 2. 取得原合約資訊
    try:
        old_contracts = await postgrest_get("contracts", {
            "id": f"eq.{contract_id}",
            "select": "*"
        })
        if not old_contracts:
            return {"success": False, "error": "找不到原合約", "code": "NOT_FOUND"}

        old_contract = old_contracts[0]
    except Exception as e:
        logger.error(f"renewal_create_draft - 取得原合約失敗: {e}")
        return {"success": False, "error": str(e)}

    # 3. 驗證原合約狀態
    if old_contract.get("status") not in ["active", "expired"]:
        return {
            "success": False,
            "error": f"原合約狀態為 {old_contract.get('status')}，無法續約",
            "code": "INVALID_STATUS"
        }

    # 4. 檢查是否已有續約草稿
    existing_drafts = await postgrest_get("contracts", {
        "renewed_from_id": f"eq.{contract_id}",
        "status": "in.(renewal_draft,active)"
    })
    if existing_drafts:
        existing = existing_drafts[0]
        if existing["status"] == "active":
            return {
                "success": False,
                "error": "此合約已有生效的續約合約",
                "code": "ALREADY_RENEWED",
                "existing_contract_id": existing["id"]
            }
        else:
            return {
                "success": False,
                "error": "此合約已有續約草稿，請先完成或取消",
                "code": "DRAFT_EXISTS",
                "existing_draft_id": existing["id"]
            }

    # 5. 沿用合約編號，遞增期數
    target_branch_id = branch_id or old_contract.get("branch_id")
    old_contract_number = old_contract.get("contract_number")
    old_period = old_contract.get("contract_period") or 1
    new_period = old_period + 1

    # 6. 建立草稿合約
    try:
        new_contract_data = {
            "contract_number": old_contract_number,  # 沿用原編號
            "contract_period": new_period,           # 遞增期數
            "customer_id": old_contract.get("customer_id"),
            "branch_id": target_branch_id,
            "contract_type": old_contract.get("contract_type"),
            "plan_name": plan_name or old_contract.get("plan_name"),
            "start_date": new_start_date,
            "end_date": new_end_date,
            "monthly_rent": monthly_rent if monthly_rent is not None else old_contract.get("monthly_rent"),
            "original_price": original_price if original_price is not None else old_contract.get("original_price"),
            "deposit": deposit if deposit is not None else old_contract.get("deposit", 0),
            "payment_cycle": payment_cycle or old_contract.get("payment_cycle", "monthly"),
            "payment_day": payment_day or old_contract.get("payment_day", 5),
            "position_number": position_number or old_contract.get("position_number"),
            # 承租人資訊（沿用或覆蓋）
            "company_name": company_name or old_contract.get("company_name"),
            "representative_name": representative_name or old_contract.get("representative_name"),
            "representative_address": representative_address or old_contract.get("representative_address"),
            "id_number": id_number or old_contract.get("id_number"),
            "company_tax_id": company_tax_id or old_contract.get("company_tax_id"),
            "phone": phone or old_contract.get("phone"),
            "email": email or old_contract.get("email"),
            # 介紹人（沿用）
            "broker_name": old_contract.get("broker_name"),
            "broker_firm_id": old_contract.get("broker_firm_id"),
            "commission_eligible": False,  # 續約不再計算佣金
            # 關聯與狀態
            "renewed_from_id": contract_id,
            "status": "renewal_draft",  # ★ 草稿狀態
            "notes": notes or f"第 {new_period} 期（續約自第 {old_period} 期）"
        }

        result = await postgrest_post("contracts", new_contract_data)
        new_contract = result[0] if isinstance(result, list) else result

        # 7. 建立操作記錄
        await postgrest_post("renewal_operations", {
            "idempotency_key": idempotency_key,
            "old_contract_id": contract_id,
            "new_contract_id": new_contract["id"],
            "status": "draft",
            "created_by": created_by
        })

        return {
            "success": True,
            "draft_id": new_contract["id"],
            "draft": {
                "id": new_contract["id"],
                "contract_number": new_contract.get("contract_number"),
                "contract_period": new_period,
                "start_date": new_start_date,
                "end_date": new_end_date,
                "monthly_rent": new_contract.get("monthly_rent"),
                "payment_cycle": new_contract.get("payment_cycle"),
                "position_number": new_contract.get("position_number"),
                "status": "renewal_draft"
            },
            "old_contract": {
                "id": contract_id,
                "contract_number": old_contract.get("contract_number"),
                "contract_period": old_period,
                "end_date": old_contract.get("end_date")
            },
            "idempotency_key": idempotency_key,
            "message": f"續約草稿已建立（第 {new_period} 期），請確認後啟用"
        }

    except Exception as e:
        logger.error(f"renewal_create_draft error: {e}")
        return {"success": False, "error": str(e)}


async def renewal_update_draft(
    draft_id: int,
    # 可修改的欄位
    start_date: str = None,
    end_date: str = None,
    plan_name: str = None,
    monthly_rent: float = None,
    payment_cycle: str = None,
    payment_day: int = None,
    position_number: str = None,
    deposit: float = None,
    company_name: str = None,
    company_tax_id: str = None,
    representative_name: str = None,
    representative_address: str = None,
    notes: str = None
) -> Dict[str, Any]:
    """
    更新續約草稿

    只能更新 renewal_draft 狀態的合約
    """
    # 1. 取得草稿
    try:
        drafts = await postgrest_get("contracts", {
            "id": f"eq.{draft_id}"
        })
        if not drafts:
            return {"success": False, "error": "找不到續約草稿", "code": "NOT_FOUND"}

        draft = drafts[0]
    except Exception as e:
        return {"success": False, "error": str(e)}

    # 2. 驗證狀態
    if draft.get("status") != "renewal_draft":
        return {
            "success": False,
            "error": f"只能更新草稿狀態的合約，目前狀態為 {draft.get('status')}",
            "code": "INVALID_STATUS"
        }

    # 3. 建立更新資料
    update_data = {}
    if start_date is not None:
        update_data["start_date"] = start_date
    if end_date is not None:
        update_data["end_date"] = end_date
    if plan_name is not None:
        update_data["plan_name"] = plan_name
    if monthly_rent is not None:
        update_data["monthly_rent"] = monthly_rent
    if payment_cycle is not None:
        update_data["payment_cycle"] = payment_cycle
    if payment_day is not None:
        update_data["payment_day"] = payment_day
    if position_number is not None:
        update_data["position_number"] = position_number
    if deposit is not None:
        update_data["deposit"] = deposit
    if company_name is not None:
        update_data["company_name"] = company_name
    if company_tax_id is not None:
        update_data["company_tax_id"] = company_tax_id
    if representative_name is not None:
        update_data["representative_name"] = representative_name
    if representative_address is not None:
        update_data["representative_address"] = representative_address
    if notes is not None:
        update_data["notes"] = notes

    if not update_data:
        return {"success": False, "error": "沒有要更新的欄位"}

    update_data["updated_at"] = datetime.now().isoformat()

    # 4. 更新草稿
    try:
        await postgrest_patch("contracts", {"id": f"eq.{draft_id}"}, update_data)

        return {
            "success": True,
            "draft_id": draft_id,
            "updated_fields": list(update_data.keys()),
            "message": "續約草稿已更新"
        }

    except Exception as e:
        logger.error(f"renewal_update_draft error: {e}")
        return {"success": False, "error": str(e)}


async def renewal_activate(
    draft_id: int,
    activated_by: str = None
) -> Dict[str, Any]:
    """
    啟用續約草稿

    使用 PostgreSQL 函數執行，確保 Transaction 保護：
    1. 新合約 renewal_draft → active
    2. 舊合約 active → renewed
    3. 更新操作記錄

    全程在單一 Transaction 中，保證資料一致性
    """
    try:
        # 調用 PostgreSQL 函數
        result = await postgrest_rpc("activate_renewal", {
            "p_new_contract_id": draft_id,
            "p_activated_by": activated_by
        })

        if isinstance(result, dict):
            return result
        else:
            return {"success": False, "error": "啟用失敗", "result": result}

    except Exception as e:
        logger.error(f"renewal_activate error: {e}")
        return {"success": False, "error": str(e)}


async def renewal_cancel_draft(
    draft_id: int,
    reason: str = None
) -> Dict[str, Any]:
    """
    取消續約草稿

    只刪除草稿，不影響原合約
    """
    try:
        # 調用 PostgreSQL 函數
        result = await postgrest_rpc("cancel_renewal_draft", {
            "p_new_contract_id": draft_id,
            "p_reason": reason
        })

        if isinstance(result, dict):
            return result
        else:
            return {"success": False, "error": "取消失敗", "result": result}

    except Exception as e:
        logger.error(f"renewal_cancel_draft error: {e}")
        return {"success": False, "error": str(e)}


# ============================================================================
# 簽署流程管理
# ============================================================================

async def renewal_send_for_sign(
    contract_id: int,
    sent_by: str = None
) -> Dict[str, Any]:
    """
    送出合約簽署

    將合約狀態從 renewal_draft 改為 pending_sign，
    並記錄 sent_for_sign_at 時間。

    Args:
        contract_id: 合約 ID（必須是 renewal_draft 狀態）
        sent_by: 操作者

    Returns:
        更新結果
    """
    try:
        # 1. 取得合約
        contracts = await postgrest_get("contracts", {
            "id": f"eq.{contract_id}",
            "select": "id,contract_number,contract_period,status,sent_for_sign_at"
        })

        if not contracts:
            return {"success": False, "error": "找不到合約", "code": "NOT_FOUND"}

        contract = contracts[0]

        # 2. 驗證狀態
        if contract["status"] not in ["renewal_draft", "draft"]:
            return {
                "success": False,
                "error": f"只能送簽草稿狀態的合約，目前狀態為 {contract['status']}",
                "code": "INVALID_STATUS"
            }

        if contract.get("sent_for_sign_at"):
            return {
                "success": False,
                "error": "此合約已送簽",
                "code": "ALREADY_SENT",
                "sent_at": contract["sent_for_sign_at"]
            }

        # 3. 更新狀態
        now = datetime.now().isoformat()
        await postgrest_patch("contracts", {"id": f"eq.{contract_id}"}, {
            "status": "pending_sign",
            "sent_for_sign_at": now,
            "updated_at": now
        })

        return {
            "success": True,
            "contract_id": contract_id,
            "contract_number": contract["contract_number"],
            "contract_period": contract.get("contract_period"),
            "new_status": "pending_sign",
            "sent_for_sign_at": now,
            "sent_by": sent_by,
            "message": "合約已送出簽署，等待客戶回簽"
        }

    except Exception as e:
        logger.error(f"renewal_send_for_sign error: {e}")
        return {"success": False, "error": str(e)}


async def renewal_mark_signed(
    contract_id: int,
    signed_at: str = None,
    signed_by: str = None,
    auto_activate: bool = False
) -> Dict[str, Any]:
    """
    標記合約已簽回

    將合約狀態從 pending_sign 改為 signed，
    並記錄 signed_at 時間。

    如果 auto_activate=True，會自動啟用合約（signed → active）。

    Args:
        contract_id: 合約 ID（必須是 pending_sign 狀態）
        signed_at: 簽署時間（不填則用當前時間）
        signed_by: 操作者
        auto_activate: 是否自動啟用

    Returns:
        更新結果
    """
    try:
        # 1. 取得合約
        contracts = await postgrest_get("contracts", {
            "id": f"eq.{contract_id}",
            "select": "id,contract_number,contract_period,status,signed_at,renewed_from_id"
        })

        if not contracts:
            return {"success": False, "error": "找不到合約", "code": "NOT_FOUND"}

        contract = contracts[0]

        # 2. 驗證狀態
        valid_statuses = ["pending_sign", "renewal_draft", "draft"]
        if contract["status"] not in valid_statuses:
            return {
                "success": False,
                "error": f"只能標記待簽狀態的合約，目前狀態為 {contract['status']}",
                "code": "INVALID_STATUS"
            }

        if contract.get("signed_at"):
            return {
                "success": False,
                "error": "此合約已簽署",
                "code": "ALREADY_SIGNED",
                "signed_at": contract["signed_at"]
            }

        # 3. 決定目標狀態
        now = datetime.now().isoformat()
        sign_time = signed_at or now
        target_status = "active" if auto_activate else "signed"

        update_data = {
            "status": target_status,
            "signed_at": sign_time,
            "updated_at": now
        }

        # 如果沒送簽就直接簽回，補上 sent_for_sign_at
        if not contract.get("sent_for_sign_at"):
            update_data["sent_for_sign_at"] = sign_time

        # 4. 更新合約
        await postgrest_patch("contracts", {"id": f"eq.{contract_id}"}, update_data)

        # 5. 如果自動啟用，更新舊合約狀態
        if auto_activate and contract.get("renewed_from_id"):
            await postgrest_patch(
                "contracts",
                {"id": f"eq.{contract['renewed_from_id']}"},
                {"status": "renewed", "updated_at": now}
            )

        return {
            "success": True,
            "contract_id": contract_id,
            "contract_number": contract["contract_number"],
            "contract_period": contract.get("contract_period"),
            "new_status": target_status,
            "signed_at": sign_time,
            "signed_by": signed_by,
            "auto_activated": auto_activate,
            "message": f"合約已標記簽署完成，狀態為 {target_status}"
        }

    except Exception as e:
        logger.error(f"renewal_mark_signed error: {e}")
        return {"success": False, "error": str(e)}


# ============================================================================
# MCP 工具定義
# ============================================================================

RENEWAL_V3_TOOLS = [
    {
        "name": "renewal_check_draft",
        "description": "檢查合約是否有未完成的續約草稿",
        "inputSchema": {
            "type": "object",
            "properties": {
                "contract_id": {
                    "type": "integer",
                    "description": "原合約 ID"
                }
            },
            "required": ["contract_id"]
        }
    },
    {
        "name": "renewal_create_draft",
        "description": "建立續約草稿 - 草稿不會影響應收帳款，可隨時取消",
        "inputSchema": {
            "type": "object",
            "properties": {
                "contract_id": {
                    "type": "integer",
                    "description": "原合約 ID"
                },
                "new_start_date": {
                    "type": "string",
                    "description": "新合約開始日期 (YYYY-MM-DD)"
                },
                "new_end_date": {
                    "type": "string",
                    "description": "新合約結束日期 (YYYY-MM-DD)"
                },
                "monthly_rent": {
                    "type": "number",
                    "description": "月租金（不填則沿用原合約）"
                },
                "payment_cycle": {
                    "type": "string",
                    "enum": ["monthly", "quarterly", "semi_annual", "annual", "biennial"],
                    "description": "繳費週期（不填則沿用原合約）"
                },
                "position_number": {
                    "type": "string",
                    "description": "座位編號（可換座）"
                },
                "plan_name": {
                    "type": "string",
                    "description": "方案名稱（可換方案）"
                },
                "deposit": {
                    "type": "number",
                    "description": "押金（通常沿用）"
                },
                "company_name": {
                    "type": "string",
                    "description": "公司名稱"
                },
                "company_tax_id": {
                    "type": "string",
                    "description": "統一編號"
                },
                "notes": {
                    "type": "string",
                    "description": "備註"
                },
                "idempotency_key": {
                    "type": "string",
                    "description": "冪等性 Key（防止重複提交）"
                }
            },
            "required": ["contract_id", "new_start_date", "new_end_date"]
        }
    },
    {
        "name": "renewal_update_draft",
        "description": "更新續約草稿",
        "inputSchema": {
            "type": "object",
            "properties": {
                "draft_id": {
                    "type": "integer",
                    "description": "草稿合約 ID"
                },
                "start_date": {"type": "string"},
                "end_date": {"type": "string"},
                "monthly_rent": {"type": "number"},
                "payment_cycle": {"type": "string"},
                "position_number": {"type": "string"},
                "plan_name": {"type": "string"},
                "deposit": {"type": "number"},
                "company_name": {"type": "string"},
                "company_tax_id": {"type": "string"},
                "notes": {"type": "string"}
            },
            "required": ["draft_id"]
        }
    },
    {
        "name": "renewal_activate",
        "description": "啟用續約草稿 - 使用 Transaction 保護，確保資料一致性",
        "inputSchema": {
            "type": "object",
            "properties": {
                "draft_id": {
                    "type": "integer",
                    "description": "草稿合約 ID"
                },
                "activated_by": {
                    "type": "string",
                    "description": "操作者"
                }
            },
            "required": ["draft_id"]
        }
    },
    {
        "name": "renewal_cancel_draft",
        "description": "取消續約草稿 - 刪除草稿，不影響原合約",
        "inputSchema": {
            "type": "object",
            "properties": {
                "draft_id": {
                    "type": "integer",
                    "description": "草稿合約 ID"
                },
                "reason": {
                    "type": "string",
                    "description": "取消原因"
                }
            },
            "required": ["draft_id"]
        }
    },
    {
        "name": "renewal_send_for_sign",
        "description": "送出合約簽署 - 將草稿狀態改為待簽，開始追蹤回簽時間",
        "inputSchema": {
            "type": "object",
            "properties": {
                "contract_id": {
                    "type": "integer",
                    "description": "合約 ID（必須是草稿狀態）"
                },
                "sent_by": {
                    "type": "string",
                    "description": "送簽人"
                }
            },
            "required": ["contract_id"]
        }
    },
    {
        "name": "renewal_mark_signed",
        "description": "標記合約已簽回 - 可選擇自動啟用",
        "inputSchema": {
            "type": "object",
            "properties": {
                "contract_id": {
                    "type": "integer",
                    "description": "合約 ID（必須是待簽狀態）"
                },
                "signed_at": {
                    "type": "string",
                    "description": "簽署時間 (YYYY-MM-DD HH:MM:SS)，不填則用當前時間"
                },
                "signed_by": {
                    "type": "string",
                    "description": "簽署確認人"
                },
                "auto_activate": {
                    "type": "boolean",
                    "description": "是否自動啟用合約（預設 false）"
                }
            },
            "required": ["contract_id"]
        }
    }
]
