import { useState, useEffect } from 'react'
import { useParams, useNavigate, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { callTool } from '../services/api'
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
  Building2,
  Calendar,
  User,
  Phone,
  Mail,
  Loader2,
  XCircle,
  Circle
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
              {item.days_pending && <p className="text-yellow-600">已等待 {item.days_pending} 天</p>}
              {item.next_signed_at && <p>簽署時間：{new Date(item.next_signed_at).toLocaleString('zh-TW')}</p>}
            </>
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
    signing_overdue: '回簽逾期（超過 14 天）',
    payment_pending: '款項未入帳',
    invoice_pending: '發票未開立'
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
      const result = await callTool('contract_get_timeline', { contract_id: contractId })
      if (!result.success) {
        throw new Error(result.error || '取得合約資料失敗')
      }
      return result
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

        {/* Decision Panel */}
        <div className="space-y-6">
          <div className="bg-white rounded-xl border shadow-sm p-6">
            <h2 className="text-lg font-semibold text-gray-900 mb-4">目前狀態</h2>
            <DecisionPanel decision={decision} />
          </div>

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
