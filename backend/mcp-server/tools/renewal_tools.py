"""
續約流程管理工具
"""

from datetime import datetime
from typing import Optional
import logging

logger = logging.getLogger(__name__)

# 導入資料庫連接（將在 main.py 中設置）
postgrest_request = None

def set_postgrest_request(func):
    """設置 postgrest_request 函數"""
    global postgrest_request
    postgrest_request = func


# 有效的續約狀態
VALID_RENEWAL_STATUSES = [
    'none',       # 無需處理
    'notified',   # 已通知
    'confirmed',  # 已確認續約
    'paid',       # 已收款
    'invoiced',   # 已開發票
    'signed',     # 已簽約
    'completed'   # 完成
]

# 有效的發票狀態
VALID_INVOICE_STATUSES = [
    'pending_tax_id',    # 等待統編
    'issued_personal',   # 已開二聯
    'issued_business'    # 已開三聯
]


async def update_renewal_status(
    contract_id: int,
    renewal_status: str,
    notes: Optional[str] = None
) -> dict:
    """
    [V1 已棄用] 更新合約的續約狀態

    ⚠️ 此工具已完全停用（2025-12-31）
    renewal_* 欄位已從資料庫清除，此工具不再執行任何操作。

    替代方案：
    - 意願管理：使用 renewal_set_flag (notified/confirmed)
    - 收款：由 Payments 系統管理 (SSOT)
    - 簽約：由 renewal_create_draft + renewal_activate 管理
    """
    # V3 護欄：完全阻擋，不再執行
    logger.error(f"[V1 已停用] update_renewal_status 被呼叫但已停用，contract_id={contract_id}")

    return {
        "success": False,
        "error": "此工具已停用。renewal_* 欄位已從 SSOT 架構中移除。請使用 renewal_create_draft / renewal_activate 等 V3 工具。",
        "deprecated": True,
        "alternatives": [
            "renewal_set_flag - 設定意願標記",
            "renewal_create_draft - 建立續約草稿",
            "renewal_activate - 啟用續約合約"
        ]
    }



async def update_invoice_status(
    contract_id: int,
    invoice_status: str,
    notes: Optional[str] = None
) -> dict:
    """
    [V2 過渡期] 更新合約的發票狀態

    ⚠️ V3 設計中，發票狀態應由 Invoices 系統管理 (SSOT)
    此工具保留於過渡期使用，未來將由發票模組完全接管

    Args:
        contract_id: 合約 ID
        invoice_status: 發票狀態 (pending_tax_id/issued_personal/issued_business)
        notes: 備註

    Returns:
        更新結果
    """
    # V3 護欄：記錄使用情況（過渡期）
    logger.info(f"[V2 過渡期] update_invoice_status 被呼叫，contract_id={contract_id}，invoice_status={invoice_status}")

    if invoice_status not in VALID_INVOICE_STATUSES:
        return {
            "success": False,
            "error": f"無效的發票狀態: {invoice_status}。有效值: {', '.join(VALID_INVOICE_STATUSES)}"
        }

    update_data = {
        "invoice_status": invoice_status
    }

    if notes:
        update_data["renewal_notes"] = notes

    try:
        result = await postgrest_request(
            "PATCH",
            f"contracts?id=eq.{contract_id}",
            data=update_data,
            headers={"Prefer": "return=representation"}
        )

        return {
            "success": True,
            "contract_id": contract_id,
            "invoice_status": invoice_status
        }
    except Exception as e:
        logger.error(f"更新發票狀態失敗: {e}")
        return {
            "success": False,
            "error": str(e)
        }


async def get_renewal_status_summary(
    branch_id: Optional[int] = None
) -> dict:
    """
    [V1 已停用] 取得續約狀態統計

    ⚠️ 此工具已停用（2025-12-31）
    renewal_status 欄位已清除，請改用 v_renewal_dashboard_stats
    """
    logger.error(f"[V1 已停用] get_renewal_status_summary 被呼叫但已停用")

    return {
        "success": False,
        "error": "此工具已停用。請改用 v_renewal_dashboard_stats 視圖。",
        "deprecated": True,
        "alternative": "SELECT * FROM v_renewal_dashboard_stats"
    }


async def renewal_set_flag(
    contract_id: int,
    flag: str,
    value: bool,
    notes: Optional[str] = None
) -> dict:
    """
    設定或清除續約 Checklist 的 flag（使用時間戳作為事實來源）

    V3 設計：只允許設定意願管理 flag (notified/confirmed)
    paid/signed 由 SSOT 系統自動計算，不可手動設定

    Args:
        contract_id: 合約 ID
        flag: flag 名稱 (notified/confirmed)
        value: True = 設定, False = 清除
        notes: 備註

    Returns:
        更新結果，包含更新後的所有 flag 狀態
    """
    # V3 設計：只允許 notified 和 confirmed（意願管理）
    valid_flags = ['notified', 'confirmed']
    deprecated_flags = ['paid', 'signed']

    if flag in deprecated_flags:
        return {
            "success": False,
            "error": f"V3 設計：{flag} 不可手動設定，由 SSOT 系統自動計算"
        }

    if flag not in valid_flags:
        return {
            "success": False,
            "error": f"無效的 flag: {flag}。有效值: {', '.join(valid_flags)}"
        }

    # 時間戳欄位對應
    flag_to_timestamp = {
        'notified': 'renewal_notified_at',
        'confirmed': 'renewal_confirmed_at'
    }

    now = datetime.now().isoformat()
    update_data = {}

    if value:
        # 設定 flag：寫入時間戳
        update_data[flag_to_timestamp[flag]] = now
    else:
        # 清除 flag：設為 null
        update_data[flag_to_timestamp[flag]] = None

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

        # 取得更新後的完整狀態（V3：只取意願欄位）
        result = await postgrest_request(
            "GET",
            f"contracts?id=eq.{contract_id}&select=id,contract_number,renewal_notified_at,renewal_confirmed_at"
        )

        if result:
            contract = result[0]
            # V3 設計：只回傳意願管理 flags
            intent_flags = {
                "is_notified": bool(contract.get('renewal_notified_at')),
                "is_confirmed": bool(contract.get('renewal_confirmed_at'))
            }

            return {
                "success": True,
                "contract_id": contract_id,
                "contract_number": contract.get('contract_number'),
                "flag_updated": flag,
                "new_value": value,
                "intent_flags": intent_flags,  # V3: 只回傳意願 flags
                "updated_at": now,
                "note": "V3 設計：paid/signed/invoiced 狀態由 SSOT 視圖提供"
            }

        return {
            "success": True,
            "contract_id": contract_id,
            "flag_updated": flag,
            "new_value": value,
            "updated_at": now
        }

    except Exception as e:
        logger.error(f"更新續約 flag 失敗: {e}")
        return {
            "success": False,
            "error": str(e)
        }


async def batch_update_renewal_status(
    contract_ids: list,
    renewal_status: str,
    notes: Optional[str] = None
) -> dict:
    """
    [V1 已停用] 批次更新多個合約的續約狀態

    ⚠️ 此工具已完全停用（2025-12-31）
    renewal_* 欄位已從資料庫清除。
    """
    logger.error(f"[V1 已停用] batch_update_renewal_status 被呼叫但已停用")

    return {
        "success": False,
        "error": "此工具已停用。renewal_* 欄位已從 SSOT 架構中移除。",
        "deprecated": True
    }

