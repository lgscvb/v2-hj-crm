/**
 * IntegrityAlerts - 資料完整性告警頁面
 *
 * 顯示 data_integrity_alerts 表中的未解決告警
 * 可按嚴重度篩選，並提供解決功能
 */

import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  ShieldAlert,
  AlertTriangle,
  AlertCircle,
  Info,
  CheckCircle,
  RefreshCw,
  ExternalLink,
  Filter,
  Clock,
  Database
} from 'lucide-react'
import { db } from '../services/api'
import { Link } from 'react-router-dom'

// 嚴重度配置
const SEVERITY_CONFIG = {
  high: {
    label: '高',
    icon: AlertTriangle,
    color: 'text-red-600',
    bg: 'bg-red-50',
    border: 'border-red-200',
    badge: 'bg-red-100 text-red-800'
  },
  medium: {
    label: '中',
    icon: AlertCircle,
    color: 'text-amber-600',
    bg: 'bg-amber-50',
    border: 'border-amber-200',
    badge: 'bg-amber-100 text-amber-800'
  },
  low: {
    label: '低',
    icon: Info,
    color: 'text-blue-600',
    bg: 'bg-blue-50',
    border: 'border-blue-200',
    badge: 'bg-blue-100 text-blue-800'
  }
}

// Issue Key 中文對照
const ISSUE_LABELS = {
  active_but_expired: '合約已過期但狀態仍為 active',
  pending_sign_overdue: '待簽署超過 14 天',
  termination_case_not_pending: '解約案件與合約狀態不一致',
  pending_termination_no_case: '待解約合約缺少解約案件',
  deprecated_renewal_fields: '使用已棄用的 renewal_* 欄位',
  payment_paid_at_mismatch: '付款狀態與 paid_at 不一致',
  payment_invoice_link_missing: '付款發票連結缺失',
  payment_invoice_status_mismatch: '付款與發票狀態不一致',
  waive_payment_without_request: '減免付款缺少申請記錄',
  waive_request_not_applied: '減免申請未套用',
  commission_paid_at_mismatch: '佣金狀態與 paid_at 不一致',
  renewal_notice_sent_but_flag_missing: '續約通知已發但 flag 未設',
  renewal_flag_without_notice_log: '續約 flag 無通知記錄',
  orphan_renewed_from_id: '續約鏈斷裂',
  contract_period_mismatch: 'contract_period 不連續',
  contract_period_is_null: 'contract_period 為空'
}

export default function IntegrityAlerts() {
  const [severityFilter, setSeverityFilter] = useState('all')
  const [resolvingId, setResolvingId] = useState(null)
  const queryClient = useQueryClient()

  // 取得告警摘要
  const { data: summary, isLoading: summaryLoading, refetch: refetchSummary } = useQuery({
    queryKey: ['integrity-summary'],
    queryFn: () => db.query('v_integrity_alerts_summary')
  })

  // 取得告警列表
  const { data: alerts, isLoading: alertsLoading, refetch: refetchAlerts } = useQuery({
    queryKey: ['integrity-alerts', severityFilter],
    queryFn: async () => {
      const params = {
        resolved_at: 'is.null',
        order: 'detected_at.desc'
      }
      if (severityFilter !== 'all') {
        params.severity = `eq.${severityFilter}`
      }
      return db.query('data_integrity_alerts', params)
    }
  })

  // 執行檢查
  const runCheckMutation = useMutation({
    mutationFn: () => db.rpc('run_daily_integrity_check'),
    onSuccess: () => {
      refetchSummary()
      refetchAlerts()
    }
  })

  // 解決告警
  const resolveMutation = useMutation({
    mutationFn: async (alertId) => {
      return db.update('data_integrity_alerts', alertId, {
        resolved_at: new Date().toISOString(),
        resolved_by: 'admin'
      })
    },
    onSuccess: () => {
      setResolvingId(null)
      refetchSummary()
      refetchAlerts()
    }
  })

  // 計算統計
  const stats = {
    high: summary?.filter(s => s.severity === 'high').reduce((sum, s) => sum + s.open_count, 0) || 0,
    medium: summary?.filter(s => s.severity === 'medium').reduce((sum, s) => sum + s.open_count, 0) || 0,
    low: summary?.filter(s => s.severity === 'low').reduce((sum, s) => sum + s.open_count, 0) || 0
  }
  const totalAlerts = stats.high + stats.medium + stats.low

  // 取得實體連結
  const getEntityLink = (alert) => {
    const { entity_type, entity_id, contract_number } = alert
    switch (entity_type) {
      case 'contract':
        return `/contracts/${entity_id}`
      case 'payment':
        return `/payments?id=${entity_id}`
      case 'commission':
        return `/commissions?id=${entity_id}`
      case 'termination_case':
        return `/terminations?id=${entity_id}`
      default:
        return null
    }
  }

  const isLoading = summaryLoading || alertsLoading

  return (
    <div className="space-y-6">
      {/* 頁面標題 */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <ShieldAlert className="w-8 h-8 text-gray-700" />
          <div>
            <h1 className="text-2xl font-bold text-gray-900">資料完整性告警</h1>
            <p className="text-sm text-gray-500">監控系統資料一致性問題</p>
          </div>
        </div>
        <button
          onClick={() => runCheckMutation.mutate()}
          disabled={runCheckMutation.isPending}
          className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50"
        >
          <RefreshCw className={`w-4 h-4 ${runCheckMutation.isPending ? 'animate-spin' : ''}`} />
          執行檢查
        </button>
      </div>

      {/* 統計卡片 */}
      <div className="grid grid-cols-4 gap-4">
        {/* 總計 */}
        <div className="bg-white rounded-lg border p-4">
          <div className="flex items-center gap-3">
            <div className="p-2 bg-gray-100 rounded-lg">
              <Database className="w-5 h-5 text-gray-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">未解決總數</p>
              <p className="text-2xl font-bold text-gray-900">{totalAlerts}</p>
            </div>
          </div>
        </div>

        {/* High */}
        <div className={`rounded-lg border p-4 ${SEVERITY_CONFIG.high.bg} ${SEVERITY_CONFIG.high.border}`}>
          <div className="flex items-center gap-3">
            <div className="p-2 bg-red-100 rounded-lg">
              <AlertTriangle className="w-5 h-5 text-red-600" />
            </div>
            <div>
              <p className="text-sm text-red-600">高優先級</p>
              <p className="text-2xl font-bold text-red-700">{stats.high}</p>
            </div>
          </div>
        </div>

        {/* Medium */}
        <div className={`rounded-lg border p-4 ${SEVERITY_CONFIG.medium.bg} ${SEVERITY_CONFIG.medium.border}`}>
          <div className="flex items-center gap-3">
            <div className="p-2 bg-amber-100 rounded-lg">
              <AlertCircle className="w-5 h-5 text-amber-600" />
            </div>
            <div>
              <p className="text-sm text-amber-600">中優先級</p>
              <p className="text-2xl font-bold text-amber-700">{stats.medium}</p>
            </div>
          </div>
        </div>

        {/* Low */}
        <div className={`rounded-lg border p-4 ${SEVERITY_CONFIG.low.bg} ${SEVERITY_CONFIG.low.border}`}>
          <div className="flex items-center gap-3">
            <div className="p-2 bg-blue-100 rounded-lg">
              <Info className="w-5 h-5 text-blue-600" />
            </div>
            <div>
              <p className="text-sm text-blue-600">低優先級</p>
              <p className="text-2xl font-bold text-blue-700">{stats.low}</p>
            </div>
          </div>
        </div>
      </div>

      {/* 篩選 */}
      <div className="flex items-center gap-2">
        <Filter className="w-4 h-4 text-gray-400" />
        <span className="text-sm text-gray-500">篩選：</span>
        {['all', 'high', 'medium', 'low'].map((sev) => (
          <button
            key={sev}
            onClick={() => setSeverityFilter(sev)}
            className={`px-3 py-1 text-sm rounded-full transition-colors ${
              severityFilter === sev
                ? 'bg-gray-900 text-white'
                : 'bg-gray-100 text-gray-600 hover:bg-gray-200'
            }`}
          >
            {sev === 'all' ? '全部' : SEVERITY_CONFIG[sev].label}
          </button>
        ))}
      </div>

      {/* 告警列表 */}
      <div className="bg-white rounded-lg border">
        {isLoading ? (
          <div className="p-8 text-center text-gray-500">載入中...</div>
        ) : !alerts?.length ? (
          <div className="p-8 text-center">
            <CheckCircle className="w-12 h-12 text-green-500 mx-auto mb-3" />
            <p className="text-gray-600">目前沒有未解決的告警</p>
            <p className="text-sm text-gray-400 mt-1">系統資料狀態良好</p>
          </div>
        ) : (
          <table className="w-full">
            <thead className="bg-gray-50 border-b">
              <tr>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">嚴重度</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">問題類型</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">合約</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">詳情</th>
                <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">發現時間</th>
                <th className="px-4 py-3 text-center text-xs font-medium text-gray-500 uppercase">操作</th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {alerts.map((alert) => {
                const config = SEVERITY_CONFIG[alert.severity] || SEVERITY_CONFIG.low
                const SeverityIcon = config.icon
                const entityLink = getEntityLink(alert)

                return (
                  <tr key={alert.id} className="hover:bg-gray-50">
                    <td className="px-4 py-3">
                      <span className={`inline-flex items-center gap-1 px-2 py-1 rounded-full text-xs font-medium ${config.badge}`}>
                        <SeverityIcon className="w-3 h-3" />
                        {config.label}
                      </span>
                    </td>
                    <td className="px-4 py-3">
                      <div className="text-sm font-medium text-gray-900">
                        {ISSUE_LABELS[alert.issue_key] || alert.issue_key}
                      </div>
                      <div className="text-xs text-gray-400">{alert.issue_key}</div>
                    </td>
                    <td className="px-4 py-3">
                      {entityLink ? (
                        <Link
                          to={entityLink}
                          className="text-sm text-blue-600 hover:underline flex items-center gap-1"
                        >
                          {alert.contract_number || alert.entity_id}
                          <ExternalLink className="w-3 h-3" />
                        </Link>
                      ) : (
                        <span className="text-sm text-gray-500">
                          {alert.contract_number || alert.entity_id}
                        </span>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <pre className="text-xs text-gray-500 max-w-xs truncate">
                        {JSON.stringify(alert.details, null, 0)}
                      </pre>
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-1 text-xs text-gray-500">
                        <Clock className="w-3 h-3" />
                        {new Date(alert.detected_at).toLocaleString('zh-TW')}
                      </div>
                    </td>
                    <td className="px-4 py-3 text-center">
                      <button
                        onClick={() => {
                          setResolvingId(alert.id)
                          resolveMutation.mutate(alert.id)
                        }}
                        disabled={resolvingId === alert.id}
                        className="text-sm text-green-600 hover:text-green-800 disabled:opacity-50"
                      >
                        {resolvingId === alert.id ? '處理中...' : '標記已解決'}
                      </button>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>

      {/* 問題類型統計 */}
      {summary?.length > 0 && (
        <div className="bg-white rounded-lg border p-4">
          <h3 className="text-sm font-medium text-gray-700 mb-3">問題類型分布</h3>
          <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-2">
            {summary.map((item) => {
              const config = SEVERITY_CONFIG[item.severity] || SEVERITY_CONFIG.low
              return (
                <div
                  key={`${item.severity}-${item.issue_key}`}
                  className={`p-2 rounded border ${config.bg} ${config.border}`}
                >
                  <div className="flex items-center justify-between">
                    <span className="text-xs text-gray-600 truncate">
                      {ISSUE_LABELS[item.issue_key] || item.issue_key}
                    </span>
                    <span className={`text-sm font-bold ${config.color}`}>
                      {item.open_count}
                    </span>
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      )}
    </div>
  )
}
