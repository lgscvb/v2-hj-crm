/**
 * ProcessDashboard - 流程管理總覽頁面
 *
 * Kanban 風格的流程看板，一眼可見所有待辦事項
 */

import { useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import {
  LayoutGrid,
  List,
  RefreshCw,
  Loader2,
  AlertTriangle,
  Clock,
  CheckCircle,
  TrendingUp,
  ChevronRight,
  Flame,
  ExternalLink,
  RefreshCw as Refresh,
  CreditCard,
  FileText,
  Banknote
} from 'lucide-react'
import { db } from '../services/api'
import { ProcessKanban, PROCESS_ICONS, PRIORITY_COLORS, OWNER_COLORS } from '../components/process'

// 流程配置（與 ProcessKanban 一致）
const PROCESS_CONFIG = {
  renewal: {
    key: 'renewal',
    label: '續約',
    view: 'v_renewal_queue',  // 使用新的 queue 視圖（含 decision_priority）
    filter: {},
    order: 'decision_priority.asc,days_until_expiry.asc',
    color: 'blue',
    linkPrefix: '/contracts'
  },
  payment: {
    key: 'payment',
    label: '付款',
    view: 'v_payment_queue',
    filter: {},
    order: 'decision_priority.asc,is_overdue.desc',
    color: 'green',
    linkPrefix: '/payments'
  },
  invoice: {
    key: 'invoice',
    label: '發票',
    view: 'v_invoice_queue',
    filter: {},
    order: 'decision_priority.asc,is_overdue.desc',
    color: 'purple',
    linkPrefix: '/invoices'
  },
  commission: {
    key: 'commission',
    label: '佣金',
    view: 'v_commission_queue',
    filter: {},
    order: 'decision_priority.asc,is_overdue.desc',
    color: 'orange',
    linkPrefix: '/commissions'
  }
}

// 優先級排序權重
const PRIORITY_ORDER = { urgent: 0, high: 1, medium: 2, low: 3 }

/**
 * 列表視圖組件
 */
function ProcessListView({ onItemClick }) {
  const [filter, setFilter] = useState('all')  // all | renewal | payment | invoice | commission
  const [sortBy, setSortBy] = useState('priority')  // priority | due_date | process

  // 取得所有流程的資料
  const { data: allItems, isLoading, refetch } = useQuery({
    queryKey: ['process-list-all'],
    queryFn: async () => {
      const processKeys = ['renewal', 'payment', 'invoice', 'commission']
      const results = await Promise.all(
        processKeys.map(async (key) => {
          const config = PROCESS_CONFIG[key]
          try {
            const items = await db.query(config.view, {
              ...config.filter,
              order: config.order || 'created_at.desc',
              limit: 50
            })
            return (items || []).map(item => ({
              ...item,
              process_key: key,
              entity_id: item.entity_id || item.id || item.contract_id || item.payment_id,
              title: item.title || item.contract_number || item.customer_name || `#${item.entity_id}`,
            }))
          } catch (err) {
            console.error(`[ProcessListView] 載入 ${key} 失敗:`, err)
            return []
          }
        })
      )
      return results.flat()
    },
    refetchInterval: 60000
  })

  // 篩選
  const filteredItems = (allItems || []).filter(item => {
    if (filter === 'all') return true
    return item.process_key === filter
  })

  // 排序
  const sortedItems = [...filteredItems].sort((a, b) => {
    if (sortBy === 'priority') {
      const aPriority = PRIORITY_ORDER[a.decision_priority] ?? 99
      const bPriority = PRIORITY_ORDER[b.decision_priority] ?? 99
      if (aPriority !== bPriority) return aPriority - bPriority
      // 次要排序：逾期優先
      if (a.is_overdue && !b.is_overdue) return -1
      if (!a.is_overdue && b.is_overdue) return 1
      return 0
    }
    if (sortBy === 'due_date') {
      const aDate = a.due_date || a.decision_due_date || '9999-12-31'
      const bDate = b.due_date || b.decision_due_date || '9999-12-31'
      return aDate.localeCompare(bDate)
    }
    if (sortBy === 'process') {
      return a.process_key.localeCompare(b.process_key)
    }
    return 0
  })

  // 取得流程圖示
  const getProcessIcon = (processKey) => {
    return PROCESS_ICONS[processKey] || Clock
  }

  // 優先級標籤
  const getPriorityBadge = (priority) => {
    const config = PRIORITY_COLORS[priority] || PRIORITY_COLORS.medium
    const labels = { urgent: '緊急', high: '高', medium: '中', low: '低' }
    return (
      <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${config.badge}`}>
        {priority === 'urgent' && <Flame className="w-3 h-3 inline mr-0.5" />}
        {labels[priority] || priority}
      </span>
    )
  }

  // 責任人標籤
  const getOwnerBadge = (owner) => {
    if (!owner) return null
    const config = OWNER_COLORS[owner] || { bg: 'bg-gray-100', text: 'text-gray-700' }
    return (
      <span className={`text-xs px-2 py-0.5 rounded ${config.bg} ${config.text}`}>
        {owner}
      </span>
    )
  }

  if (isLoading) {
    return (
      <div className="bg-white rounded-lg border shadow-sm p-8">
        <div className="flex items-center justify-center">
          <Loader2 className="w-6 h-6 animate-spin text-gray-400" />
          <span className="ml-2 text-gray-500">載入中...</span>
        </div>
      </div>
    )
  }

  return (
    <div className="bg-white rounded-lg border shadow-sm">
      {/* 篩選與排序 */}
      <div className="p-4 border-b flex flex-wrap items-center justify-between gap-4">
        <div className="flex items-center gap-2">
          <span className="text-sm text-gray-500">流程：</span>
          <div className="flex items-center bg-gray-100 rounded-lg p-1">
            {[
              { key: 'all', label: '全部' },
              { key: 'renewal', label: '續約' },
              { key: 'payment', label: '付款' },
              { key: 'invoice', label: '發票' },
              { key: 'commission', label: '佣金' }
            ].map(opt => (
              <button
                key={opt.key}
                onClick={() => setFilter(opt.key)}
                className={`px-3 py-1 text-sm rounded ${filter === opt.key ? 'bg-white shadow-sm font-medium' : 'text-gray-600 hover:text-gray-900'}`}
              >
                {opt.label}
              </button>
            ))}
          </div>
        </div>

        <div className="flex items-center gap-4">
          <div className="flex items-center gap-2">
            <span className="text-sm text-gray-500">排序：</span>
            <select
              value={sortBy}
              onChange={(e) => setSortBy(e.target.value)}
              className="text-sm border rounded-lg px-2 py-1"
            >
              <option value="priority">優先級</option>
              <option value="due_date">到期日</option>
              <option value="process">流程類型</option>
            </select>
          </div>

          <button
            onClick={() => refetch()}
            className="p-1.5 hover:bg-gray-100 rounded-lg transition-colors"
            title="重新整理"
          >
            <RefreshCw className="w-4 h-4 text-gray-500" />
          </button>
        </div>
      </div>

      {/* 表格 */}
      <div className="overflow-x-auto">
        <table className="w-full">
          <thead className="bg-gray-50 text-left text-sm text-gray-500">
            <tr>
              <th className="px-4 py-3 font-medium">流程</th>
              <th className="px-4 py-3 font-medium">標題</th>
              <th className="px-4 py-3 font-medium">卡點</th>
              <th className="px-4 py-3 font-medium">優先級</th>
              <th className="px-4 py-3 font-medium">責任人</th>
              <th className="px-4 py-3 font-medium">到期日</th>
              <th className="px-4 py-3 font-medium">操作</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100">
            {sortedItems.length === 0 ? (
              <tr>
                <td colSpan={7} className="px-4 py-8 text-center text-gray-500">
                  <CheckCircle className="w-8 h-8 mx-auto mb-2 text-green-400" />
                  無待辦事項
                </td>
              </tr>
            ) : (
              sortedItems.map((item, idx) => {
                const ProcessIcon = getProcessIcon(item.process_key)
                const config = PROCESS_CONFIG[item.process_key]
                const dueDate = item.due_date || item.decision_due_date

                return (
                  <tr
                    key={`${item.process_key}-${item.entity_id}-${idx}`}
                    className={`hover:bg-gray-50 ${item.is_overdue ? 'bg-red-50/50' : ''}`}
                  >
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-2">
                        <ProcessIcon className={`w-4 h-4 text-${config.color}-500`} />
                        <span className="text-sm font-medium">{config.label}</span>
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      <div>
                        <p className="text-sm font-medium text-gray-900">{item.title}</p>
                        {item.customer_name && item.title !== item.customer_name && (
                          <p className="text-xs text-gray-500">{item.customer_name}</p>
                        )}
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      <p className="text-sm text-gray-700">{item.decision_next_action || item.decision_blocked_by || '-'}</p>
                    </td>
                    <td className="px-4 py-3">
                      {getPriorityBadge(item.decision_priority)}
                    </td>
                    <td className="px-4 py-3">
                      {getOwnerBadge(item.decision_owner)}
                    </td>
                    <td className="px-4 py-3">
                      <div className="text-sm">
                        {dueDate ? (
                          <>
                            <span className={item.is_overdue ? 'text-red-600 font-medium' : ''}>
                              {new Date(dueDate).toLocaleDateString('zh-TW')}
                            </span>
                            {item.is_overdue && item.overdue_days > 0 && (
                              <span className="text-xs text-red-500 ml-1">
                                (逾期 {item.overdue_days} 天)
                              </span>
                            )}
                          </>
                        ) : (
                          <span className="text-gray-400">-</span>
                        )}
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      <button
                        onClick={() => onItemClick(item)}
                        className="inline-flex items-center gap-1 px-2 py-1 text-sm text-primary-600 hover:text-primary-700 hover:bg-primary-50 rounded transition-colors"
                      >
                        處理
                        <ChevronRight className="w-4 h-4" />
                      </button>
                    </td>
                  </tr>
                )
              })
            )}
          </tbody>
        </table>
      </div>

      {/* 底部統計 */}
      <div className="p-4 border-t bg-gray-50 text-center text-sm text-gray-500">
        共 {sortedItems.length} 項待處理
      </div>
    </div>
  )
}

/**
 * 統計卡片
 */
function StatCard({ label, value, icon: Icon, color, subtext }) {
  const colorClasses = {
    blue: 'bg-blue-50 text-blue-700 border-blue-200',
    green: 'bg-green-50 text-green-700 border-green-200',
    orange: 'bg-orange-50 text-orange-700 border-orange-200',
    red: 'bg-red-50 text-red-700 border-red-200',
    gray: 'bg-gray-50 text-gray-700 border-gray-200'
  }

  return (
    <div className={`rounded-lg border p-4 ${colorClasses[color] || colorClasses.gray}`}>
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium opacity-80">{label}</p>
          <p className="text-2xl font-bold mt-1">{value}</p>
          {subtext && <p className="text-xs mt-1 opacity-70">{subtext}</p>}
        </div>
        {Icon && <Icon className="w-8 h-8 opacity-50" />}
      </div>
    </div>
  )
}

/**
 * 主頁面
 */
export default function ProcessDashboard() {
  const navigate = useNavigate()
  const [viewMode, setViewMode] = useState('kanban')  // kanban | list

  // 取得統計資料
  const { data: stats, isLoading: statsLoading, refetch: refetchStats } = useQuery({
    queryKey: ['process-dashboard-stats'],
    queryFn: async () => {
      const [payment, invoice, commission] = await Promise.all([
        db.query('v_payment_dashboard_stats', {}),
        db.query('v_invoice_dashboard_stats', {}),
        db.query('v_commission_dashboard_stats', {})
      ])

      return {
        payment: payment?.[0] || {},
        invoice: invoice?.[0] || {},
        commission: commission?.[0] || {}
      }
    },
    refetchInterval: 60000
  })

  // 計算總待辦
  const totalActionNeeded = (
    (stats?.payment?.total_action_needed || 0) +
    (stats?.invoice?.total_action_needed || 0) +
    (stats?.commission?.ready_to_pay_count || 0)
  )

  const totalOverdue = (
    (stats?.payment?.overdue_count || 0) +
    (stats?.invoice?.overdue_count || 0) +
    (stats?.commission?.overdue_count || 0)
  )

  const totalUrgent = (
    (stats?.payment?.urgent_count || 0)
  )

  // 點擊項目時跳轉
  const handleItemClick = (item) => {
    if (item.workspace_url) {
      navigate(item.workspace_url)
    } else if (item.process_key === 'payment' && item.payment_id) {
      navigate(`/payments?id=${item.payment_id}`)
    } else if (item.process_key === 'invoice' && item.payment_id) {
      navigate(`/payments/${item.payment_id}/invoice`)
    } else if (item.process_key === 'renewal' && item.contract_id) {
      navigate(`/contracts/${item.contract_id}/workspace`)
    }
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">流程看板</h1>
          <p className="text-gray-500 mt-1">所有待辦事項一覽</p>
        </div>

        <div className="flex items-center gap-2">
          {/* 視圖切換 */}
          <div className="flex items-center bg-gray-100 rounded-lg p-1">
            <button
              onClick={() => setViewMode('kanban')}
              className={`p-2 rounded ${viewMode === 'kanban' ? 'bg-white shadow-sm' : ''}`}
              title="看板視圖"
            >
              <LayoutGrid className="w-4 h-4" />
            </button>
            <button
              onClick={() => setViewMode('list')}
              className={`p-2 rounded ${viewMode === 'list' ? 'bg-white shadow-sm' : ''}`}
              title="列表視圖"
            >
              <List className="w-4 h-4" />
            </button>
          </div>

          {/* 刷新按鈕 */}
          <button
            onClick={() => refetchStats()}
            className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
            title="重新整理"
          >
            <RefreshCw className="w-5 h-5 text-gray-500" />
          </button>
        </div>
      </div>

      {/* 統計卡片 */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <StatCard
          label="待處理"
          value={statsLoading ? '...' : totalActionNeeded}
          icon={Clock}
          color="blue"
        />
        <StatCard
          label="逾期"
          value={statsLoading ? '...' : totalOverdue}
          icon={AlertTriangle}
          color={totalOverdue > 0 ? 'red' : 'gray'}
        />
        <StatCard
          label="緊急"
          value={statsLoading ? '...' : totalUrgent}
          icon={AlertTriangle}
          color={totalUrgent > 0 ? 'orange' : 'gray'}
        />
        <StatCard
          label="待開票金額"
          value={statsLoading ? '...' : `$${(stats?.invoice?.total_pending_amount || 0).toLocaleString()}`}
          icon={TrendingUp}
          color="green"
        />
      </div>

      {/* 詳細統計 */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        {/* 付款統計 */}
        <div className="bg-white rounded-lg border shadow-sm p-4">
          <h3 className="font-semibold text-gray-700 mb-3">付款流程</h3>
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-gray-500">需催繳</span>
              <span className="font-medium">{stats?.payment?.need_reminder_count || 0}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">嚴重逾期</span>
              <span className="font-medium text-red-600">{stats?.payment?.severe_overdue_count || 0}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">需存證信函</span>
              <span className="font-medium text-red-600">{stats?.payment?.need_legal_count || 0}</span>
            </div>
          </div>
        </div>

        {/* 發票統計 */}
        <div className="bg-white rounded-lg border shadow-sm p-4">
          <h3 className="font-semibold text-gray-700 mb-3">發票流程</h3>
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-gray-500">缺統編</span>
              <span className="font-medium text-orange-600">{stats?.invoice?.need_tax_id_count || 0}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">待開票</span>
              <span className="font-medium">{stats?.invoice?.pending_count || 0}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">開票逾期</span>
              <span className="font-medium text-red-600">{stats?.invoice?.overdue_count || 0}</span>
            </div>
          </div>
        </div>

        {/* 佣金統計 */}
        <div className="bg-white rounded-lg border shadow-sm p-4">
          <h3 className="font-semibold text-gray-700 mb-3">佣金流程</h3>
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-gray-500">待付款</span>
              <span className="font-medium">{stats?.commission?.ready_to_pay_count || 0}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">付款逾期</span>
              <span className="font-medium text-red-600">{stats?.commission?.overdue_count || 0}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-500">待付金額</span>
              <span className="font-medium text-green-600">
                ${(stats?.commission?.total_eligible_amount || 0).toLocaleString()}
              </span>
            </div>
          </div>
        </div>
      </div>

      {/* Kanban 看板 */}
      {viewMode === 'kanban' && (
        <ProcessKanban
          processes={['renewal', 'payment', 'invoice', 'commission']}
          onItemClick={handleItemClick}
          maxItemsPerColumn={5}
        />
      )}

      {/* 列表視圖 */}
      {viewMode === 'list' && (
        <ProcessListView onItemClick={handleItemClick} />
      )}
    </div>
  )
}
