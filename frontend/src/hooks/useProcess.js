/**
 * 流程管理 Hooks
 *
 * 提供統一的流程資料存取和操作介面
 *
 * @example
 * // 取得 Workspace 資料
 * const { data, isLoading } = useProcessWorkspace('renewal', contractId)
 *
 * // 取得 Dashboard 統計
 * const { data: stats } = useProcessDashboard()
 *
 * // 執行流程行動
 * const { mutate: executeAction } = useProcessAction('renewal')
 */

import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { db } from '../services/api'
import { executeAction as dispatchAction } from '../components/process/ActionDispatcher'
import useStore from '../store/useStore'

// ============================================================================
// Workspace 資料查詢
// ============================================================================

/**
 * 取得流程 Workspace 資料
 *
 * @param {string} processKey - 流程類型 (renewal, payment, termination, etc.)
 * @param {number|string} entityId - 實體 ID
 * @param {object} options - 額外選項
 */
export function useProcessWorkspace(processKey, entityId, options = {}) {
  const viewMap = {
    renewal: 'v_contract_workspace',
    signing: 'v_contract_workspace',
    termination: 'v_termination_workspace',
    payment: 'v_payment_workspace',
    invoice: 'v_invoice_workspace',
    commission: 'v_commission_workspace'
  }

  const idFieldMap = {
    renewal: 'id',      // v_contract_workspace 使用 id（即 contract.id）
    signing: 'id',      // v_contract_workspace 使用 id
    termination: 'id',
    payment: 'payment_id',
    invoice: 'payment_id',  // v_invoice_workspace 使用 payment_id
    commission: 'commission_id'
  }

  const viewName = viewMap[processKey]
  const idField = idFieldMap[processKey] || 'id'

  return useQuery({
    queryKey: ['process', processKey, 'workspace', entityId],
    queryFn: async () => {
      if (!viewName) {
        throw new Error(`未知的流程類型: ${processKey}`)
      }

      const params = {
        [`${idField}`]: `eq.${entityId}`
      }

      const data = await db.query(viewName, params)
      return data?.[0] || null
    },
    enabled: !!entityId && !!processKey,
    ...options
  })
}

// ============================================================================
// Dashboard 資料查詢
// ============================================================================

/**
 * 取得流程 Dashboard 待辦清單
 *
 * @param {string} processKey - 流程類型（可選，不指定則取得全部）
 * @param {object} filters - 過濾條件
 */
export function useProcessQueue(processKey, filters = {}) {
  const selectedBranch = useStore((state) => state.selectedBranch)

  const viewMap = {
    renewal: 'v_contract_workspace',
    signing: 'v_contract_workspace',
    termination: 'v_termination_workspace',
    payment: 'v_payment_workspace'
  }

  return useQuery({
    queryKey: ['process', processKey, 'queue', filters, selectedBranch],
    queryFn: async () => {
      const viewName = viewMap[processKey]
      if (!viewName) {
        throw new Error(`未知的流程類型: ${processKey}`)
      }

      const params = {
        // 只取有卡點且非 completed 的項目
        // 使用 and 語法避免重複 key 覆蓋
        and: '(decision_blocked_by.not.is.null,decision_blocked_by.neq.completed)',
        // 按優先級和逾期排序
        order: 'is_overdue.desc,decision_priority.asc,due_date.asc',
        ...filters
      }

      if (selectedBranch) {
        params.branch_id = `eq.${selectedBranch}`
      }

      return db.query(viewName, params)
    },
    enabled: !!processKey
  })
}

/**
 * 取得 Dashboard 統計數據
 */
export function useProcessDashboardStats() {
  const selectedBranch = useStore((state) => state.selectedBranch)

  return useQuery({
    queryKey: ['process', 'dashboard', 'stats', selectedBranch],
    queryFn: async () => {
      // 並行取得各流程統計
      const [renewalData, signingData, terminationData, paymentData] = await Promise.all([
        db.query('v_contract_workspace', {
          decision_blocked_by: 'not.is.null',
          'decision_blocked_by': 'neq.completed',
          select: 'contract_id,decision_priority,is_overdue',
          ...(selectedBranch && { branch_id: `eq.${selectedBranch}` })
        }),
        db.query('v_contract_workspace', {
          decision_blocked_by: 'not.is.null',
          signing_status: 'not.eq.completed',
          select: 'contract_id,decision_priority,is_overdue',
          ...(selectedBranch && { branch_id: `eq.${selectedBranch}` })
        }),
        db.query('v_termination_workspace', {
          select: 'id,status',
          status: 'neq.completed',
          ...(selectedBranch && { branch_id: `eq.${selectedBranch}` })
        }),
        // Payment workspace 可能尚未建立
        Promise.resolve([])
      ])

      return {
        renewal: {
          total: renewalData?.length || 0,
          urgent: renewalData?.filter(i => i.decision_priority === 'urgent').length || 0,
          overdue: renewalData?.filter(i => i.is_overdue).length || 0
        },
        signing: {
          total: signingData?.length || 0,
          urgent: signingData?.filter(i => i.decision_priority === 'urgent').length || 0,
          overdue: signingData?.filter(i => i.is_overdue).length || 0
        },
        termination: {
          total: terminationData?.length || 0,
          inProgress: terminationData?.filter(i => i.status === 'in_progress').length || 0
        },
        payment: {
          total: paymentData?.length || 0,
          overdue: paymentData?.filter(i => i.is_overdue).length || 0
        }
      }
    }
  })
}

// ============================================================================
// 行動執行
// ============================================================================

/**
 * 流程行動執行 Hook
 *
 * @param {string} processKey - 流程類型
 */
export function useProcessAction(processKey) {
  const queryClient = useQueryClient()
  const addNotification = useStore((state) => state.addNotification)

  return useMutation({
    mutationFn: async ({ actionKey, entityId, payload = {} }) => {
      return dispatchAction(processKey, actionKey, entityId, payload)
    },
    onSuccess: (result, variables) => {
      // 重新整理相關查詢
      queryClient.invalidateQueries({ queryKey: ['process', processKey] })
      queryClient.invalidateQueries({ queryKey: ['contracts'] })
      queryClient.invalidateQueries({ queryKey: ['payments'] })

      if (result.success) {
        addNotification({
          type: 'success',
          message: '操作成功'
        })
      } else {
        addNotification({
          type: 'error',
          message: result.error || '操作失敗'
        })
      }
    },
    onError: (error) => {
      addNotification({
        type: 'error',
        message: `操作失敗: ${error.message}`
      })
    }
  })
}

// ============================================================================
// 工具函數
// ============================================================================

/**
 * 將 Decision Table 資料轉換為 DecisionPanel 格式
 */
export function parseDecision(workspaceData) {
  if (!workspaceData) return null

  return {
    blocked_by: workspaceData.decision_blocked_by,
    next_action: workspaceData.decision_next_action,
    action_key: workspaceData.decision_action_key,
    owner: workspaceData.decision_owner,
    priority: workspaceData.decision_priority,
    is_overdue: workspaceData.is_overdue,
    overdue_days: workspaceData.overdue_days,
    // ★ 105 新增：傳遞 next_contract_id 給 ActionDispatcher 導流用
    next_contract_id: workspaceData.next_contract_id
  }
}

/**
 * 將 Workspace 資料轉換為 Timeline 步驟格式
 */
export function parseTimelineSteps(workspaceData, processKey) {
  if (!workspaceData) return []

  // 各流程的步驟定義
  const stepDefinitions = {
    renewal: [
      { key: 'intent', label: '續約意願' },
      { key: 'signing', label: '合約簽署' },
      { key: 'payment', label: '款項收取' },
      { key: 'invoice', label: '發票開立' },
      { key: 'activation', label: '合約啟用' }
    ],
    termination: [
      { key: 'notice', label: '收到通知' },
      { key: 'checklist', label: '退租清單' },
      { key: 'settlement', label: '費用結算' },
      { key: 'handover', label: '點交完成' }
    ],
    payment: [
      { key: 'created', label: '帳單建立' },
      { key: 'reminder', label: '催繳通知' },
      { key: 'received', label: '款項入帳' },
      { key: 'invoiced', label: '發票開立' }
    ]
  }

  const steps = stepDefinitions[processKey] || []

  // 根據 workspaceData 中的狀態欄位填充各步驟狀態
  return steps.map(step => {
    // 這裡需要根據實際的 workspace view 欄位來判斷狀態
    // 暫時返回基本結構，實際使用時需根據 view schema 調整
    return {
      key: step.key,
      label: step.label,
      status: workspaceData[`${step.key}_status`] || 'not_started',
      details: workspaceData[`${step.key}_details`] || null
    }
  })
}
