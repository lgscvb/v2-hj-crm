/**
 * Action Dispatcher - 將 SQL 的 action_key 映射到具體的 JS 函數
 *
 * 這個模組是流程引擎的核心，負責：
 * 1. 接收 process_key + action_key
 * 2. 調用對應的 MCP Tool
 * 3. 返回執行結果
 */

import { callTool } from '../../services/api'

/**
 * 執行流程行動
 *
 * @param {string} processKey - 流程類型 (renewal, payment, etc.)
 * @param {string} actionKey - 行動代碼 (SEND_REMINDER, CREATE_DRAFT, etc.)
 * @param {number|string} entityId - 實體 ID
 * @param {object} payload - 額外參數
 * @returns {Promise<object>} 執行結果
 */
export const executeAction = async (processKey, actionKey, entityId, payload = {}) => {
  console.log(`[ActionDispatcher] 執行 [${processKey}]: ${actionKey} for ID: ${entityId}`)

  const handler = getActionHandler(processKey, actionKey)

  if (!handler) {
    throw new Error(`未定義的行動: ${processKey}.${actionKey}`)
  }

  try {
    const result = await handler(entityId, payload)
    console.log(`[ActionDispatcher] 執行成功:`, result)
    return { success: true, data: result }
  } catch (error) {
    console.error(`[ActionDispatcher] 執行失敗:`, error)
    return { success: false, error: error.message }
  }
}

/**
 * 取得行動處理函數
 */
const getActionHandler = (processKey, actionKey) => {
  const strategies = {
    // ========================================
    // 續約流程 (Renewal)
    // ========================================
    renewal: {
      // 建立續約草稿
      CREATE_DRAFT: async (contractId, payload) => {
        return callTool('renewal_create_draft', {
          contract_id: contractId,
          ...payload
        })
      },

      // 送出簽署
      SEND_FOR_SIGN: async (contractId, payload) => {
        return callTool('renewal_send_for_sign', {
          contract_id: contractId,
          ...payload
        })
      },

      // 標記已簽回
      MARK_SIGNED: async (contractId, payload) => {
        return callTool('renewal_mark_signed', {
          contract_id: contractId,
          signed_date: payload.signed_date || new Date().toISOString().split('T')[0]
        })
      },

      // 啟用合約
      ACTIVATE: async (contractId, payload) => {
        return callTool('renewal_activate', {
          contract_id: contractId
        })
      },

      // 設定續約意願（value 預設 true，可從 payload 覆蓋）
      SET_CONFIRMED: async (contractId, payload) => {
        return callTool('renewal_set_flag', {
          contract_id: contractId,
          flag: 'confirmed',
          value: payload?.value !== undefined ? payload.value : true
        })
      },

      // 設定已通知（value 預設 true，可從 payload 覆蓋）
      SET_NOTIFIED: async (contractId, payload) => {
        return callTool('renewal_set_flag', {
          contract_id: contractId,
          flag: 'notified',
          value: payload?.value !== undefined ? payload.value : true
        })
      },

      // 發送催簽提醒
      SEND_SIGN_REMINDER: async (contractId, payload) => {
        return callTool('renewal_send_sign_reminder', {
          contract_id: contractId,
          force: payload.force || false
        })
      },

      // ★ 2026-01-01 新增：導流到付款管理（payment_pending 狀態使用）
      // ★ 105 修正：優先使用 next_contract_id（續約合約的款項），否則 fallback 到舊合約
      GO_TO_PAYMENTS: async (contractId, payload) => {
        const targetId = payload?.next_contract_id || contractId
        return {
          success: true,
          action: 'navigate',
          url: `/payments?contract_id=${targetId}`,
          message: '請前往繳費管理頁面處理款項'
        }
      },

      // ★ 2026-01-01 新增：導流到發票管理（invoice_pending 狀態使用）
      // ★ 105 修正：優先使用 next_contract_id
      GO_TO_INVOICES: async (contractId, payload) => {
        const targetId = payload?.next_contract_id || contractId
        return {
          success: true,
          action: 'navigate',
          url: `/invoices?contract_id=${targetId}`,
          message: '請前往發票管理頁面開立發票'
        }
      }
    },

    // ========================================
    // 付款流程 (Payment)
    // ========================================
    payment: {
      // 發送催繳通知
      SEND_REMINDER: async (paymentId, payload) => {
        return callTool('billing_send_reminder', {
          payment_id: paymentId
        })
      },

      // 記錄收款（使用 crm_record_payment）
      // ★ 2025-01-01 修復：移除 paid_at/payment_reference，改用 notes
      RECORD_PAYMENT: async (paymentId, payload) => {
        return callTool('crm_record_payment', {
          payment_id: paymentId,
          payment_method: payload.payment_method,
          notes: payload.payment_reference || payload.notes || null
        })
      },

      // 申請免收
      REQUEST_WAIVE: async (paymentId, payload) => {
        return callTool('billing_request_waive', {
          payment_id: paymentId,
          reason: payload.reason
        })
      },

      // 撤銷付款
      UNDO_PAYMENT: async (paymentId, payload) => {
        return callTool('billing_undo_payment', {
          payment_id: paymentId,
          reason: payload.reason
        })
      },

      // 設定承諾付款日期
      SET_PROMISE: async (paymentId, payload) => {
        return callTool('billing_set_promise', {
          payment_id: paymentId,
          promised_pay_date: payload.promised_pay_date,
          notes: payload.notes
        })
      },

      // 清除承諾付款日期
      CLEAR_PROMISE: async (paymentId, payload) => {
        return callTool('billing_clear_promise', {
          payment_id: paymentId,
          reason: payload.reason
        })
      }
    },

    // ========================================
    // 發票流程 (Invoice)
    // ========================================
    invoice: {
      // 開立發票（使用 invoice_create）
      ISSUE_INVOICE: async (paymentId, payload) => {
        return callTool('invoice_create', {
          payment_id: paymentId,
          ...payload
        })
      },

      // 作廢發票（注意：invoice_void 接收 payment_id，不是 invoice_id）
      VOID_INVOICE: async (paymentId, payload) => {
        return callTool('invoice_void', {
          payment_id: paymentId,
          reason: payload.reason
        })
      },

      // 更新客戶資料（缺統編時需導航到客戶編輯頁面）
      // 這是 UI 導航行動，不呼叫 MCP tool
      UPDATE_CUSTOMER: async (paymentId, payload) => {
        return {
          success: true,
          action: 'navigate',
          url: `/customers/${payload.customerId}/edit`,
          message: '請前往客戶頁面補齊統一編號'
        }
      },

      // ★ 2026-01-02 新增：手動確認已開發票（用於外部 App 開立情況）
      MARK_ISSUED: async (paymentId, payload) => {
        return callTool('invoice_mark_issued', {
          payment_id: paymentId,
          invoice_number: payload?.invoice_number,
          notes: payload?.notes
        })
      }
    },

    // ========================================
    // 解約流程 (Termination)
    // ========================================
    termination: {
      // 更新 Checklist
      UPDATE_CHECKLIST: async (caseId, payload) => {
        return callTool('termination_update_checklist', {
          case_id: caseId,
          step: payload.step,
          completed: payload.completed
        })
      },

      // 更新狀態（使用 v2 版本）
      UPDATE_STATUS: async (caseId, payload) => {
        return callTool('termination_update_status_v2', {
          case_id: caseId,
          status: payload.status
        })
      }
    },

    // ========================================
    // 簽署流程 (Signing) - 使用 renewal tools
    // ========================================
    signing: {
      GENERATE_PDF: async (contractId, payload) => {
        return callTool('contract_generate_pdf', {
          contract_id: contractId
        })
      },

      SEND_FOR_SIGN: async (contractId, payload) => {
        return callTool('renewal_send_for_sign', {
          contract_id: contractId
        })
      },

      MARK_SIGNED: async (contractId, payload) => {
        return callTool('renewal_mark_signed', {
          contract_id: contractId,
          signed_date: payload.signed_date
        })
      },

      // 發送催簽提醒
      SEND_SIGN_REMINDER: async (contractId, payload) => {
        return callTool('renewal_send_sign_reminder', {
          contract_id: contractId,
          force: payload.force || false
        })
      }
    },

    // ========================================
    // 佣金流程 (Commission)
    // ========================================
    commission: {
      // 支付佣金
      PAY_COMMISSION: async (commissionId, payload) => {
        return callTool('commission_pay', {
          commission_id: commissionId,
          payment_method: payload.payment_method,
          payment_reference: payload.payment_reference,
          paid_at: payload.paid_at || new Date().toISOString().split('T')[0]
        })
      },

      // 標記可付款（pending → eligible）
      MARK_ELIGIBLE: async (commissionId, payload) => {
        return callTool('commission_mark_eligible', {
          commission_id: commissionId,
          notes: payload.notes
        })
      },

      // 取消佣金
      CANCEL_COMMISSION: async (commissionId, payload) => {
        return callTool('commission_cancel', {
          commission_id: commissionId,
          reason: payload.reason
        })
      }
    }
  }

  return strategies[processKey]?.[actionKey]
}

/**
 * 檢查行動是否存在
 */
export const hasAction = (processKey, actionKey) => {
  return !!getActionHandler(processKey, actionKey)
}

/**
 * 取得流程所有可用行動
 * 註：僅列出已實作的 MCP 工具映射
 */
export const getAvailableActions = (processKey) => {
  const actionMap = {
    renewal: ['CREATE_DRAFT', 'SEND_FOR_SIGN', 'MARK_SIGNED', 'ACTIVATE', 'SET_CONFIRMED', 'SET_NOTIFIED', 'SEND_SIGN_REMINDER', 'GO_TO_PAYMENTS', 'GO_TO_INVOICES'],
    payment: ['SEND_REMINDER', 'RECORD_PAYMENT', 'REQUEST_WAIVE', 'UNDO_PAYMENT', 'SET_PROMISE', 'CLEAR_PROMISE'],
    invoice: ['ISSUE_INVOICE', 'VOID_INVOICE', 'UPDATE_CUSTOMER', 'MARK_ISSUED'],
    termination: ['UPDATE_CHECKLIST', 'UPDATE_STATUS'],
    signing: ['GENERATE_PDF', 'SEND_FOR_SIGN', 'MARK_SIGNED', 'SEND_SIGN_REMINDER'],
    commission: ['PAY_COMMISSION', 'MARK_ELIGIBLE', 'CANCEL_COMMISSION']
  }

  return actionMap[processKey] || []
}

export default executeAction
