"""
解約流程管理工具 V2 - 使用 PostgreSQL Function 確保 Transaction 保護

修復的問題（來自 PRD-v2.5）：
- create_termination_case: 先建案件、再更新合約 → 使用 create_termination_case_atomic
- update_termination_status: 先更新案件、再更新合約 → 使用 update_termination_status_atomic
- process_refund: 先更新案件、再更新合約 → 使用 complete_termination_atomic
- cancel_termination_case: 先更新案件、再恢復合約 → 使用 cancel_termination_case_atomic
"""

from datetime import datetime
from typing import Optional
import logging

logger = logging.getLogger(__name__)

# 導入資料庫連接（將在 main.py 中設置）
postgrest_request = None
postgrest_rpc = None


def set_postgrest_request(func):
    """設置 postgrest_request 函數"""
    global postgrest_request
    postgrest_request = func


def set_postgrest_rpc(func):
    """設置 postgrest_rpc 函數（用於呼叫 PostgreSQL Function）"""
    global postgrest_rpc
    postgrest_rpc = func


# ============================================================================
# V2 工具：使用 PostgreSQL Function 確保 Transaction
# ============================================================================

async def termination_create_case_v2(
    contract_id: int,
    termination_type: str = 'not_renewing',
    notice_date: Optional[str] = None,
    expected_end_date: Optional[str] = None,
    notes: Optional[str] = None,
    created_by: Optional[str] = None
) -> dict:
    """
    建立解約案件（V2：使用 Transaction 保護）

    使用 PostgreSQL Function 確保：
    1. 建立解約案件
    2. 更新合約狀態為 pending_termination

    兩個操作在同一 Transaction 內，要麼全成功、要麼全失敗
    """
    try:
        result = await postgrest_rpc(
            "create_termination_case_atomic",
            {
                "p_contract_id": contract_id,
                "p_termination_type": termination_type,
                "p_notice_date": notice_date,
                "p_expected_end_date": expected_end_date,
                "p_notes": notes,
                "p_created_by": created_by
            }
        )
        return result

    except Exception as e:
        logger.error(f"建立解約案件失敗: {e}")
        return {"success": False, "error": str(e)}


async def termination_complete_v2(
    case_id: int,
    refund_method: str,
    refund_account: Optional[str] = None,
    refund_receipt: Optional[str] = None,
    notes: Optional[str] = None
) -> dict:
    """
    完成解約流程（V2：使用 Transaction 保護）

    使用 PostgreSQL Function 確保：
    1. 更新解約案件狀態為 completed
    2. 更新合約狀態為 terminated
    3. 取消所有待繳款項

    三個操作在同一 Transaction 內，要麼全成功、要麼全失敗
    """
    valid_methods = ['cash', 'transfer', 'check']
    if refund_method not in valid_methods:
        return {
            "success": False,
            "error": f"無效的退款方式: {refund_method}。有效值: {', '.join(valid_methods)}",
            "code": "INVALID_REFUND_METHOD"
        }

    try:
        result = await postgrest_rpc(
            "complete_termination_atomic",
            {
                "p_case_id": case_id,
                "p_refund_method": refund_method,
                "p_refund_account": refund_account,
                "p_refund_receipt": refund_receipt,
                "p_notes": notes
            }
        )
        return result

    except Exception as e:
        logger.error(f"完成解約失敗: {e}")
        return {"success": False, "error": str(e)}


async def termination_cancel_v2(
    case_id: int,
    reason: str
) -> dict:
    """
    取消解約案件（V2：使用 Transaction 保護）

    使用 PostgreSQL Function 確保：
    1. 更新解約案件狀態為 cancelled
    2. 恢復合約狀態為 active

    兩個操作在同一 Transaction 內，要麼全成功、要麼全失敗
    """
    try:
        result = await postgrest_rpc(
            "cancel_termination_case_atomic",
            {
                "p_case_id": case_id,
                "p_reason": reason
            }
        )
        return result

    except Exception as e:
        logger.error(f"取消解約案件失敗: {e}")
        return {"success": False, "error": str(e)}


async def termination_update_status_v2(
    case_id: int,
    status: str,
    notes: Optional[str] = None
) -> dict:
    """
    更新解約案件狀態（V2：使用 Transaction 保護）

    注意：如果要 complete 或 cancel，請使用專用函數
    """
    try:
        result = await postgrest_rpc(
            "update_termination_status_atomic",
            {
                "p_case_id": case_id,
                "p_status": status,
                "p_notes": notes
            }
        )
        return result

    except Exception as e:
        logger.error(f"更新解約狀態失敗: {e}")
        return {"success": False, "error": str(e)}


# ============================================================================
# 保留的工具（不涉及多表操作，無需 Transaction）
# ============================================================================

async def termination_update_checklist(
    case_id: int,
    item: str,
    value: bool
) -> dict:
    """
    更新解約案件的 Checklist 項目（單表操作，無需 Transaction）
    """
    CHECKLIST_ITEMS = [
        'notice_confirmed', 'belongings_removed', 'keys_returned',
        'room_inspected', 'doc_submitted', 'doc_approved',
        'settlement_calculated', 'refund_processed'
    ]

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
        checklist = case.get('checklist', {}) or {}
        checklist[item] = value

        # 更新
        update_data = {"checklist": checklist}

        # 自動更新相關日期
        if item == 'doc_submitted' and value:
            update_data["doc_submitted_date"] = datetime.now().strftime('%Y-%m-%d')
        elif item == 'doc_approved' and value:
            update_data["doc_approved_date"] = datetime.now().strftime('%Y-%m-%d')
        elif item == 'refund_processed' and value:
            update_data["refund_date"] = datetime.now().strftime('%Y-%m-%d')

        await postgrest_request(
            "PATCH",
            f"termination_cases?id=eq.{case_id}",
            data=update_data
        )

        completed_count = sum(1 for v in checklist.values() if v)

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


async def termination_calculate_settlement(
    case_id: int,
    doc_approved_date: str,
    other_deductions: float = 0,
    other_deduction_notes: Optional[str] = None
) -> dict:
    """
    計算押金結算（單表操作，無需 Transaction）
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

        # 計算扣除天數
        deduction_days = max(0, (doc_date - contract_end_date).days)

        # 計算金額
        daily_rate = float(case.get('daily_rate', 0)) or round(float(case.get('monthly_rent', 0)) / 30, 2)
        deposit_amount = float(case.get('deposit_amount', 0)) or float(case.get('contract_deposit', 0))
        deduction_amount = deduction_days * daily_rate
        refund_amount = deposit_amount - deduction_amount - other_deductions

        # 更新解約案件
        checklist = case.get('checklist', {}) or {}
        checklist['doc_approved'] = True
        checklist['settlement_calculated'] = True

        update_data = {
            "doc_approved_date": doc_approved_date,
            "deduction_days": deduction_days,
            "daily_rate": daily_rate,
            "deduction_amount": deduction_amount,
            "other_deductions": other_deductions,
            "other_deduction_notes": other_deduction_notes,
            "refund_amount": max(0, refund_amount),
            "settlement_date": datetime.now().strftime('%Y-%m-%d'),
            "status": "pending_settlement",
            "checklist": checklist
        }

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


async def termination_get_cases(
    branch_id: Optional[int] = None,
    status: Optional[str] = None,
    include_completed: bool = False
) -> dict:
    """取得解約案件列表"""
    try:
        query = "v_termination_cases?"
        filters = []

        if branch_id:
            filters.append(f"branch_id=eq.{branch_id}")
        if status:
            filters.append(f"status=eq.{status}")
        elif not include_completed:
            filters.append("status=not.in.(completed,cancelled)")

        if filters:
            query += "&".join(filters)

        result = await postgrest_request("GET", query)

        return {
            "success": True,
            "cases": result or [],
            "count": len(result or [])
        }

    except Exception as e:
        logger.error(f"取得解約案件失敗: {e}")
        return {"success": False, "error": str(e)}


async def termination_get_case(case_id: int) -> dict:
    """取得單一解約案件詳情"""
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
