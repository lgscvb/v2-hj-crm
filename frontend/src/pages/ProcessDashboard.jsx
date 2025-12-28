/**
 * ProcessDashboard - 流程管理總覽頁面
 *
 * Kanban 風格的流程看板，一眼可見所有待辦事項
 */

import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import {
  LayoutGrid,
  List,
  RefreshCw,
  Loader2,
  AlertTriangle,
  Clock,
  CheckCircle,
  TrendingUp
} from 'lucide-react'
import { db } from '../services/api'
import { ProcessKanban } from '../components/process'

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
        db.get('v_payment_dashboard_stats', {}),
        db.get('v_invoice_dashboard_stats', {}),
        db.get('v_commission_dashboard_stats', {})
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

      {/* 列表視圖（簡化版） */}
      {viewMode === 'list' && (
        <div className="bg-white rounded-lg border shadow-sm p-6">
          <p className="text-gray-500 text-center py-8">
            列表視圖開發中...
          </p>
        </div>
      )}
    </div>
  )
}
