/**
 * ProcessCard - 流程 Kanban 卡片組件
 *
 * 用於 Dashboard Kanban 看板，顯示單一待辦項目
 * 點擊可進入對應的 Workspace 頁面
 *
 * @example
 * <ProcessCard
 *   item={{
 *     process_key: 'renewal',
 *     entity_id: 123,
 *     title: 'A001 戴豪廷',
 *     decision_blocked_by: 'need_send_for_sign',
 *     decision_next_action: '送出簽署給客戶',
 *     decision_owner: 'Sales',
 *     decision_priority: 'high',
 *     is_overdue: true,
 *     overdue_days: 5,
 *     due_date: '2024-01-15',
 *     workspace_url: '/contracts/123/workspace'
 *   }}
 *   onClick={(item) => navigate(item.workspace_url)}
 * />
 */

import { Link } from 'react-router-dom'
import {
  Clock,
  AlertTriangle,
  Flame,
  ArrowRight,
  ChevronRight,
  Building2,
  Calendar,
  User
} from 'lucide-react'
import { PRIORITY_COLORS, OWNER_COLORS, PROCESS_ICONS } from './index'

// 優先級圖示
const PRIORITY_ICONS = {
  urgent: Flame,
  high: AlertTriangle,
  medium: Clock,
  low: ArrowRight
}

// 格式化日期
const formatDate = (dateStr) => {
  if (!dateStr) return null
  const date = new Date(dateStr)
  const month = date.getMonth() + 1
  const day = date.getDate()
  return `${month}/${day}`
}

// 計算距離天數
const getDaysText = (dateStr) => {
  if (!dateStr) return null
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const target = new Date(dateStr)
  target.setHours(0, 0, 0, 0)
  const diffDays = Math.ceil((target - today) / (1000 * 60 * 60 * 24))

  if (diffDays < 0) return `逾期 ${Math.abs(diffDays)} 天`
  if (diffDays === 0) return '今天'
  if (diffDays === 1) return '明天'
  if (diffDays <= 7) return `${diffDays} 天後`
  return formatDate(dateStr)
}

/**
 * 緊湊模式卡片（用於列表）
 */
function CompactCard({ item, onClick }) {
  const priority = item.decision_priority || 'medium'
  const priorityConfig = PRIORITY_COLORS[priority] || PRIORITY_COLORS.medium
  const PriorityIcon = PRIORITY_ICONS[priority] || Clock

  return (
    <div
      onClick={() => onClick?.(item)}
      className={`
        flex items-center gap-3 px-3 py-2 rounded-lg cursor-pointer
        border-l-4 ${priorityConfig.border} bg-white
        hover:bg-gray-50 transition-colors
      `}
    >
      {/* 優先級圖示 */}
      <PriorityIcon className={`w-4 h-4 flex-shrink-0 ${priorityConfig.text}`} />

      {/* 標題 */}
      <span className="flex-1 text-sm font-medium text-gray-900 truncate">
        {item.title}
      </span>

      {/* 逾期天數 */}
      {item.is_overdue && item.overdue_days > 0 && (
        <span className="text-xs text-red-600 font-medium">
          逾{item.overdue_days}天
        </span>
      )}

      <ChevronRight className="w-4 h-4 text-gray-400" />
    </div>
  )
}

/**
 * 完整卡片（用於 Kanban）
 */
function FullCard({ item, onClick, showProcess = false }) {
  const priority = item.decision_priority || 'medium'
  const priorityConfig = PRIORITY_COLORS[priority] || PRIORITY_COLORS.medium
  const ownerConfig = OWNER_COLORS[item.decision_owner] || { bg: 'bg-gray-100', text: 'text-gray-700' }
  const PriorityIcon = PRIORITY_ICONS[priority] || Clock
  const ProcessIcon = PROCESS_ICONS[item.process_key]

  const dueText = getDaysText(item.due_date)

  return (
    <div
      onClick={() => onClick?.(item)}
      className={`
        bg-white rounded-lg border shadow-sm p-3 space-y-2 cursor-pointer
        hover:shadow-md hover:border-gray-300 transition-all
        ${item.is_overdue ? 'border-red-200' : 'border-gray-200'}
      `}
    >
      {/* 頂部：流程類型 + 優先級 */}
      <div className="flex items-center justify-between">
        {showProcess && ProcessIcon && (
          <div className="flex items-center gap-1 text-xs text-gray-500">
            <ProcessIcon className="w-3 h-3" />
            <span>{item.process_key}</span>
          </div>
        )}

        <span className={`text-xs px-1.5 py-0.5 rounded font-medium ${priorityConfig.badge}`}>
          <PriorityIcon className="w-3 h-3 inline mr-0.5" />
          {priority === 'urgent' ? '緊急' : priority === 'high' ? '高' : priority === 'medium' ? '中' : '低'}
        </span>
      </div>

      {/* 標題 */}
      <h4 className="font-medium text-gray-900 text-sm line-clamp-2">
        {item.title}
      </h4>

      {/* 下一步行動 */}
      {item.decision_next_action && (
        <p className="text-xs text-gray-500 line-clamp-1">
          → {item.decision_next_action}
        </p>
      )}

      {/* 底部：責任人 + 到期日 */}
      <div className="flex items-center justify-between pt-1 border-t border-gray-100">
        {item.decision_owner && (
          <span className={`text-xs px-1.5 py-0.5 rounded ${ownerConfig.bg} ${ownerConfig.text}`}>
            {item.decision_owner}
          </span>
        )}

        {dueText && (
          <span className={`text-xs ${item.is_overdue ? 'text-red-600 font-medium' : 'text-gray-500'}`}>
            <Calendar className="w-3 h-3 inline mr-0.5" />
            {dueText}
          </span>
        )}
      </div>
    </div>
  )
}

/**
 * 主組件
 */
export default function ProcessCard({
  item,
  onClick,
  variant = 'full',  // 'full' | 'compact'
  showProcess = false,
  asLink = false
}) {
  const CardComponent = variant === 'compact' ? CompactCard : FullCard

  // 如果是連結模式
  if (asLink && item.workspace_url) {
    return (
      <Link to={item.workspace_url} className="block">
        <CardComponent item={item} showProcess={showProcess} />
      </Link>
    )
  }

  return (
    <CardComponent
      item={item}
      onClick={onClick}
      showProcess={showProcess}
    />
  )
}

// 匯出子組件
export { CompactCard, FullCard }
