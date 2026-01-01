import { useState, useEffect } from 'react'
import { useParams, useNavigate, Link } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { callTool } from '../services/api'
import { useContractBillingCycles, useContractBillingSummary } from '../hooks/useApi'
import Badge from '../components/Badge'
import { ProcessTimeline } from '../components/process'
import {
  ArrowLeft,
  Bell,
  CheckCircle,
  FileText,
  Receipt,
  Play,
  Clock,
  AlertTriangle,
  ExternalLink,
  ChevronRight,
  ChevronLeft,
  ChevronDown,
  ChevronUp,
  Calendar,
  Loader2,
  XCircle,
  Circle,
  CreditCard,
  DollarSign,
  Plus,
  Send,
  PenLine,
  History,
  X
} from 'lucide-react'

// ============================================================================
// 續約流程專用的時間軸詳情渲染
// ============================================================================

function renderRenewalTimelineDetails(step) {
  const formatDateTime = (dateStr) => {
    if (!dateStr) return null
    return new Date(dateStr).toLocaleString('zh-TW')
  }

  switch (step.key) {
    case 'intent':
      return (
        <>
          {step.notified_at && <p>通知時間：{formatDateTime(step.notified_at)}</p>}
          {step.confirmed_at && <p>確認時間：{formatDateTime(step.confirmed_at)}</p>}
          {step.status === 'not_started' && <p className="text-gray-400">尚未通知</p>}
        </>
      )
    case 'signing':
      if (step.next_contract_id) {
        return (
          <>
            <p>續約合約 ID：{step.next_contract_id}</p>
            {step.sent_for_sign_at && <p>送簽時間：{formatDateTime(step.sent_for_sign_at)}</p>}
            {step.days_pending > 0 && !step.next_signed_at && (
              <p className={step.days_pending > 14 ? "text-red-600 font-medium" : "text-yellow-600"}>
                已等待 {step.days_pending} 天{step.days_pending > 14 && '（逾期）'}
              </p>
            )}
            {step.next_signed_at && <p className="text-green-600">簽署時間：{formatDateTime(step.next_signed_at)}</p>}
          </>
        )
      }
      if (step.status === 'not_created') {
        return <p className="text-gray-400">尚未建立續約合約</p>
      }
      return null
    case 'payment':
      return (
        <>
          {step.payment_status && <p>狀態：{step.payment_status}</p>}
          {step.paid_at && <p>付款時間：{formatDateTime(step.paid_at)}</p>}
          {/* ★ 105 修正：後端回傳 pending/n/a，不是 not_started */}
          {step.status === 'pending' && <p className="text-gray-400">等待收款</p>}
          {step.status === 'n/a' && <p className="text-gray-400">無需收款</p>}
        </>
      )
    case 'invoice':
      return (
        <>
          {step.invoice_number && <p>發票號碼：{step.invoice_number}</p>}
          {step.invoice_date && <p>開立日期：{step.invoice_date}</p>}
          {/* ★ 105 修正：後端回傳 not_created/pending/n/a，不是 not_started；移除 invoice_status 顯示 */}
          {step.status === 'not_created' && <p className="text-gray-400">尚未開票</p>}
          {step.status === 'pending' && <p className="text-gray-400">等待開票</p>}
          {step.status === 'n/a' && <p className="text-gray-400">無需開票</p>}
        </>
      )
    case 'activation':
      return step.next_status ? <p>合約狀態：{step.next_status}</p> : null
    default:
      return null
  }
}

// ============================================================================
// Decision Panel 元件（含 Action 按鈕）
// ============================================================================

function DecisionPanel({ decision, contract, nextContract, onAction, isLoading }) {
  if (!decision?.blocked_by) {
    return (
      <div className="bg-green-50 border border-green-200 rounded-lg p-4">
        <div className="flex items-center gap-2">
          <CheckCircle className="w-5 h-5 text-green-500" />
          <span className="font-medium text-green-700">流程完成</span>
        </div>
      </div>
    )
  }

  const blockedLabels = {
    ready_for_draft: '已確認續約，可建立草稿',
    need_create_renewal: '尚未建立續約合約',
    need_send_for_sign: '合約草稿待送簽',
    waiting_for_sign: '等待客戶回簽',
    signing_overdue: '回簽逾期（超過 14 天）',
    need_activate: '已簽回，待啟用',
    payment_pending: '款項未入帳',
    invoice_pending: '發票未開立',
    completed: '流程完成'
  }

  const ownerColors = {
    Sales: 'bg-blue-100 text-blue-700',
    Finance: 'bg-purple-100 text-purple-700',
    Legal: 'bg-orange-100 text-orange-700'
  }

  // 根據 blocked_by 決定可用動作
  const getActions = () => {
    const actions = []

    switch (decision.blocked_by) {
      case 'ready_for_draft':
      case 'need_create_renewal':
        actions.push({
          key: 'create_draft',
          label: '建立續約草稿',
          icon: Plus,
          variant: 'primary'
        })
        break
      case 'need_send_for_sign':
        if (nextContract?.id) {
          actions.push({
            key: 'send_for_sign',
            label: '送出簽署',
            icon: Send,
            variant: 'primary',
            targetId: nextContract.id
          })
        }
        break
      case 'waiting_for_sign':
      case 'signing_overdue':
        if (nextContract?.id) {
          actions.push({
            key: 'mark_signed',
            label: '標記已簽回',
            icon: PenLine,
            variant: 'success',
            targetId: nextContract.id
          })
          actions.push({
            key: 'send_reminder',
            label: '發送提醒',
            icon: Bell,
            variant: 'secondary',
            targetId: nextContract.id
          })
        }
        break
      case 'need_activate':
        if (nextContract?.id) {
          actions.push({
            key: 'activate',
            label: '啟用合約',
            icon: Play,
            variant: 'success',
            targetId: nextContract.id
          })
        }
        break
      case 'payment_pending':
        actions.push({
          key: 'go_payments',
          label: '前往收款',
          icon: Receipt,
          variant: 'secondary',
          isLink: true,
          to: `/payments?contract_id=${nextContract?.id || contract?.id}`
        })
        break
      case 'invoice_pending':
        actions.push({
          key: 'go_invoices',
          label: '前往開票',
          icon: FileText,
          variant: 'secondary',
          isLink: true,
          to: `/invoices?contract_id=${nextContract?.id || contract?.id}`
        })
        break
    }

    return actions
  }

  const actions = getActions()

  return (
    <div className="space-y-4">
      <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4 space-y-3">
        <div className="flex items-center gap-2">
          <AlertTriangle className="w-5 h-5 text-yellow-500" />
          <span className="font-medium text-yellow-700">
            卡在：{blockedLabels[decision.blocked_by] || decision.blocked_by}
          </span>
        </div>

        {decision.next_action && (
          <div className="flex items-center gap-2 text-sm">
            <ChevronRight className="w-4 h-4 text-gray-400" />
            <span className="text-gray-700">下一步：{decision.next_action}</span>
          </div>
        )}

        {decision.owner && (
          <div className="flex items-center gap-2">
            <span className="text-sm text-gray-500">責任人：</span>
            <span className={`text-xs px-2 py-0.5 rounded ${ownerColors[decision.owner] || 'bg-gray-100 text-gray-700'}`}>
              {decision.owner}
            </span>
          </div>
        )}
      </div>

      {/* Action 按鈕區 */}
      {actions.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {actions.map((action) => {
            const Icon = action.icon
            const baseClass = "inline-flex items-center gap-1.5 px-3 py-2 text-sm font-medium rounded-lg transition-colors disabled:opacity-50"
            const variantClass = {
              primary: 'bg-primary-600 text-white hover:bg-primary-700',
              success: 'bg-green-600 text-white hover:bg-green-700',
              secondary: 'bg-gray-100 text-gray-700 hover:bg-gray-200'
            }[action.variant] || 'bg-gray-100 text-gray-700 hover:bg-gray-200'

            if (action.isLink) {
              return (
                <Link
                  key={action.key}
                  to={action.to}
                  className={`${baseClass} ${variantClass}`}
                >
                  <Icon className="w-4 h-4" />
                  {action.label}
                </Link>
              )
            }

            return (
              <button
                key={action.key}
                onClick={() => onAction(action.key, action.targetId)}
                disabled={isLoading}
                className={`${baseClass} ${variantClass}`}
              >
                {isLoading ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  <Icon className="w-4 h-4" />
                )}
                {action.label}
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

// ============================================================================
// 繳費週期元件
// ============================================================================

function BillingCyclesPanel({ contractId }) {
  const [expanded, setExpanded] = useState(false)
  const { data: summary, isLoading: summaryLoading } = useContractBillingSummary(contractId)
  const { data: cycles, isLoading: cyclesLoading } = useContractBillingCycles(contractId, 2, 3)

  if (summaryLoading) {
    return (
      <div className="bg-white rounded-xl border shadow-sm p-6">
        <div className="flex items-center justify-center h-24">
          <Loader2 className="w-6 h-6 animate-spin text-gray-400" />
        </div>
      </div>
    )
  }

  // 如果不計費，不顯示
  if (!summary?.is_billable) {
    return null
  }

  const hasIssues = summary.overdue_periods > 0 || summary.not_created_periods > 0

  const getStatusIcon = (status, isOverdue) => {
    if (isOverdue) return <AlertTriangle className="w-4 h-4 text-red-500" />
    if (status === 'paid' || status === 'waived') return <CheckCircle className="w-4 h-4 text-green-500" />
    if (status === 'pending') return <Clock className="w-4 h-4 text-yellow-500" />
    return <Circle className="w-4 h-4 text-gray-300" />
  }

  const getStatusText = (status, isOverdue) => {
    if (isOverdue) return '逾期'
    if (status === 'paid') return '已付'
    if (status === 'waived') return '免收'
    if (status === 'pending') return '待繳'
    return '未建立'
  }

  const getStatusColor = (status, isOverdue) => {
    if (isOverdue) return 'text-red-600 bg-red-50'
    if (status === 'paid' || status === 'waived') return 'text-green-600 bg-green-50'
    if (status === 'pending') return 'text-yellow-600 bg-yellow-50'
    return 'text-gray-400 bg-gray-50'
  }

  return (
    <div className="bg-white rounded-xl border shadow-sm p-6">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-lg font-semibold text-gray-900 flex items-center gap-2">
          <CreditCard className="w-5 h-5 text-gray-500" />
          繳費週期
        </h2>
        <div className="flex items-center gap-2">
          {hasIssues && (
            <span className="text-xs px-2 py-1 rounded bg-red-100 text-red-700">
              {summary.overdue_periods > 0 && `${summary.overdue_periods} 逾期`}
              {summary.overdue_periods > 0 && summary.not_created_periods > 0 && ' / '}
              {summary.not_created_periods > 0 && `${summary.not_created_periods} 未建立`}
            </span>
          )}
          <span className="text-sm font-medium text-gray-700">
            {summary.paid_periods}/{summary.total_periods} 期已繳
          </span>
        </div>
      </div>

      {/* 摘要資訊 */}
      <div className="grid grid-cols-2 gap-4 mb-4">
        <div className="bg-gray-50 rounded-lg p-3">
          <p className="text-xs text-gray-500">下次繳費</p>
          <p className="font-medium text-gray-900">
            {summary.next_due_date
              ? new Date(summary.next_due_date).toLocaleDateString('zh-TW')
              : '-'}
          </p>
        </div>
        <div className="bg-gray-50 rounded-lg p-3">
          <p className="text-xs text-gray-500">金額</p>
          <p className="font-medium text-gray-900">
            ${summary.next_amount?.toLocaleString() || 0}
          </p>
        </div>
      </div>

      {/* 進度條 */}
      <div className="mb-4">
        <div className="flex justify-between text-xs text-gray-500 mb-1">
          <span>收款進度</span>
          <span>${summary.total_paid?.toLocaleString()} / ${summary.total_expected?.toLocaleString()}</span>
        </div>
        <div className="h-2 bg-gray-200 rounded-full overflow-hidden">
          <div
            className="h-full bg-green-500 rounded-full transition-all"
            style={{ width: `${summary.total_expected > 0 ? (summary.total_paid / summary.total_expected) * 100 : 0}%` }}
          />
        </div>
      </div>

      {/* 展開/收起按鈕 */}
      <button
        onClick={() => setExpanded(!expanded)}
        className="w-full flex items-center justify-center gap-1 text-sm text-gray-500 hover:text-gray-700 py-2"
      >
        {expanded ? (
          <>
            <ChevronUp className="w-4 h-4" />
            收起明細
          </>
        ) : (
          <>
            <ChevronDown className="w-4 h-4" />
            查看近期繳費 ({cycles?.length || 0} 期)
          </>
        )}
      </button>

      {/* 週期明細 */}
      {expanded && cycles && cycles.length > 0 && (
        <div className="mt-4 border-t pt-4">
          <div className="space-y-2">
            {cycles.map((cycle) => (
              <div
                key={cycle.period_index}
                className={`flex items-center justify-between p-3 rounded-lg ${
                  cycle.is_current ? 'bg-blue-50 border border-blue-200' : 'bg-gray-50'
                }`}
              >
                <div className="flex items-center gap-3">
                  {getStatusIcon(cycle.payment_status, cycle.is_overdue)}
                  <div>
                    <p className="text-sm font-medium">
                      第 {cycle.period_index} 期
                      {cycle.is_current && (
                        <span className="ml-2 text-xs px-1.5 py-0.5 rounded bg-blue-100 text-blue-700">
                          當期
                        </span>
                      )}
                    </p>
                    <p className="text-xs text-gray-500">
                      {cycle.payment_period} · 應收 {new Date(cycle.due_date).toLocaleDateString('zh-TW')}
                    </p>
                  </div>
                </div>
                <div className="text-right">
                  <p className="text-sm font-medium">${cycle.expected_amount?.toLocaleString()}</p>
                  <span className={`text-xs px-2 py-0.5 rounded ${getStatusColor(cycle.payment_status, cycle.is_overdue)}`}>
                    {getStatusText(cycle.payment_status, cycle.is_overdue)}
                  </span>
                  {cycle.invoice_number && (
                    <p className="text-xs text-gray-400 mt-1">{cycle.invoice_number}</p>
                  )}
                </div>
              </div>
            ))}
          </div>

          <Link
            to={`/payments?contract_id=${contractId}`}
            className="mt-4 block text-center text-sm text-primary-600 hover:text-primary-700"
          >
            查看全部付款記錄 →
          </Link>
        </div>
      )}
    </div>
  )
}

// ============================================================================
// 建立續約草稿 Modal
// ============================================================================

function CreateRenewalDraftModal({ isOpen, onClose, contract, onSuccess }) {
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [error, setError] = useState(null)

  // 計算預設日期：原合約結束日 +1 為新開始日，+1年為新結束日
  const getDefaultDates = () => {
    if (!contract?.end_date) return { start: '', end: '' }
    const endDate = new Date(contract.end_date)
    const newStart = new Date(endDate)
    newStart.setDate(newStart.getDate() + 1)
    const newEnd = new Date(newStart)
    newEnd.setFullYear(newEnd.getFullYear() + 1)
    newEnd.setDate(newEnd.getDate() - 1)
    return {
      start: newStart.toISOString().split('T')[0],
      end: newEnd.toISOString().split('T')[0]
    }
  }

  const defaultDates = getDefaultDates()
  const [formData, setFormData] = useState({
    new_start_date: defaultDates.start,
    new_end_date: defaultDates.end,
    monthly_rent: contract?.monthly_rent || '',
    payment_cycle: contract?.payment_cycle || 'monthly',
    notes: ''
  })

  useEffect(() => {
    if (isOpen && contract) {
      const dates = getDefaultDates()
      setFormData({
        new_start_date: dates.start,
        new_end_date: dates.end,
        monthly_rent: contract.monthly_rent || '',
        payment_cycle: contract.payment_cycle || 'monthly',
        notes: ''
      })
      setError(null)
    }
  }, [isOpen, contract])

  const handleSubmit = async (e) => {
    e.preventDefault()
    setIsSubmitting(true)
    setError(null)

    try {
      const response = await callTool('renewal_create_draft', {
        contract_id: contract.id,
        new_start_date: formData.new_start_date,
        new_end_date: formData.new_end_date,
        monthly_rent: parseFloat(formData.monthly_rent) || undefined,
        payment_cycle: formData.payment_cycle,
        notes: formData.notes || undefined
      })

      if (!response.success || !response.result?.success) {
        throw new Error(response.result?.error || response.error || '建立失敗')
      }

      onSuccess(response.result)
      onClose()
    } catch (err) {
      setError(err.message)
    } finally {
      setIsSubmitting(false)
    }
  }

  if (!isOpen) return null

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto">
      <div className="flex min-h-full items-center justify-center p-4">
        <div className="fixed inset-0 bg-black/50" onClick={onClose} />
        <div className="relative bg-white rounded-xl shadow-xl w-full max-w-md p-6">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-lg font-semibold text-gray-900">建立續約草稿</h2>
            <button
              onClick={onClose}
              className="p-1 hover:bg-gray-100 rounded-lg transition-colors"
            >
              <X className="w-5 h-5 text-gray-500" />
            </button>
          </div>

          <div className="mb-4 p-3 bg-blue-50 rounded-lg text-sm text-blue-700">
            <p>原合約：{contract?.contract_number}</p>
            <p>到期日：{contract?.end_date}</p>
          </div>

          {error && (
            <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">
              {error}
            </div>
          )}

          <form onSubmit={handleSubmit} className="space-y-4">
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  新合約開始日
                </label>
                <input
                  type="date"
                  value={formData.new_start_date}
                  onChange={(e) => setFormData({ ...formData, new_start_date: e.target.value })}
                  className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
                  required
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  新合約結束日
                </label>
                <input
                  type="date"
                  value={formData.new_end_date}
                  onChange={(e) => setFormData({ ...formData, new_end_date: e.target.value })}
                  className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
                  required
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                月租金
              </label>
              <input
                type="number"
                value={formData.monthly_rent}
                onChange={(e) => setFormData({ ...formData, monthly_rent: e.target.value })}
                className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
                placeholder="沿用原金額"
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                繳費週期
              </label>
              <select
                value={formData.payment_cycle}
                onChange={(e) => setFormData({ ...formData, payment_cycle: e.target.value })}
                className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
              >
                <option value="monthly">月繳</option>
                <option value="quarterly">季繳</option>
                <option value="semi_annual">半年繳</option>
                <option value="annual">年繳</option>
                <option value="biennial">兩年繳</option>
              </select>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                備註
              </label>
              <textarea
                value={formData.notes}
                onChange={(e) => setFormData({ ...formData, notes: e.target.value })}
                className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
                rows={2}
                placeholder="選填"
              />
            </div>

            <div className="flex justify-end gap-3 pt-4">
              <button
                type="button"
                onClick={onClose}
                className="px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 rounded-lg hover:bg-gray-200 transition-colors"
              >
                取消
              </button>
              <button
                type="submit"
                disabled={isSubmitting}
                className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 transition-colors disabled:opacity-50"
              >
                {isSubmitting ? (
                  <span className="flex items-center gap-2">
                    <Loader2 className="w-4 h-4 animate-spin" />
                    建立中...
                  </span>
                ) : (
                  '建立草稿'
                )}
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
  )
}

// ============================================================================
// 合約歷史鏈元件
// ============================================================================

function ContractHistoryChain({ currentContract, prevContractId, nextContract }) {
  const hasPrev = !!prevContractId
  const hasNext = !!nextContract

  if (!hasPrev && !hasNext) {
    return null
  }

  return (
    <div className="bg-white rounded-xl border shadow-sm p-4">
      <div className="flex items-center gap-2 mb-3">
        <History className="w-4 h-4 text-gray-500" />
        <h3 className="text-sm font-medium text-gray-700">合約歷史</h3>
      </div>

      <div className="flex items-center justify-center gap-2">
        {/* 前一期 */}
        {hasPrev ? (
          <Link
            to={`/contracts/${prevContractId}/workspace`}
            className="flex items-center gap-1 px-3 py-1.5 text-xs bg-gray-100 hover:bg-gray-200 rounded-lg transition-colors"
          >
            <ChevronLeft className="w-3 h-3" />
            <span>上一期</span>
          </Link>
        ) : (
          <div className="w-16" />
        )}

        {/* 當前合約 */}
        <div className="flex-1 text-center">
          <div className="inline-flex items-center gap-2 px-4 py-2 bg-primary-50 border-2 border-primary-200 rounded-lg">
            <span className="text-sm font-medium text-primary-700">
              {currentContract.contract_number}
            </span>
            {currentContract.contract_period && (
              <span className="text-xs px-1.5 py-0.5 bg-primary-100 text-primary-600 rounded">
                第 {currentContract.contract_period} 期
              </span>
            )}
          </div>
          <p className="text-xs text-gray-500 mt-1">
            {currentContract.start_date} ~ {currentContract.end_date}
          </p>
        </div>

        {/* 下一期 */}
        {hasNext ? (
          <Link
            to={`/contracts/${nextContract.id}/workspace`}
            className="flex items-center gap-1 px-3 py-1.5 text-xs bg-green-100 hover:bg-green-200 text-green-700 rounded-lg transition-colors"
          >
            <span>下一期</span>
            <ChevronRight className="w-3 h-3" />
          </Link>
        ) : (
          <div className="w-16" />
        )}
      </div>

      {/* 狀態提示 */}
      {hasNext && nextContract.status && (
        <p className="text-center text-xs text-gray-500 mt-2">
          下一期狀態：
          <span className={`ml-1 font-medium ${
            nextContract.status === 'active' ? 'text-green-600' :
            nextContract.status === 'pending_sign' ? 'text-yellow-600' :
            nextContract.status === 'renewal_draft' ? 'text-blue-600' :
            'text-gray-600'
          }`}>
            {nextContract.status}
          </span>
        </p>
      )}
    </div>
  )
}

// ============================================================================
// 主頁面元件
// ============================================================================

export default function ContractWorkspace() {
  const { id } = useParams()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const contractId = parseInt(id)

  // Modal 狀態
  const [showCreateDraftModal, setShowCreateDraftModal] = useState(false)
  const [actionLoading, setActionLoading] = useState(false)

  // Action 處理
  const handleAction = async (actionKey, targetId) => {
    setActionLoading(true)
    try {
      let response
      switch (actionKey) {
        case 'create_draft':
          // 簡化流程：直接導航到合約建立頁面，帶入續約來源
          navigate(`/contracts/new?renew_from=${contractId}`)
          setActionLoading(false)
          return

        case 'send_for_sign':
          response = await callTool('renewal_send_for_sign', { contract_id: targetId })
          break

        case 'mark_signed':
          response = await callTool('renewal_mark_signed', {
            contract_id: targetId,
            auto_activate: false
          })
          break

        case 'activate':
          response = await callTool('renewal_activate', { draft_id: targetId })
          break

        case 'send_reminder':
          alert('提醒功能開發中')
          setActionLoading(false)
          return

        default:
          console.warn('Unknown action:', actionKey)
          setActionLoading(false)
          return
      }

      if (!response?.success || !response?.result?.success) {
        throw new Error(response?.result?.error || response?.error || '操作失敗')
      }

      // 成功後重新載入
      queryClient.invalidateQueries(['contract-timeline', contractId])
      refetch()
    } catch (err) {
      alert(`錯誤：${err.message}`)
    } finally {
      setActionLoading(false)
    }
  }

  // 草稿建立成功回呼
  const handleDraftCreated = (result) => {
    queryClient.invalidateQueries(['contract-timeline', contractId])
    refetch()
    // 可選：跳轉到新草稿
    if (result.draft_id) {
      navigate(`/contracts/${result.draft_id}/workspace`)
    }
  }

  // 呼叫 Timeline API
  const { data, isLoading, error, refetch } = useQuery({
    queryKey: ['contract-timeline', contractId],
    queryFn: async () => {
      const response = await callTool('contract_get_timeline', { contract_id: contractId })
      // callTool 回傳 { success, tool, result }
      // result 內才是實際資料 { success, contract, timeline, decision, ... }
      if (!response.success || !response.result?.success) {
        throw new Error(response.result?.error || response.error || '取得合約資料失敗')
      }
      return response.result
    },
    enabled: !!contractId
  })

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 className="w-8 h-8 animate-spin text-primary-500" />
      </div>
    )
  }

  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-6 text-center">
        <XCircle className="w-12 h-12 text-red-400 mx-auto mb-4" />
        <h3 className="text-lg font-medium text-red-800">載入失敗</h3>
        <p className="text-red-600 mt-2">{error.message}</p>
        <button
          onClick={() => refetch()}
          className="mt-4 btn-primary"
        >
          重試
        </button>
      </div>
    )
  }

  const { contract, timeline, decision, next_contract, prev_contract_id } = data

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-4">
          <button
            onClick={() => navigate(-1)}
            className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
          >
            <ArrowLeft className="w-5 h-5 text-gray-500" />
          </button>
          <div>
            <div className="flex items-center gap-3">
              <h1 className="text-2xl font-bold text-gray-900">
                {contract.contract_number}
              </h1>
              <Badge variant={contract.status === 'active' ? 'success' : 'gray'}>
                {contract.status}
              </Badge>
            </div>
            <p className="text-gray-500 mt-1">
              {contract.customer_name}
              {contract.company_name && ` - ${contract.company_name}`}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          <Link
            to={`/contracts/${contractId}`}
            className="btn-secondary"
          >
            <FileText className="w-4 h-4 mr-1" />
            合約詳情
          </Link>
        </div>
      </div>

      {/* 合約資訊卡片 */}
      <div className="bg-white rounded-xl border shadow-sm p-6">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-6">
          <div className="flex items-center gap-3">
            <div className="p-2 bg-blue-100 rounded-lg">
              <Calendar className="w-5 h-5 text-blue-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">合約期間</p>
              <p className="font-medium">{contract.start_date} ~ {contract.end_date}</p>
            </div>
          </div>

          <div className="flex items-center gap-3">
            <div className="p-2 bg-orange-100 rounded-lg">
              <Clock className="w-5 h-5 text-orange-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">剩餘天數</p>
              <p className={`font-medium ${contract.days_until_expiry < 0 ? 'text-red-600' : contract.days_until_expiry <= 30 ? 'text-orange-600' : ''}`}>
                {contract.days_until_expiry < 0
                  ? `已過期 ${Math.abs(contract.days_until_expiry)} 天`
                  : `${contract.days_until_expiry} 天`}
              </p>
            </div>
          </div>

          {contract.monthly_rent && (
            <div className="flex items-center gap-3">
              <div className="p-2 bg-green-100 rounded-lg">
                <DollarSign className="w-5 h-5 text-green-600" />
              </div>
              <div>
                <p className="text-sm text-gray-500">月租金</p>
                <p className="font-medium">${contract.monthly_rent?.toLocaleString()}</p>
              </div>
            </div>
          )}

          {contract.contract_period && (
            <div className="flex items-center gap-3">
              <div className="p-2 bg-purple-100 rounded-lg">
                <History className="w-5 h-5 text-purple-600" />
              </div>
              <div>
                <p className="text-sm text-gray-500">合約期數</p>
                <p className="font-medium">第 {contract.contract_period} 期</p>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* 主要內容：Timeline + Decision */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Timeline - 使用通用 ProcessTimeline 組件 */}
        <div className="lg:col-span-2 bg-white rounded-xl border shadow-sm p-6">
          <h2 className="text-lg font-semibold text-gray-900 mb-6">狀態時間線</h2>
          <ProcessTimeline
            steps={timeline}
            currentStep={decision?.blocked_by ? timeline.find(t => t.status === 'pending' || t.status === 'blocked')?.key : null}
            renderDetails={renderRenewalTimelineDetails}
          />
        </div>

        {/* Decision Panel + 繳費週期 */}
        <div className="space-y-6">
          {/* 合約歷史鏈 */}
          <ContractHistoryChain
            currentContract={contract}
            prevContractId={prev_contract_id}
            nextContract={next_contract}
          />

          {/* Decision Panel（含動作按鈕） */}
          <div className="bg-white rounded-xl border shadow-sm p-6">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">目前狀態</h2>
            <DecisionPanel
              decision={decision}
              contract={contract}
              nextContract={next_contract}
              onAction={handleAction}
              isLoading={actionLoading}
            />
          </div>

          {/* 繳費週期 */}
          <BillingCyclesPanel contractId={contractId} />

          {/* 快速操作 */}
          <div className="bg-white rounded-xl border shadow-sm p-6">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">快速跳轉</h2>
            <div className="space-y-2">
              <Link
                to="/renewals"
                className="flex items-center justify-between p-3 rounded-lg hover:bg-gray-50 transition-colors"
              >
                <div className="flex items-center gap-2">
                  <Bell className="w-4 h-4 text-gray-400" />
                  <span className="text-sm">續約追蹤</span>
                </div>
                <ExternalLink className="w-4 h-4 text-gray-400" />
              </Link>

              <Link
                to={`/payments?contract_id=${contractId}`}
                className="flex items-center justify-between p-3 rounded-lg hover:bg-gray-50 transition-colors"
              >
                <div className="flex items-center gap-2">
                  <Receipt className="w-4 h-4 text-gray-400" />
                  <span className="text-sm">付款管理</span>
                </div>
                <ExternalLink className="w-4 h-4 text-gray-400" />
              </Link>

              <Link
                to={`/invoices?contract_id=${contractId}`}
                className="flex items-center justify-between p-3 rounded-lg hover:bg-gray-50 transition-colors"
              >
                <div className="flex items-center gap-2">
                  <FileText className="w-4 h-4 text-gray-400" />
                  <span className="text-sm">發票系統</span>
                </div>
                <ExternalLink className="w-4 h-4 text-gray-400" />
              </Link>
            </div>
          </div>
        </div>
      </div>

      {/* 建立續約草稿 Modal */}
      <CreateRenewalDraftModal
        isOpen={showCreateDraftModal}
        onClose={() => setShowCreateDraftModal(false)}
        contract={contract}
        onSuccess={handleDraftCreated}
      />
    </div>
  )
}
