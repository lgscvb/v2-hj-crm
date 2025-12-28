/**
 * DecisionPanel - 通用決策面板組件
 *
 * 顯示流程當前卡點、下一步行動、責任人等資訊
 * 並提供行動按鈕執行 MCP Tool
 *
 * @example
 * <DecisionPanel
 *   decision={{
 *     blocked_by: 'need_send_for_sign',
 *     next_action: '送出簽署給客戶',
 *     action_key: 'SEND_FOR_SIGN',
 *     owner: 'Sales',
 *     priority: 'high',
 *     is_overdue: true,
 *     overdue_days: 5
 *   }}
 *   processKey="renewal"
 *   entityId={123}
 *   onActionComplete={(result) => console.log('完成', result)}
 * />
 */

import { useState } from 'react'
import { Link } from 'react-router-dom'
import {
  CheckCircle,
  AlertTriangle,
  ChevronRight,
  Loader2,
  Clock,
  Flame,
  AlertCircle,
  ArrowRight
} from 'lucide-react'
import { executeAction } from './ActionDispatcher'
import { PRIORITY_COLORS, OWNER_COLORS } from './index'

// 通用卡點標籤對照表（可擴充）
const BLOCKED_LABELS = {
  // 續約流程
  need_create_renewal: '尚未建立續約合約',
  need_send_for_sign: '合約草稿待送簽',
  waiting_for_sign: '等待客戶回簽',
  signing_overdue: '回簽逾期',
  need_activate: '已簽回，待啟用',
  payment_pending: '款項未入帳',
  invoice_pending: '發票未開立',

  // 付款流程
  high_risk_overdue: '高風險客戶逾期',
  severe_overdue: '嚴重逾期（超過60天）',
  need_legal_notice: '需發存證信函',
  need_second_reminder: '需再次催繳',
  need_first_reminder: '首次催繳',
  due_soon: '即將到期',

  // 發票流程
  need_tax_id: '缺少統一編號',
  invoice_overdue: '開票逾期',
  need_issue_invoice: '待開立發票',
  need_reissue: '作廢待重開',

  // 佣金流程
  contract_terminated: '合約已終止，待確認',
  payment_overdue: '佣金付款逾期',
  ready_to_pay: '可付款',
  almost_eligible: '即將可付款',
  waiting_eligibility: '等待滿 6 個月',

  // 解約流程
  need_confirm_notice: '待確認解約通知',
  need_move_out: '待客戶搬遷',
  need_return_keys: '待回收鑰匙',
  need_inspect_room: '待驗收場地',
  need_submit_doc: '待送國稅局公文',
  doc_overdue: '公文逾期（超過30天）',
  waiting_doc_approval: '等待公文核准',
  settlement_overdue: '結算逾期',
  need_calculate_settlement: '待計算押金結算',
  refund_overdue: '退款逾期',
  need_process_refund: '待處理退款',
  ready_to_complete: '可完成解約',
  pending_checklist: '待完成退租清單',
  waiting_approval: '等待核准',

  // 通用
  completed: '流程完成'
}

// 行動標籤對照表
const ACTION_LABELS = {
  // 續約流程
  CREATE_DRAFT: '建立草稿',
  SEND_FOR_SIGN: '送出簽署',
  MARK_SIGNED: '標記已簽回',
  ACTIVATE: '啟用合約',
  SET_CONFIRMED: '設定續約意願',
  SET_NOTIFIED: '標記已通知',
  SEND_SIGN_REMINDER: '發送催簽提醒',

  // 付款流程
  SEND_REMINDER: '發送催繳通知',
  SEND_LEGAL_NOTICE: '發送存證信函',
  RECORD_PAYMENT: '記錄收款',
  REQUEST_WAIVE: '申請免收',

  // 發票流程
  ISSUE_INVOICE: '開立發票',
  UPDATE_CUSTOMER: '更新客戶資料',

  // 佣金流程
  CANCEL_COMMISSION: '取消佣金',
  PAY_COMMISSION: '支付佣金',
  MARK_ELIGIBLE: '標記可付款',

  // 解約流程
  UPDATE_CHECKLIST: '更新清單',
  UPDATE_STATUS: '更新狀態',
  CONFIRM_NOTICE: '確認通知',
  SUBMIT_DOC: '送出公文',
  APPROVE_DOC: '核准公文',
  CALCULATE_SETTLEMENT: '計算結算',
  PROCESS_REFUND: '處理退款',
  COMPLETE_TERMINATION: '完成解約'
}

// 優先級圖示
const PRIORITY_ICONS = {
  urgent: Flame,
  high: AlertTriangle,
  medium: Clock,
  low: ArrowRight
}

/**
 * 完成狀態面板
 */
function CompletedPanel({ message = '流程完成' }) {
  return (
    <div className="bg-green-50 border border-green-200 rounded-lg p-4">
      <div className="flex items-center gap-2">
        <CheckCircle className="w-5 h-5 text-green-500" />
        <span className="font-medium text-green-700">{message}</span>
      </div>
    </div>
  )
}

/**
 * 逾期警告
 */
function OverdueWarning({ days }) {
  if (!days || days <= 0) return null

  return (
    <div className="flex items-center gap-1.5 text-sm text-red-600 font-medium">
      <AlertCircle className="w-4 h-4" />
      <span>已逾期 {days} 天</span>
    </div>
  )
}

/**
 * 主組件
 */
export default function DecisionPanel({
  decision,
  processKey,
  entityId,
  onActionComplete,
  onActionError,
  actionOverrides,  // 覆寫特定 action 的行為
  showPriority = true,
  showOwner = true,
  customActions,    // 額外的自訂按鈕
  className = ''
}) {
  const [isLoading, setIsLoading] = useState(false)
  const [loadingAction, setLoadingAction] = useState(null)

  // 如果沒有卡點，顯示完成狀態
  if (!decision?.blocked_by || decision.blocked_by === 'completed') {
    return <CompletedPanel />
  }

  const {
    blocked_by,
    next_action,
    action_key,
    owner,
    priority = 'medium',
    is_overdue,
    overdue_days
  } = decision

  // 取得優先級樣式
  const priorityConfig = PRIORITY_COLORS[priority] || PRIORITY_COLORS.medium
  const PriorityIcon = PRIORITY_ICONS[priority] || Clock

  // 取得責任人樣式
  const ownerConfig = OWNER_COLORS[owner] || { bg: 'bg-gray-100', text: 'text-gray-700' }

  // 處理行動執行
  const handleAction = async (actionKey, payload = {}) => {
    // 檢查是否有覆寫
    if (actionOverrides?.[actionKey]) {
      return actionOverrides[actionKey](entityId, payload)
    }

    setIsLoading(true)
    setLoadingAction(actionKey)

    try {
      const result = await executeAction(processKey, actionKey, entityId, payload)

      if (result.success) {
        onActionComplete?.(result)
      } else {
        onActionError?.(result.error)
      }
    } catch (error) {
      console.error('[DecisionPanel] 行動執行失敗:', error)
      onActionError?.(error.message)
    } finally {
      setIsLoading(false)
      setLoadingAction(null)
    }
  }

  // 按鈕樣式
  const buttonBaseClass = "inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium rounded-lg transition-colors disabled:opacity-50"
  const buttonVariants = {
    primary: 'bg-primary-600 text-white hover:bg-primary-700',
    success: 'bg-green-600 text-white hover:bg-green-700',
    warning: 'bg-yellow-500 text-white hover:bg-yellow-600',
    danger: 'bg-red-600 text-white hover:bg-red-700',
    secondary: 'bg-gray-100 text-gray-700 hover:bg-gray-200'
  }

  // 根據優先級決定主按鈕樣式
  const getButtonVariant = () => {
    if (priority === 'urgent') return 'danger'
    if (priority === 'high') return 'warning'
    return 'primary'
  }

  return (
    <div className={`space-y-4 ${className}`}>
      {/* 決策資訊卡 */}
      <div className={`${priorityConfig.bg} border ${priorityConfig.border} rounded-lg p-4 space-y-3`}>
        {/* 卡點顯示 */}
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-2">
            <AlertTriangle className={`w-5 h-5 ${priorityConfig.text}`} />
            <span className={`font-medium ${priorityConfig.text}`}>
              卡在：{BLOCKED_LABELS[blocked_by] || blocked_by}
            </span>
          </div>

          {/* 優先級標籤 */}
          {showPriority && priority && (
            <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${priorityConfig.badge}`}>
              <PriorityIcon className="w-3 h-3 inline mr-1" />
              {priority === 'urgent' ? '緊急' : priority === 'high' ? '高' : priority === 'medium' ? '中' : '低'}
            </span>
          )}
        </div>

        {/* 下一步行動 */}
        {next_action && (
          <div className="flex items-center gap-2 text-sm">
            <ChevronRight className="w-4 h-4 text-gray-400" />
            <span className="text-gray-700">下一步：{next_action}</span>
          </div>
        )}

        {/* 責任人與逾期 */}
        <div className="flex items-center justify-between">
          {showOwner && owner && (
            <div className="flex items-center gap-2">
              <span className="text-sm text-gray-500">責任人：</span>
              <span className={`text-xs px-2 py-0.5 rounded ${ownerConfig.bg} ${ownerConfig.text}`}>
                {owner}
              </span>
            </div>
          )}

          {is_overdue && <OverdueWarning days={overdue_days} />}
        </div>
      </div>

      {/* 行動按鈕區 */}
      <div className="flex flex-wrap gap-2">
        {/* 主要行動按鈕（由 action_key 決定） */}
        {action_key && (
          <button
            onClick={() => handleAction(action_key)}
            disabled={isLoading}
            className={`${buttonBaseClass} ${buttonVariants[getButtonVariant()]}`}
          >
            {loadingAction === action_key ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : (
              <ArrowRight className="w-4 h-4" />
            )}
            {ACTION_LABELS[action_key] || action_key}
          </button>
        )}

        {/* 自訂額外按鈕 */}
        {customActions?.map((action) => {
          const Icon = action.icon
          const variant = buttonVariants[action.variant || 'secondary']

          if (action.isLink && action.to) {
            return (
              <Link
                key={action.key}
                to={action.to}
                className={`${buttonBaseClass} ${variant}`}
              >
                {Icon && <Icon className="w-4 h-4" />}
                {action.label}
              </Link>
            )
          }

          return (
            <button
              key={action.key}
              onClick={() => action.onClick ? action.onClick() : handleAction(action.key, action.payload)}
              disabled={isLoading}
              className={`${buttonBaseClass} ${variant}`}
            >
              {loadingAction === action.key ? (
                <Loader2 className="w-4 h-4 animate-spin" />
              ) : Icon ? (
                <Icon className="w-4 h-4" />
              ) : null}
              {action.label}
            </button>
          )
        })}
      </div>
    </div>
  )
}

// 匯出子組件供獨立使用
export { CompletedPanel, OverdueWarning }
