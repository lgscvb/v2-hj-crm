/**
 * ProcessWorkspace - 流程工作區容器組件
 *
 * 提供統一的 Workspace 頁面佈局：
 * - 左側：流程時間軸 + 決策面板
 * - 右側：實體詳情（由外部提供）
 *
 * @example
 * <ProcessWorkspace
 *   processKey="renewal"
 *   title="續約流程"
 *   entityId={123}
 *   decision={decisionData}
 *   timelineSteps={steps}
 *   currentStep="signing"
 *   onActionComplete={handleRefresh}
 *   loading={isLoading}
 * >
 *   {/* 右側自訂內容 *}
 *   <ContractDetails contract={contract} />
 * </ProcessWorkspace>
 */

import { Link } from 'react-router-dom'
import {
  ArrowLeft,
  Loader2,
  RefreshCw
} from 'lucide-react'
import DecisionPanel from './DecisionPanel'
import ProcessTimeline from './ProcessTimeline'
import { PROCESS_ICONS } from './constants'

/**
 * 載入狀態
 */
function LoadingState() {
  return (
    <div className="min-h-screen bg-gray-50 flex items-center justify-center">
      <div className="text-center">
        <Loader2 className="w-8 h-8 animate-spin text-primary-500 mx-auto mb-2" />
        <p className="text-gray-500">載入中...</p>
      </div>
    </div>
  )
}

/**
 * 錯誤狀態
 */
function ErrorState({ message, onRetry }) {
  return (
    <div className="min-h-screen bg-gray-50 flex items-center justify-center">
      <div className="text-center">
        <p className="text-red-600 mb-4">{message || '發生錯誤'}</p>
        {onRetry && (
          <button
            onClick={onRetry}
            className="inline-flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700"
          >
            <RefreshCw className="w-4 h-4" />
            重試
          </button>
        )}
      </div>
    </div>
  )
}

/**
 * 主組件
 */
export default function ProcessWorkspace({
  // 流程資訊
  processKey,
  title,
  subtitle,

  // 實體資訊
  entityId,
  entityUrl,  // 返回連結

  // 決策資料
  decision,
  actionOverrides,
  customActions,

  // 時間軸資料
  timelineSteps,
  currentStep,
  renderTimelineDetails,

  // 狀態
  loading = false,
  error = null,

  // 回調
  onActionComplete,
  onActionError,
  onRetry,

  // 自訂內容
  children,
  leftPanelExtra,  // 左側面板額外內容
  headerExtra,     // 標題列額外內容

  // 樣式
  className = ''
}) {
  // 載入中
  if (loading) {
    return <LoadingState />
  }

  // 錯誤
  if (error) {
    return <ErrorState message={error} onRetry={onRetry} />
  }

  const ProcessIcon = PROCESS_ICONS[processKey]

  return (
    <div className={`min-h-screen bg-gray-50 ${className}`}>
      {/* 頂部標題列 */}
      <div className="bg-white border-b sticky top-0 z-10">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 py-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-4">
              {/* 返回按鈕 */}
              {entityUrl && (
                <Link
                  to={entityUrl}
                  className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
                >
                  <ArrowLeft className="w-5 h-5 text-gray-500" />
                </Link>
              )}

              {/* 標題 */}
              <div>
                <div className="flex items-center gap-2">
                  {ProcessIcon && <ProcessIcon className="w-5 h-5 text-primary-500" />}
                  <h1 className="text-xl font-bold text-gray-900">{title}</h1>
                </div>
                {subtitle && (
                  <p className="text-sm text-gray-500 mt-0.5">{subtitle}</p>
                )}
              </div>
            </div>

            {/* 額外標題區內容 */}
            {headerExtra}
          </div>
        </div>
      </div>

      {/* 主內容區 */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 py-6">
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {/* 左側：決策面板 + 時間軸 */}
          <div className="lg:col-span-1 space-y-6">
            {/* 決策面板 */}
            <div className="bg-white rounded-xl border shadow-sm p-4">
              <h2 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mb-4">
                當前狀態
              </h2>
              <DecisionPanel
                decision={decision}
                processKey={processKey}
                entityId={entityId}
                onActionComplete={onActionComplete}
                onActionError={onActionError}
                actionOverrides={actionOverrides}
                customActions={customActions}
              />
            </div>

            {/* 時間軸 */}
            {timelineSteps && timelineSteps.length > 0 && (
              <div className="bg-white rounded-xl border shadow-sm p-4">
                <h2 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mb-4">
                  流程進度
                </h2>
                <ProcessTimeline
                  steps={timelineSteps}
                  currentStep={currentStep}
                  renderDetails={renderTimelineDetails}
                />
              </div>
            )}

            {/* 左側額外內容 */}
            {leftPanelExtra}
          </div>

          {/* 右側：主要內容（由外部提供） */}
          <div className="lg:col-span-2">
            {children}
          </div>
        </div>
      </div>
    </div>
  )
}

// 匯出子組件
export { LoadingState, ErrorState }
