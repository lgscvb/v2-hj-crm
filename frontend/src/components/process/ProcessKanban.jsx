/**
 * ProcessKanban - 流程 Kanban 看板組件
 *
 * 以 Kanban 形式顯示所有流程的待辦事項
 * 每個流程一欄，按優先級排序
 *
 * @example
 * <ProcessKanban
 *   processes={['renewal', 'payment', 'invoice']}
 *   onItemClick={(item) => navigate(item.workspace_url)}
 * />
 */

import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import {
  Loader2,
  ChevronRight,
  AlertTriangle,
  Clock,
  Flame,
  RefreshCw
} from 'lucide-react'
import { db } from '../../services/api'
import { PROCESS_ICONS, PRIORITY_COLORS } from './index'
import ProcessCard from './ProcessCard'

// 流程配置
const PROCESS_CONFIG = {
  renewal: {
    key: 'renewal',
    label: '續約流程',
    view: 'v_contract_workspace',
    filter: { decision_blocked_by: 'not.is.null' },
    color: 'blue'
  },
  payment: {
    key: 'payment',
    label: '付款流程',
    view: 'v_payment_queue',
    filter: {},
    color: 'green'
  },
  invoice: {
    key: 'invoice',
    label: '發票流程',
    view: 'v_invoice_queue',
    filter: {},
    color: 'purple'
  },
  commission: {
    key: 'commission',
    label: '佣金流程',
    view: 'v_commission_queue',
    filter: {},
    color: 'orange'
  },
  termination: {
    key: 'termination',
    label: '解約流程',
    view: 'v_termination_workspace',
    filter: { status: 'neq.completed' },
    color: 'red'
  }
}

// 欄位顏色
const COLUMN_COLORS = {
  blue: 'border-t-blue-500',
  green: 'border-t-green-500',
  purple: 'border-t-purple-500',
  orange: 'border-t-orange-500',
  red: 'border-t-red-500'
}

/**
 * 單一流程欄位
 */
function ProcessColumn({ processKey, config, onItemClick, maxItems = 5 }) {
  const Icon = PROCESS_ICONS[processKey]

  const { data: items, isLoading, error, refetch } = useQuery({
    queryKey: ['process-queue', processKey],
    queryFn: async () => {
      const params = {
        ...config.filter,
        order: 'decision_priority.asc,is_overdue.desc',
        limit: maxItems + 1  // 多取一筆判斷是否有更多
      }
      return db.get(config.view, params)
    },
    refetchInterval: 60000  // 每分鐘刷新
  })

  const hasMore = items?.length > maxItems
  const displayItems = items?.slice(0, maxItems) || []

  // 統計
  const urgentCount = displayItems.filter(i => i.decision_priority === 'urgent').length
  const highCount = displayItems.filter(i => i.decision_priority === 'high').length
  const overdueCount = displayItems.filter(i => i.is_overdue).length

  return (
    <div className={`bg-white rounded-lg border-t-4 ${COLUMN_COLORS[config.color]} shadow-sm flex flex-col`}>
      {/* 欄位標題 */}
      <div className="p-4 border-b">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            {Icon && <Icon className="w-5 h-5 text-gray-500" />}
            <h3 className="font-semibold text-gray-900">{config.label}</h3>
          </div>
          <button
            onClick={() => refetch()}
            className="p-1 hover:bg-gray-100 rounded transition-colors"
            title="重新整理"
          >
            <RefreshCw className="w-4 h-4 text-gray-400" />
          </button>
        </div>

        {/* 統計標籤 */}
        {!isLoading && displayItems.length > 0 && (
          <div className="flex gap-2 mt-2">
            {urgentCount > 0 && (
              <span className="text-xs px-2 py-0.5 rounded-full bg-red-100 text-red-700">
                <Flame className="w-3 h-3 inline mr-0.5" />
                {urgentCount} 緊急
              </span>
            )}
            {highCount > 0 && (
              <span className="text-xs px-2 py-0.5 rounded-full bg-orange-100 text-orange-700">
                <AlertTriangle className="w-3 h-3 inline mr-0.5" />
                {highCount} 高
              </span>
            )}
            {overdueCount > 0 && (
              <span className="text-xs px-2 py-0.5 rounded-full bg-red-100 text-red-700">
                <Clock className="w-3 h-3 inline mr-0.5" />
                {overdueCount} 逾期
              </span>
            )}
          </div>
        )}
      </div>

      {/* 內容區 */}
      <div className="flex-1 p-3 space-y-2 overflow-y-auto max-h-96">
        {isLoading ? (
          <div className="flex items-center justify-center h-24">
            <Loader2 className="w-5 h-5 animate-spin text-gray-400" />
          </div>
        ) : error ? (
          <div className="text-center text-red-500 text-sm py-4">
            載入失敗
          </div>
        ) : displayItems.length === 0 ? (
          <div className="text-center text-gray-400 text-sm py-8">
            無待辦事項 ✓
          </div>
        ) : (
          <>
            {displayItems.map((item) => (
              <ProcessCard
                key={item.entity_id || item.id || item.contract_id || item.payment_id}
                item={{
                  ...item,
                  process_key: processKey,
                  entity_id: item.entity_id || item.id || item.contract_id || item.payment_id,
                  title: item.title || item.contract_number || `#${item.entity_id}`,
                  decision_blocked_by: item.decision_blocked_by,
                  decision_next_action: item.decision_next_action,
                  decision_owner: item.decision_owner,
                  decision_priority: item.decision_priority,
                  is_overdue: item.is_overdue,
                  overdue_days: item.overdue_days || item.actual_overdue_days,
                  due_date: item.due_date || item.decision_due_date,
                  workspace_url: item.workspace_url
                }}
                variant="full"
                onClick={onItemClick}
              />
            ))}

            {/* 查看更多 */}
            {hasMore && (
              <Link
                to={`/${processKey}s`}
                className="block text-center text-sm text-primary-600 hover:text-primary-700 py-2"
              >
                查看全部 →
              </Link>
            )}
          </>
        )}
      </div>

      {/* 底部統計 */}
      <div className="p-3 border-t bg-gray-50 text-center">
        <span className="text-sm text-gray-500">
          {isLoading ? '...' : `${items?.length || 0} 項待處理`}
        </span>
      </div>
    </div>
  )
}

/**
 * 主組件
 */
export default function ProcessKanban({
  processes = ['renewal', 'payment', 'invoice', 'commission'],
  onItemClick,
  maxItemsPerColumn = 5,
  className = ''
}) {
  const handleItemClick = (item) => {
    if (onItemClick) {
      onItemClick(item)
    }
  }

  return (
    <div className={`grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 ${className}`}>
      {processes.map((processKey) => {
        const config = PROCESS_CONFIG[processKey]
        if (!config) return null

        return (
          <ProcessColumn
            key={processKey}
            processKey={processKey}
            config={config}
            onItemClick={handleItemClick}
            maxItems={maxItemsPerColumn}
          />
        )
      })}
    </div>
  )
}

// 匯出配置供外部使用
export { PROCESS_CONFIG, ProcessColumn }
