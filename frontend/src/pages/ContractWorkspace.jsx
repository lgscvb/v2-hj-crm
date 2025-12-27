import { useState, useEffect } from 'react'
import { useParams, useNavigate, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { callTool } from '../services/api'
import { useContractBillingCycles, useContractBillingSummary } from '../hooks/useApi'
import Badge from '../components/Badge'
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
  ChevronDown,
  ChevronUp,
  Building2,
  Calendar,
  User,
  Phone,
  Mail,
  Loader2,
  XCircle,
  Circle,
  CreditCard,
  DollarSign
} from 'lucide-react'

// ============================================================================
// Timeline 節點元件
// ============================================================================

const STATUS_CONFIG = {
  done: { icon: CheckCircle, color: 'text-green-500', bg: 'bg-green-100', label: '完成' },
  pending: { icon: Clock, color: 'text-yellow-500', bg: 'bg-yellow-100', label: '進行中' },
  blocked: { icon: XCircle, color: 'text-red-500', bg: 'bg-red-100', label: '阻塞' },
  draft: { icon: FileText, color: 'text-blue-500', bg: 'bg-blue-100', label: '草稿' },
  not_started: { icon: Circle, color: 'text-gray-400', bg: 'bg-gray-100', label: '未開始' },
  not_created: { icon: Circle, color: 'text-gray-400', bg: 'bg-gray-100', label: '未建立' },
  'n/a': { icon: Circle, color: 'text-gray-300', bg: 'bg-gray-50', label: '不適用' },
  unknown: { icon: AlertTriangle, color: 'text-gray-400', bg: 'bg-gray-100', label: '未知' }
}

function TimelineNode({ item, isLast }) {
  const config = STATUS_CONFIG[item.status] || STATUS_CONFIG.unknown
  const Icon = config.icon

  return (
    <div className="flex gap-4">
      {/* 左側：圖示和連接線 */}
      <div className="flex flex-col items-center">
        <div className={`w-10 h-10 rounded-full ${config.bg} flex items-center justify-center`}>
          <Icon className={`w-5 h-5 ${config.color}`} />
        </div>
        {!isLast && (
          <div className="w-0.5 h-full bg-gray-200 my-2" />
        )}
      </div>

      {/* 右側：內容 */}
      <div className="flex-1 pb-6">
        <div className="flex items-center justify-between">
          <h4 className="font-medium text-gray-900">{item.label}</h4>
          <Badge variant={item.status === 'done' ? 'success' : item.status === 'blocked' ? 'danger' : 'gray'}>
            {config.label}
          </Badge>
        </div>

        {/* 詳細資訊 */}
        <div className="mt-2 text-sm text-gray-500 space-y-1">
          {item.key === 'intent' && (
            <>
              {item.notified_at && <p>通知時間：{new Date(item.notified_at).toLocaleString('zh-TW')}</p>}
              {item.confirmed_at && <p>確認時間：{new Date(item.confirmed_at).toLocaleString('zh-TW')}</p>}
            </>
          )}
          {item.key === 'signing' && item.next_contract_id && (
            <>
              <p>續約合約 ID：{item.next_contract_id}</p>
              {item.sent_for_sign_at && <p>送簽時間：{new Date(item.sent_for_sign_at).toLocaleString('zh-TW')}</p>}
              {item.days_pending > 0 && !item.next_signed_at && (
                <p className={item.days_pending > 14 ? "text-red-600 font-medium" : "text-yellow-600"}>
                  已等待 {item.days_pending} 天{item.days_pending > 14 && '（逾期）'}
                </p>
              )}
              {item.next_signed_at && <p className="text-green-600">簽署時間：{new Date(item.next_signed_at).toLocaleString('zh-TW')}</p>}
            </>
          )}
          {item.key === 'signing' && !item.next_contract_id && item.status === 'not_created' && (
            <p className="text-gray-400">尚未建立續約合約</p>
          )}
          {item.key === 'payment' && (
            <>
              {item.payment_status && <p>狀態：{item.payment_status}</p>}
              {item.paid_at && <p>付款時間：{new Date(item.paid_at).toLocaleString('zh-TW')}</p>}
            </>
          )}
          {item.key === 'invoice' && (
            <>
              {item.invoice_number && <p>發票號碼：{item.invoice_number}</p>}
              {item.invoice_status && <p>狀態：{item.invoice_status}</p>}
            </>
          )}
          {item.key === 'activation' && item.next_status && (
            <p>合約狀態：{item.next_status}</p>
          )}
        </div>
      </div>
    </div>
  )
}

// ============================================================================
// Decision Panel 元件
// ============================================================================

function DecisionPanel({ decision }) {
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

  return (
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
// 主頁面元件
// ============================================================================

export default function ContractWorkspace() {
  const { id } = useParams()
  const navigate = useNavigate()
  const contractId = parseInt(id)

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

          {prev_contract_id && (
            <div className="flex items-center gap-3">
              <div className="p-2 bg-gray-100 rounded-lg">
                <ArrowLeft className="w-5 h-5 text-gray-600" />
              </div>
              <div>
                <p className="text-sm text-gray-500">上一期合約</p>
                <Link
                  to={`/contracts/${prev_contract_id}/workspace`}
                  className="font-medium text-primary-600 hover:underline"
                >
                  #{prev_contract_id}
                </Link>
              </div>
            </div>
          )}

          {next_contract && (
            <div className="flex items-center gap-3">
              <div className="p-2 bg-green-100 rounded-lg">
                <ChevronRight className="w-5 h-5 text-green-600" />
              </div>
              <div>
                <p className="text-sm text-gray-500">續約合約</p>
                <Link
                  to={`/contracts/${next_contract.id}/workspace`}
                  className="font-medium text-primary-600 hover:underline"
                >
                  #{next_contract.id} ({next_contract.status})
                </Link>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* 主要內容：Timeline + Decision */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Timeline */}
        <div className="lg:col-span-2 bg-white rounded-xl border shadow-sm p-6">
          <h2 className="text-lg font-semibold text-gray-900 mb-6">狀態時間線</h2>
          <div className="space-y-0">
            {timeline.map((item, index) => (
              <TimelineNode
                key={item.key}
                item={item}
                isLast={index === timeline.length - 1}
              />
            ))}
          </div>
        </div>

        {/* Decision Panel + 繳費週期 */}
        <div className="space-y-6">
          <div className="bg-white rounded-xl border shadow-sm p-6">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">目前狀態</h2>
            <DecisionPanel decision={decision} />
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
                to="/payments"
                className="flex items-center justify-between p-3 rounded-lg hover:bg-gray-50 transition-colors"
              >
                <div className="flex items-center gap-2">
                  <Receipt className="w-4 h-4 text-gray-400" />
                  <span className="text-sm">付款管理</span>
                </div>
                <ExternalLink className="w-4 h-4 text-gray-400" />
              </Link>

              <Link
                to="/invoices"
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
    </div>
  )
}
