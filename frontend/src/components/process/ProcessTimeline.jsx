/**
 * ProcessTimeline - 流程時間軸組件
 *
 * 垂直顯示流程各階段的狀態和進度
 * 適用於 Workspace 頁面展示流程全貌
 *
 * @example
 * <ProcessTimeline
 *   steps={[
 *     {
 *       key: 'intent',
 *       label: '續約意願',
 *       status: 'done',
 *       details: { confirmed_at: '2024-01-01' }
 *     },
 *     {
 *       key: 'signing',
 *       label: '合約簽署',
 *       status: 'pending',
 *       details: { sent_for_sign_at: '2024-01-10', days_pending: 5 }
 *     },
 *     {
 *       key: 'payment',
 *       label: '款項收取',
 *       status: 'not_started'
 *     }
 *   ]}
 *   currentStep="signing"
 * />
 */

import {
  CheckCircle,
  Clock,
  XCircle,
  Circle,
  FileText,
  AlertTriangle,
  Play,
  Pause
} from 'lucide-react'
import Badge from '../Badge'

// 狀態配置
const STATUS_CONFIG = {
  done: {
    icon: CheckCircle,
    color: 'text-green-500',
    bg: 'bg-green-100',
    lineColor: 'bg-green-300',
    label: '完成',
    badgeVariant: 'success'
  },
  pending: {
    icon: Clock,
    color: 'text-yellow-500',
    bg: 'bg-yellow-100',
    lineColor: 'bg-yellow-300',
    label: '進行中',
    badgeVariant: 'warning'
  },
  blocked: {
    icon: XCircle,
    color: 'text-red-500',
    bg: 'bg-red-100',
    lineColor: 'bg-red-300',
    label: '阻塞',
    badgeVariant: 'danger'
  },
  draft: {
    icon: FileText,
    color: 'text-blue-500',
    bg: 'bg-blue-100',
    lineColor: 'bg-blue-300',
    label: '草稿',
    badgeVariant: 'info'
  },
  not_started: {
    icon: Circle,
    color: 'text-gray-400',
    bg: 'bg-gray-100',
    lineColor: 'bg-gray-200',
    label: '未開始',
    badgeVariant: 'gray'
  },
  not_created: {
    icon: Circle,
    color: 'text-gray-400',
    bg: 'bg-gray-100',
    lineColor: 'bg-gray-200',
    label: '未建立',
    badgeVariant: 'gray'
  },
  skipped: {
    icon: Pause,
    color: 'text-gray-300',
    bg: 'bg-gray-50',
    lineColor: 'bg-gray-200',
    label: '略過',
    badgeVariant: 'gray'
  },
  'n/a': {
    icon: Circle,
    color: 'text-gray-300',
    bg: 'bg-gray-50',
    lineColor: 'bg-gray-200',
    label: '不適用',
    badgeVariant: 'gray'
  }
}

// 格式化日期時間
const formatDateTime = (dateStr) => {
  if (!dateStr) return null
  return new Date(dateStr).toLocaleString('zh-TW', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  })
}

/**
 * 單一時間軸節點
 */
function TimelineNode({ step, isLast, isCurrent, renderDetails }) {
  const config = STATUS_CONFIG[step.status] || STATUS_CONFIG.not_started
  const Icon = config.icon

  return (
    <div className="flex gap-4">
      {/* 左側：圖示和連接線 */}
      <div className="flex flex-col items-center">
        <div
          className={`
            w-10 h-10 rounded-full ${config.bg} flex items-center justify-center
            ${isCurrent ? 'ring-2 ring-offset-2 ring-primary-500' : ''}
          `}
        >
          <Icon className={`w-5 h-5 ${config.color}`} />
        </div>
        {!isLast && (
          <div className={`w-0.5 flex-1 min-h-[24px] ${config.lineColor} my-2`} />
        )}
      </div>

      {/* 右側：內容 */}
      <div className="flex-1 pb-6">
        <div className="flex items-center justify-between gap-2">
          <h4 className={`font-medium ${isCurrent ? 'text-primary-700' : 'text-gray-900'}`}>
            {step.label}
          </h4>
          <Badge variant={config.badgeVariant}>
            {config.label}
          </Badge>
        </div>

        {/* 詳細資訊 */}
        <div className="mt-2 text-sm text-gray-500 space-y-1">
          {/* 使用自訂渲染或預設渲染 */}
          {renderDetails ? (
            renderDetails(step)
          ) : (
            <DefaultDetails step={step} />
          )}
        </div>
      </div>
    </div>
  )
}

/**
 * 預設詳情渲染
 */
function DefaultDetails({ step }) {
  const { details, status } = step

  if (!details) {
    if (status === 'not_started' || status === 'not_created') {
      return <p className="text-gray-400">尚未開始</p>
    }
    return null
  }

  return (
    <>
      {/* 通用時間戳記 */}
      {details.created_at && (
        <p>建立時間：{formatDateTime(details.created_at)}</p>
      )}
      {details.completed_at && (
        <p className="text-green-600">完成時間：{formatDateTime(details.completed_at)}</p>
      )}
      {details.sent_at && (
        <p>送出時間：{formatDateTime(details.sent_at)}</p>
      )}

      {/* 等待天數 */}
      {details.days_pending > 0 && status === 'pending' && (
        <p className={details.days_pending > 14 ? 'text-red-600 font-medium' : 'text-yellow-600'}>
          已等待 {details.days_pending} 天{details.days_pending > 14 && '（逾期）'}
        </p>
      )}

      {/* 備註 */}
      {details.note && (
        <p className="italic">{details.note}</p>
      )}
    </>
  )
}

/**
 * 主組件
 */
export default function ProcessTimeline({
  steps,
  currentStep,
  orientation = 'vertical',  // 目前只支援 vertical
  renderDetails,
  className = ''
}) {
  if (!steps || steps.length === 0) {
    return (
      <div className="text-center text-gray-500 py-4">
        無流程步驟資料
      </div>
    )
  }

  return (
    <div className={`${className}`}>
      {steps.map((step, index) => (
        <TimelineNode
          key={step.key || index}
          step={step}
          isLast={index === steps.length - 1}
          isCurrent={currentStep === step.key}
          renderDetails={renderDetails}
        />
      ))}
    </div>
  )
}

// 匯出子組件和配置
export { TimelineNode, DefaultDetails, STATUS_CONFIG }
