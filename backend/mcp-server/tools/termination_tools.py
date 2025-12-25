"""
解約流程管理工具
處理提前解約、退租、不續約等情況
"""

from datetime import datetime, date
from typing import Optional
import logging

logger = logging.getLogger(__name__)

# 導入資料庫連接（將在 main.py 中設置）
postgrest_request = None

def set_postgrest_request(func):
    """設置 postgrest_request 函數"""
    global postgrest_request
    postgrest_request = func


# 有效的解約狀態
VALID_TERMINATION_STATUSES = [
    'notice_received',    # 客戶已通知
    'moving_out',         # 搬遷中
    'pending_doc',        # 等待公文
    'pending_settlement', # 押金結算中
    'completed',          # 已完成
    'cancelled'           # 已取消（客戶反悔續租）
]

# 有效的解約類型
VALID_TERMINATION_TYPES = [
    'early',           # 提前解約
    'not_renewing',    # 到期不續約
    'breach'           # 違約終止
]

# Checklist 項目
CHECKLIST_ITEMS = [
    'notice_confirmed',      # 解約通知已確認
    'belongings_removed',    # 物品已搬離
    'keys_returned',         # 鑰匙已歸還
    'room_inspected',        # 房間已檢查
    'doc_submitted',         # 公文已送件
    'doc_approved',          # 公文已核准
    'settlement_calculated', # 押金已結算
    'refund_processed'       # 押金已退還
]


async def create_termination_case(
    contract_id: int,
    termination_type: str = 'not_renewing',
    notice_date: Optional[str] = None,
    expected_end_date: Optional[str] = None,
    notes: Optional[str] = None,
    created_by: Optional[str] = None
) -> dict:
    """
    建立解約案件

    Args:
        contract_id: 合約 ID
        termination_type: 解約類型 (early/not_renewing/breach)
        notice_date: 客戶通知日期 (YYYY-MM-DD)
        expected_end_date: 預計搬離日期 (YYYY-MM-DD)
        notes: 備註
        created_by: 建立者

    Returns:
        建立結果
    """
    if termination_type not in VALID_TERMINATION_TYPES:
        return {
            "success": False,
            "error": f"無效的解約類型: {termination_type}。有效值: {', '.join(VALID_TERMINATION_TYPES)}"
        }

    try:
        # 先取得合約資訊
        contract_result = await postgrest_request(
            "GET",
            f"contracts?id=eq.{contract_id}&select=id,contract_number,end_date,monthly_rent,deposit,status"
        )

        if not contract_result:
            return {
                "success": False,
                "error": f"找不到合約 ID: {contract_id}"
            }

        contract = contract_result[0]

        # 檢查是否已有進行中的解約案件
        existing = await postgrest_request(
            "GET",
            f"termination_cases?contract_id=eq.{contract_id}&status=not.in.(completed,cancelled)"
        )

        if existing:
            return {
                "success": False,
                "error": f"合約已有進行中的解約案件 (ID: {existing[0]['id']})"
            }

        # 計算日租金
        monthly_rent = float(contract.get('monthly_rent', 0))
        daily_rate = round(monthly_rent / 30, 2)
        deposit = float(contract.get('deposit', 0))

        # 建立解約案件
        case_data = {
            "contract_id": contract_id,
            "termination_type": termination_type,
            "status": "notice_received",
            "notice_date": notice_date or datetime.now().strftime('%Y-%m-%d'),
            "expected_end_date": expected_end_date or contract.get('end_date'),
            "deposit_amount": deposit,
            "daily_rate": daily_rate,
            "notes": notes,
            "created_by": created_by
        }

        result = await postgrest_request(
            "POST",
            "termination_cases",
            data=case_data,
            headers={"Prefer": "return=representation"}
        )

        if result:
            case = result[0]

            # 更新合約狀態為 pending_termination
            await postgrest_request(
                "PATCH",
                f"contracts?id=eq.{contract_id}",
                data={"status": "pending_termination"}
            )

            return {
                "success": True,
                "case_id": case['id'],
                "contract_id": contract_id,
                "contract_number": contract.get('contract_number'),
                "termination_type": termination_type,
                "status": "notice_received",
                "deposit_amount": deposit,
                "daily_rate": daily_rate,
                "message": f"解約案件已建立，合約 {contract.get('contract_number')} 狀態已更新為「解約中」"
            }

        return {"success": False, "error": "建立解約案件失敗"}

    except Exception as e:
        logger.error(f"建立解約案件失敗: {e}")
        return {"success": False, "error": str(e)}


async def update_termination_status(
    case_id: int,
    status: str,
    notes: Optional[str] = None
) -> dict:
    """
    更新解約案件狀態

    Args:
        case_id: 解約案件 ID
        status: 新狀態 (notice_received/moving_out/pending_doc/pending_settlement/completed/cancelled)
        notes: 備註

    Returns:
        更新結果
    """
    if status not in VALID_TERMINATION_STATUSES:
        return {
            "success": False,
            "error": f"無效的狀態: {status}。有效值: {', '.join(VALID_TERMINATION_STATUSES)}"
        }

    update_data = {"status": status}

    if notes:
        update_data["notes"] = notes

    # 狀態特定的更新
    if status == 'cancelled':
        update_data["cancelled_at"] = datetime.now().isoformat()
    elif status == 'completed':
        update_data["refund_date"] = datetime.now().strftime('%Y-%m-%d')

    try:
        result = await postgrest_request(
            "PATCH",
            f"termination_cases?id=eq.{case_id}",
            data=update_data,
            headers={"Prefer": "return=representation"}
        )

        if result:
            case = result[0]

            # 如果完成或取消，更新合約狀態
            if status == 'completed':
                await postgrest_request(
                    "PATCH",
                    f"contracts?id=eq.{case['contract_id']}",
                    data={"status": "terminated"}
                )
            elif status == 'cancelled':
                await postgrest_request(
                    "PATCH",
                    f"contracts?id=eq.{case['contract_id']}",
                    data={"status": "active"}
                )

            return {
                "success": True,
                "case_id": case_id,
                "new_status": status,
                "contract_status_updated": status in ['completed', 'cancelled']
            }

        return {"success": False, "error": f"找不到解約案件 ID: {case_id}"}

    except Exception as e:
        logger.error(f"更新解約狀態失敗: {e}")
        return {"success": False, "error": str(e)}


async def update_termination_checklist(
    case_id: int,
    item: str,
    value: bool
) -> dict:
    """
    更新解約案件的 Checklist 項目

    Args:
        case_id: 解約案件 ID
        item: Checklist 項目名稱
        value: True = 已完成, False = 未完成

    Returns:
        更新結果
    """
    if item not in CHECKLIST_ITEMS:
        return {
            "success": False,
            "error": f"無效的 Checklist 項目: {item}。有效值: {', '.join(CHECKLIST_ITEMS)}"
        }

    try:
        # 取得現有 checklist
        result = await postgrest_request(
            "GET",
            f"termination_cases?id=eq.{case_id}&select=id,checklist,status"
        )

        if not result:
            return {"success": False, "error": f"找不到解約案件 ID: {case_id}"}

        case = result[0]
        checklist = case.get('checklist', {})

        # 更新項目
        checklist[item] = value

        # 更新資料庫
        await postgrest_request(
            "PATCH",
            f"termination_cases?id=eq.{case_id}",
            data={"checklist": checklist}
        )

        # 計算進度
        completed_count = sum(1 for v in checklist.values() if v)

        # 自動更新相關日期
        date_updates = {}
        if item == 'doc_submitted' and value:
            date_updates["doc_submitted_date"] = datetime.now().strftime('%Y-%m-%d')
        elif item == 'doc_approved' and value:
            date_updates["doc_approved_date"] = datetime.now().strftime('%Y-%m-%d')
        elif item == 'refund_processed' and value:
            date_updates["refund_date"] = datetime.now().strftime('%Y-%m-%d')

        if date_updates:
            await postgrest_request(
                "PATCH",
                f"termination_cases?id=eq.{case_id}",
                data=date_updates
            )

        return {
            "success": True,
            "case_id": case_id,
            "item": item,
            "value": value,
            "checklist": checklist,
            "progress": completed_count,
            "total_items": len(CHECKLIST_ITEMS)
        }

    except Exception as e:
        logger.error(f"更新 Checklist 失敗: {e}")
        return {"success": False, "error": str(e)}


async def calculate_deposit_settlement(
    case_id: int,
    doc_approved_date: str,
    other_deductions: float = 0,
    other_deduction_notes: Optional[str] = None
) -> dict:
    """
    計算押金結算

    Args:
        case_id: 解約案件 ID
        doc_approved_date: 公文核准日期 (YYYY-MM-DD)
        other_deductions: 其他扣款（清潔費、損壞等）
        other_deduction_notes: 其他扣款說明

    Returns:
        結算結果
    """
    try:
        # 取得解約案件和合約資訊
        result = await postgrest_request(
            "GET",
            f"v_termination_cases?id=eq.{case_id}"
        )

        if not result:
            return {"success": False, "error": f"找不到解約案件 ID: {case_id}"}

        case = result[0]

        # 解析日期
        contract_end_date = datetime.strptime(case['contract_end_date'], '%Y-%m-%d').date()
        doc_date = datetime.strptime(doc_approved_date, '%Y-%m-%d').date()

        # 計算扣除天數（公文核准日 - 合約到期日）
        deduction_days = max(0, (doc_date - contract_end_date).days)

        # 計算金額
        daily_rate = float(case.get('daily_rate', 0)) or round(float(case.get('monthly_rent', 0)) / 30, 2)
        deposit_amount = float(case.get('deposit_amount', 0)) or float(case.get('contract_deposit', 0))
        deduction_amount = deduction_days * daily_rate
        refund_amount = deposit_amount - deduction_amount - other_deductions

        # 更新解約案件
        update_data = {
            "doc_approved_date": doc_approved_date,
            "deduction_days": deduction_days,
            "daily_rate": daily_rate,
            "deduction_amount": deduction_amount,
            "other_deductions": other_deductions,
            "other_deduction_notes": other_deduction_notes,
            "refund_amount": max(0, refund_amount),  # 確保不是負數
            "settlement_date": datetime.now().strftime('%Y-%m-%d'),
            "status": "pending_settlement"
        }

        # 更新 checklist
        checklist = case.get('checklist', {})
        checklist['doc_approved'] = True
        checklist['settlement_calculated'] = True
        update_data["checklist"] = checklist

        await postgrest_request(
            "PATCH",
            f"termination_cases?id=eq.{case_id}",
            data=update_data
        )

        return {
            "success": True,
            "case_id": case_id,
            "contract_number": case.get('contract_number'),
            "customer_name": case.get('customer_name'),
            "settlement": {
                "contract_end_date": case['contract_end_date'],
                "doc_approved_date": doc_approved_date,
                "deduction_days": deduction_days,
                "daily_rate": daily_rate,
                "deposit_amount": deposit_amount,
                "deduction_amount": deduction_amount,
                "other_deductions": other_deductions,
                "other_deduction_notes": other_deduction_notes,
                "refund_amount": max(0, refund_amount)
            },
            "message": f"押金結算完成：原押金 ${deposit_amount:,.0f} - 扣除 {deduction_days} 天 (${deduction_amount:,.0f}) - 其他扣款 (${other_deductions:,.0f}) = 退還 ${max(0, refund_amount):,.0f}"
        }

    except Exception as e:
        logger.error(f"計算押金結算失敗: {e}")
        return {"success": False, "error": str(e)}


async def process_refund(
    case_id: int,
    refund_method: str,
    refund_account: Optional[str] = None,
    refund_receipt: Optional[str] = None,
    notes: Optional[str] = None
) -> dict:
    """
    處理押金退還

    Args:
        case_id: 解約案件 ID
        refund_method: 退款方式 (cash/transfer/check)
        refund_account: 退款帳戶（匯款時）
        refund_receipt: 收據編號
        notes: 備註

    Returns:
        處理結果
    """
    valid_methods = ['cash', 'transfer', 'check']
    if refund_method not in valid_methods:
        return {
            "success": False,
            "error": f"無效的退款方式: {refund_method}。有效值: {', '.join(valid_methods)}"
        }

    try:
        # 取得解約案件
        result = await postgrest_request(
            "GET",
            f"v_termination_cases?id=eq.{case_id}"
        )

        if not result:
            return {"success": False, "error": f"找不到解約案件 ID: {case_id}"}

        case = result[0]

        if not case.get('refund_amount'):
            return {
                "success": False,
                "error": "請先執行押金結算 (calculate_deposit_settlement)"
            }

        # 更新解約案件
        update_data = {
            "refund_method": refund_method,
            "refund_account": refund_account,
            "refund_receipt": refund_receipt,
            "refund_date": datetime.now().strftime('%Y-%m-%d'),
            "status": "completed"
        }

        if notes:
            update_data["notes"] = (case.get('notes', '') or '') + f"\n退款備註: {notes}"

        # 更新 checklist
        checklist = case.get('checklist', {})
        checklist['refund_processed'] = True
        update_data["checklist"] = checklist

        await postgrest_request(
            "PATCH",
            f"termination_cases?id=eq.{case_id}",
            data=update_data
        )

        # 更新合約狀態為已終止
        await postgrest_request(
            "PATCH",
            f"contracts?id=eq.{case['contract_id']}",
            data={"status": "terminated"}
        )

        refund_method_labels = {
            'cash': '現金',
            'transfer': '匯款',
            'check': '支票'
        }

        return {
            "success": True,
            "case_id": case_id,
            "contract_number": case.get('contract_number'),
            "customer_name": case.get('customer_name'),
            "refund_amount": case.get('refund_amount'),
            "refund_method": refund_method,
            "refund_method_label": refund_method_labels.get(refund_method),
            "refund_date": update_data["refund_date"],
            "message": f"解約完成！已退還押金 ${case.get('refund_amount'):,.0f} ({refund_method_labels.get(refund_method)})"
        }

    except Exception as e:
        logger.error(f"處理退款失敗: {e}")
        return {"success": False, "error": str(e)}


async def get_termination_cases(
    branch_id: Optional[int] = None,
    status: Optional[str] = None,
    include_completed: bool = False
) -> dict:
    """
    取得解約案件列表

    Args:
        branch_id: 場館 ID（可選）
        status: 狀態過濾（可選）
        include_completed: 是否包含已完成的案件

    Returns:
        解約案件列表
    """
    try:
        params = {}

        if branch_id:
            params["branch_id"] = f"eq.{branch_id}"

        if status:
            if status not in VALID_TERMINATION_STATUSES:
                return {
                    "success": False,
                    "error": f"無效的狀態: {status}"
                }
            params["status"] = f"eq.{status}"
        elif not include_completed:
            params["status"] = "not.in.(completed,cancelled)"

        result = await postgrest_request(
            "GET",
            "v_termination_cases",
            params=params
        )

        return {
            "success": True,
            "cases": result or [],
            "count": len(result or [])
        }

    except Exception as e:
        logger.error(f"取得解約案件失敗: {e}")
        return {"success": False, "error": str(e)}


async def get_termination_case(case_id: int) -> dict:
    """
    取得單一解約案件詳情

    Args:
        case_id: 解約案件 ID

    Returns:
        解約案件詳情
    """
    try:
        result = await postgrest_request(
            "GET",
            f"v_termination_cases?id=eq.{case_id}"
        )

        if not result:
            return {"success": False, "error": f"找不到解約案件 ID: {case_id}"}

        return {
            "success": True,
            "case": result[0]
        }

    except Exception as e:
        logger.error(f"取得解約案件失敗: {e}")
        return {"success": False, "error": str(e)}


async def cancel_termination_case(
    case_id: int,
    reason: str
) -> dict:
    """
    取消解約案件（客戶反悔決定續租）

    Args:
        case_id: 解約案件 ID
        reason: 取消原因

    Returns:
        取消結果
    """
    if not reason or not reason.strip():
        return {"success": False, "error": "請提供取消原因"}

    try:
        result = await postgrest_request(
            "GET",
            f"termination_cases?id=eq.{case_id}&select=id,contract_id,status"
        )

        if not result:
            return {"success": False, "error": f"找不到解約案件 ID: {case_id}"}

        case = result[0]

        if case['status'] in ['completed', 'cancelled']:
            return {
                "success": False,
                "error": f"無法取消狀態為「{case['status']}」的案件"
            }

        # 更新解約案件
        await postgrest_request(
            "PATCH",
            f"termination_cases?id=eq.{case_id}",
            data={
                "status": "cancelled",
                "cancelled_at": datetime.now().isoformat(),
                "cancel_reason": reason.strip()
            }
        )

        # 恢復合約狀態為 active
        await postgrest_request(
            "PATCH",
            f"contracts?id=eq.{case['contract_id']}",
            data={"status": "active"}
        )

        return {
            "success": True,
            "case_id": case_id,
            "message": "解約案件已取消，合約狀態已恢復為「生效中」"
        }

    except Exception as e:
        logger.error(f"取消解約案件失敗: {e}")
        return {"success": False, "error": str(e)}


# MCP 工具定義
TERMINATION_TOOLS = [
    {
        "name": "termination_create_case",
        "description": "建立解約案件 - 當客戶通知要解約時使用",
        "inputSchema": {
            "type": "object",
            "properties": {
                "contract_id": {
                    "type": "integer",
                    "description": "合約 ID"
                },
                "termination_type": {
                    "type": "string",
                    "enum": ["early", "not_renewing", "breach"],
                    "description": "解約類型：early=提前解約, not_renewing=到期不續約, breach=違約終止"
                },
                "notice_date": {
                    "type": "string",
                    "description": "客戶通知日期 (YYYY-MM-DD)"
                },
                "expected_end_date": {
                    "type": "string",
                    "description": "預計搬離日期 (YYYY-MM-DD)"
                },
                "notes": {
                    "type": "string",
                    "description": "備註"
                }
            },
            "required": ["contract_id"]
        }
    },
    {
        "name": "termination_update_status",
        "description": "更新解約案件狀態",
        "inputSchema": {
            "type": "object",
            "properties": {
                "case_id": {
                    "type": "integer",
                    "description": "解約案件 ID"
                },
                "status": {
                    "type": "string",
                    "enum": ["notice_received", "moving_out", "pending_doc", "pending_settlement", "completed", "cancelled"],
                    "description": "新狀態"
                },
                "notes": {
                    "type": "string",
                    "description": "備註"
                }
            },
            "required": ["case_id", "status"]
        }
    },
    {
        "name": "termination_update_checklist",
        "description": "更新解約案件的 Checklist 項目",
        "inputSchema": {
            "type": "object",
            "properties": {
                "case_id": {
                    "type": "integer",
                    "description": "解約案件 ID"
                },
                "item": {
                    "type": "string",
                    "enum": ["notice_confirmed", "belongings_removed", "keys_returned", "room_inspected", "doc_submitted", "doc_approved", "settlement_calculated", "refund_processed"],
                    "description": "Checklist 項目"
                },
                "value": {
                    "type": "boolean",
                    "description": "是否已完成"
                }
            },
            "required": ["case_id", "item", "value"]
        }
    },
    {
        "name": "termination_calculate_settlement",
        "description": "計算押金結算 - 根據公文核准日計算應扣除的天數和金額",
        "inputSchema": {
            "type": "object",
            "properties": {
                "case_id": {
                    "type": "integer",
                    "description": "解約案件 ID"
                },
                "doc_approved_date": {
                    "type": "string",
                    "description": "公文核准日期 (YYYY-MM-DD)"
                },
                "other_deductions": {
                    "type": "number",
                    "description": "其他扣款金額（清潔費、損壞等）"
                },
                "other_deduction_notes": {
                    "type": "string",
                    "description": "其他扣款說明"
                }
            },
            "required": ["case_id", "doc_approved_date"]
        }
    },
    {
        "name": "termination_process_refund",
        "description": "處理押金退還 - 完成解約流程",
        "inputSchema": {
            "type": "object",
            "properties": {
                "case_id": {
                    "type": "integer",
                    "description": "解約案件 ID"
                },
                "refund_method": {
                    "type": "string",
                    "enum": ["cash", "transfer", "check"],
                    "description": "退款方式：cash=現金, transfer=匯款, check=支票"
                },
                "refund_account": {
                    "type": "string",
                    "description": "退款帳戶（匯款時需要）"
                },
                "refund_receipt": {
                    "type": "string",
                    "description": "收據編號"
                },
                "notes": {
                    "type": "string",
                    "description": "備註"
                }
            },
            "required": ["case_id", "refund_method"]
        }
    },
    {
        "name": "termination_get_cases",
        "description": "取得解約案件列表",
        "inputSchema": {
            "type": "object",
            "properties": {
                "branch_id": {
                    "type": "integer",
                    "description": "場館 ID（可選）"
                },
                "status": {
                    "type": "string",
                    "enum": ["notice_received", "moving_out", "pending_doc", "pending_settlement", "completed", "cancelled"],
                    "description": "狀態過濾（可選）"
                },
                "include_completed": {
                    "type": "boolean",
                    "description": "是否包含已完成的案件"
                }
            }
        }
    },
    {
        "name": "termination_get_case",
        "description": "取得單一解約案件詳情",
        "inputSchema": {
            "type": "object",
            "properties": {
                "case_id": {
                    "type": "integer",
                    "description": "解約案件 ID"
                }
            },
            "required": ["case_id"]
        }
    },
    {
        "name": "termination_cancel_case",
        "description": "取消解約案件 - 當客戶反悔決定續租時使用",
        "inputSchema": {
            "type": "object",
            "properties": {
                "case_id": {
                    "type": "integer",
                    "description": "解約案件 ID"
                },
                "reason": {
                    "type": "string",
                    "description": "取消原因"
                }
            },
            "required": ["case_id", "reason"]
        }
    }
]
