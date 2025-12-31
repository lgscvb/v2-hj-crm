"""
intent_tools.py - 續約意願管理工具

管理續約意願線（Intent Line）：
- renewal_notified_at：是否已發送續約通知
- renewal_confirmed_at：是否已確認續約意願

與交易線（Transaction Line）分離：
- 交易線由 SSOT 系統管理（payment/invoice/signing 狀態）
- 意願線由本模組管理

設計原則：
1. 前端透過 View (v_renewal_intent) 讀取意願狀態
2. 前端透過本模組的 Tool 設定意願
3. 為未來可能的 renewal_intent 獨立表預留空間

Date: 2025-12-31
"""

from datetime import datetime
from typing import Optional
from .postgrest_client import postgrest_request


# ============================================================================
# 意願 Flag 設定
# ============================================================================

async def set_renewal_intent(
    contract_id: int,
    intent_type: str,
    value: bool,
    notes: Optional[str] = None
) -> dict:
    """
    設定或清除續約意願 flag

    Args:
        contract_id: 合約 ID
        intent_type: 意願類型
            - 'notified': 已發送續約通知
            - 'confirmed': 已確認續約意願
        value: True = 設定, False = 清除
        notes: 備註（可選）

    Returns:
        {
            "success": True/False,
            "contract_id": int,
            "contract_number": str,
            "intent": {
                "is_notified": bool,
                "is_confirmed": bool,
                "notified_at": str or None,
                "confirmed_at": str or None
            },
            "message": str
        }

    Note:
        paid/signed 由 SSOT 系統自動計算，不可透過本工具設定
    """
    # 有效的意願類型
    valid_intents = ['notified', 'confirmed']

    # 已棄用的 flag（屬於交易線，由 SSOT 管理）
    transaction_flags = ['paid', 'signed']

    if intent_type in transaction_flags:
        return {
            "success": False,
            "error": f"'{intent_type}' 屬於交易線，由 SSOT 系統自動計算，不可手動設定",
            "hint": "請透過 payment/invoice 工具操作，狀態會自動更新"
        }

    if intent_type not in valid_intents:
        return {
            "success": False,
            "error": f"無效的意願類型: {intent_type}",
            "valid_types": valid_intents
        }

    # 意願類型對應的資料庫欄位
    intent_to_column = {
        'notified': 'renewal_notified_at',
        'confirmed': 'renewal_confirmed_at'
    }

    # 準備更新資料
    now = datetime.now().isoformat()
    update_data = {}

    if value:
        update_data[intent_to_column[intent_type]] = now
    else:
        update_data[intent_to_column[intent_type]] = None

    if notes:
        update_data["renewal_notes"] = notes

    try:
        # 更新資料庫
        await postgrest_request(
            "PATCH",
            f"contracts?id=eq.{contract_id}",
            data=update_data,
            headers={"Prefer": "return=representation"}
        )

        # 從 View 讀取更新後的狀態
        result = await postgrest_request(
            "GET",
            f"v_renewal_intent?contract_id=eq.{contract_id}"
        )

        if not result:
            return {
                "success": False,
                "error": f"找不到合約 ID: {contract_id}"
            }

        intent_data = result[0]

        action = "設定" if value else "清除"
        intent_label = "通知" if intent_type == 'notified' else "確認"

        return {
            "success": True,
            "contract_id": contract_id,
            "contract_number": intent_data.get('contract_number'),
            "intent": {
                "is_notified": intent_data.get('is_notified', False),
                "is_confirmed": intent_data.get('is_confirmed', False),
                "notified_at": intent_data.get('renewal_notified_at'),
                "confirmed_at": intent_data.get('renewal_confirmed_at')
            },
            "message": f"已{action}續約{intent_label}"
        }

    except Exception as e:
        return {
            "success": False,
            "error": str(e)
        }


# ============================================================================
# 批次操作
# ============================================================================

async def batch_set_renewal_intent(
    contract_ids: list,
    intent_type: str,
    value: bool,
    notes: Optional[str] = None
) -> dict:
    """
    批次設定續約意願 flag

    Args:
        contract_ids: 合約 ID 列表
        intent_type: 意願類型 ('notified' / 'confirmed')
        value: True = 設定, False = 清除
        notes: 備註（可選）

    Returns:
        {
            "success": True,
            "total": int,
            "succeeded": int,
            "failed": int,
            "results": [...]
        }
    """
    results = []
    succeeded = 0
    failed = 0

    for contract_id in contract_ids:
        result = await set_renewal_intent(contract_id, intent_type, value, notes)
        results.append({
            "contract_id": contract_id,
            "success": result.get("success", False),
            "message": result.get("message") or result.get("error")
        })

        if result.get("success"):
            succeeded += 1
        else:
            failed += 1

    return {
        "success": failed == 0,
        "total": len(contract_ids),
        "succeeded": succeeded,
        "failed": failed,
        "results": results
    }


# ============================================================================
# 查詢
# ============================================================================

async def get_renewal_intent(contract_id: int) -> dict:
    """
    取得合約的續約意願狀態

    Args:
        contract_id: 合約 ID

    Returns:
        v_renewal_intent View 的完整資料
    """
    try:
        result = await postgrest_request(
            "GET",
            f"v_renewal_intent?contract_id=eq.{contract_id}"
        )

        if not result:
            return {
                "success": False,
                "error": f"找不到合約 ID: {contract_id}"
            }

        return {
            "success": True,
            "data": result[0]
        }

    except Exception as e:
        return {
            "success": False,
            "error": str(e)
        }


async def list_pending_intents(
    intent_type: str = 'notified',
    limit: int = 50
) -> dict:
    """
    列出待處理的續約意願

    Args:
        intent_type: 要查詢的意願類型
            - 'notified': 尚未通知的合約
            - 'confirmed': 已通知但尚未確認的合約
        limit: 回傳筆數上限

    Returns:
        待處理的合約列表
    """
    try:
        if intent_type == 'notified':
            # 尚未通知：可續約 + 未通知
            result = await postgrest_request(
                "GET",
                f"v_renewal_intent?is_renewable=eq.true&is_notified=eq.false&order=days_until_expiry.asc&limit={limit}"
            )
        elif intent_type == 'confirmed':
            # 待確認：可續約 + 已通知 + 未確認
            result = await postgrest_request(
                "GET",
                f"v_renewal_intent?is_renewable=eq.true&is_notified=eq.true&is_confirmed=eq.false&order=days_until_expiry.asc&limit={limit}"
            )
        else:
            return {
                "success": False,
                "error": f"無效的意願類型: {intent_type}",
                "valid_types": ['notified', 'confirmed']
            }

        return {
            "success": True,
            "intent_type": intent_type,
            "count": len(result),
            "data": result
        }

    except Exception as e:
        return {
            "success": False,
            "error": str(e)
        }
