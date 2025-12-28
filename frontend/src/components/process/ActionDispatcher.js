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

      // 設定續約意願
      SET_CONFIRMED: async (contractId, payload) => {
        return callTool('renewal_set_flag', {
          contract_id: contractId,
          flag_type: 'confirmed'
        })
      },

      // 設定已通知
      SET_NOTIFIED: async (contractId, payload) => {
        return callTool('renewal_set_flag', {
          contract_id: contractId,
          flag_type: 'notified'
        })
      }
    },

    // ========================================
    // 付款流程 (Payment)
    // ========================================
    payment: {
      // 發送催繳通知
      SEND_REMINDER: async (paymentId, payload) => {
        return callTool('send_payment_reminder', {
          payment_id: paymentId,
          channel: payload.channel || 'line'
        })
      },

      // 記錄收款
      RECORD_PAYMENT: async (paymentId, payload) => {
        return callTool('record_payment', {
          payment_id: paymentId,
          payment_method: payload.payment_method,
          paid_at: payload.paid_at,
          payment_reference: payload.payment_reference
        })
      },

      // 申請免收
      REQUEST_WAIVE: async (paymentId, payload) => {
        return callTool('request_waive', {
          payment_id: paymentId,
          reason: payload.reason
        })
      },

      // 撤銷付款
      UNDO_PAYMENT: async (paymentId, payload) => {
        return callTool('undo_payment', {
          payment_id: paymentId,
          reason: payload.reason
        })
      }
    },

    // ========================================
    // 發票流程 (Invoice)
    // ========================================
    invoice: {
      // 開立發票
      ISSUE_INVOICE: async (paymentId, payload) => {
        return callTool('invoice_issue', {
          payment_id: paymentId,
          ...payload
        })
      },

      // 作廢發票
      VOID_INVOICE: async (invoiceId, payload) => {
        return callTool('invoice_void', {
          invoice_id: invoiceId,
          reason: payload.reason
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

      // 更新狀態
      UPDATE_STATUS: async (caseId, payload) => {
        return callTool('termination_update_status', {
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
      }
    },

    // ========================================
    // 佣金流程 (Commission)
    // ========================================
    commission: {
      // 標記為可付款
      MARK_ELIGIBLE: async (commissionId, payload) => {
        return callTool('commission_mark_eligible', {
          commission_id: commissionId
        })
      },

      // 支付佣金
      PAY_COMMISSION: async (commissionId, payload) => {
        return callTool('commission_pay', {
          commission_id: commissionId,
          payment_method: payload.payment_method,
          payment_reference: payload.payment_reference,
          paid_at: payload.paid_at || new Date().toISOString().split('T')[0]
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
 */
export const getAvailableActions = (processKey) => {
  const actionMap = {
    renewal: ['CREATE_DRAFT', 'SEND_FOR_SIGN', 'MARK_SIGNED', 'ACTIVATE', 'SET_CONFIRMED', 'SET_NOTIFIED'],
    payment: ['SEND_REMINDER', 'RECORD_PAYMENT', 'REQUEST_WAIVE', 'UNDO_PAYMENT'],
    invoice: ['ISSUE_INVOICE', 'VOID_INVOICE', 'UPDATE_CUSTOMER'],
    termination: ['UPDATE_CHECKLIST', 'UPDATE_STATUS'],
    signing: ['GENERATE_PDF', 'SEND_FOR_SIGN', 'MARK_SIGNED'],
    commission: ['MARK_ELIGIBLE', 'PAY_COMMISSION', 'CANCEL_COMMISSION']
  }

  return actionMap[processKey] || []
}

export default executeAction
