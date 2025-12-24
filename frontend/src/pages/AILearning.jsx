/**
 * AI 學習管理頁面
 *
 * 功能：
 * 1. 回饋統計儀表板
 * 2. 對話歷史列表
 * 3. 學習模式展示
 * 4. 訓練資料匯出
 */

import { useState } from 'react'
import { useQuery, useMutation } from '@tanstack/react-query'
import {
  Brain,
  ThumbsUp,
  ThumbsDown,
  Star,
  MessageSquare,
  Download,
  RefreshCw,
  TrendingUp,
  Calendar,
  Filter,
  ChevronDown,
  ChevronRight,
  Clock,
  Bot,
  FileText,
  CheckCircle,
  XCircle
} from 'lucide-react'
import { aiLearning } from '../services/api'
import { toast } from 'react-hot-toast'

// 統計卡片元件
function StatCard({ icon: Icon, label, value, subValue, color = 'blue' }) {
  const colorClasses = {
    blue: 'bg-blue-50 text-blue-600',
    green: 'bg-green-50 text-green-600',
    red: 'bg-red-50 text-red-600',
    yellow: 'bg-yellow-50 text-yellow-600',
    purple: 'bg-purple-50 text-purple-600'
  }

  return (
    <div className="bg-white rounded-xl border border-gray-200 p-4">
      <div className="flex items-center gap-3">
        <div className={`w-10 h-10 rounded-lg ${colorClasses[color]} flex items-center justify-center`}>
          <Icon className="w-5 h-5" />
        </div>
        <div>
          <p className="text-sm text-gray-500">{label}</p>
          <p className="text-xl font-bold text-gray-900">{value}</p>
          {subValue && <p className="text-xs text-gray-400">{subValue}</p>}
        </div>
      </div>
    </div>
  )
}

// 對話項目元件
function ConversationItem({ conversation, isExpanded, onToggle }) {
  const formatDate = (dateStr) => {
    if (!dateStr) return '-'
    const date = new Date(dateStr)
    return date.toLocaleString('zh-TW', {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    })
  }

  return (
    <div className="border border-gray-200 rounded-lg overflow-hidden">
      <button
        onClick={onToggle}
        className="w-full px-4 py-3 flex items-center gap-3 hover:bg-gray-50 text-left"
      >
        {isExpanded ? (
          <ChevronDown className="w-4 h-4 text-gray-400" />
        ) : (
          <ChevronRight className="w-4 h-4 text-gray-400" />
        )}
        <Bot className="w-5 h-5 text-purple-500" />
        <div className="flex-1 min-w-0">
          <p className="text-sm text-gray-900 truncate">
            {conversation.user_message?.slice(0, 60) || '無訊息'}...
          </p>
          <p className="text-xs text-gray-500">
            {conversation.model_used} • {formatDate(conversation.created_at)}
          </p>
        </div>
        {conversation.feedback_is_good !== null && (
          <div className={`px-2 py-0.5 rounded-full text-xs ${
            conversation.feedback_is_good
              ? 'bg-green-100 text-green-700'
              : 'bg-red-100 text-red-700'
          }`}>
            {conversation.feedback_is_good ? '👍' : '👎'}
          </div>
        )}
        {conversation.feedback_rating && (
          <div className="flex items-center gap-0.5">
            <Star className="w-3 h-3 text-yellow-400 fill-yellow-400" />
            <span className="text-xs text-gray-600">{conversation.feedback_rating}</span>
          </div>
        )}
      </button>

      {isExpanded && (
        <div className="px-4 py-3 bg-gray-50 border-t border-gray-200">
          <div className="space-y-3">
            {/* 用戶訊息 */}
            <div>
              <p className="text-xs font-medium text-gray-500 mb-1">用戶訊息</p>
              <p className="text-sm text-gray-800 bg-white p-2 rounded border border-gray-200">
                {conversation.user_message}
              </p>
            </div>

            {/* AI 回覆 */}
            <div>
              <p className="text-xs font-medium text-gray-500 mb-1">AI 回覆</p>
              <p className="text-sm text-gray-800 bg-white p-2 rounded border border-gray-200 whitespace-pre-wrap">
                {conversation.assistant_message?.slice(0, 500)}
                {conversation.assistant_message?.length > 500 && '...'}
              </p>
            </div>

            {/* 回饋詳情 */}
            {conversation.feedback_reason && (
              <div>
                <p className="text-xs font-medium text-gray-500 mb-1">回饋原因</p>
                <p className="text-sm text-gray-700 bg-yellow-50 p-2 rounded border border-yellow-200">
                  {conversation.feedback_reason}
                </p>
              </div>
            )}

            {/* 工具調用 */}
            {conversation.tool_calls && conversation.tool_calls.length > 0 && (
              <div>
                <p className="text-xs font-medium text-gray-500 mb-1">使用的工具</p>
                <div className="flex flex-wrap gap-1">
                  {conversation.tool_calls.map((tool, i) => (
                    <span
                      key={i}
                      className="px-2 py-0.5 bg-blue-100 text-blue-700 rounded text-xs"
                    >
                      {tool.tool || tool}
                    </span>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}

export default function AILearning() {
  const [dateRange, setDateRange] = useState(30)
  const [expandedId, setExpandedId] = useState(null)
  const [exportFormat, setExportFormat] = useState('sft')

  // 取得回饋統計
  const { data: statsData, isLoading: statsLoading, refetch: refetchStats } = useQuery({
    queryKey: ['ai-feedback-stats', dateRange],
    queryFn: () => aiLearning.getFeedbackStats(dateRange)
  })

  // 取得對話列表
  const { data: conversationsData, isLoading: conversationsLoading, refetch: refetchConversations } = useQuery({
    queryKey: ['ai-conversations'],
    queryFn: () => aiLearning.getConversations({ limit: 50 })
  })

  // 取得訓練統計
  const { data: trainingData } = useQuery({
    queryKey: ['ai-training-stats'],
    queryFn: () => aiLearning.getTrainingStats()
  })

  // 匯出訓練資料
  const exportMutation = useMutation({
    mutationFn: (format) => aiLearning.exportTrainingData(format, null, 1000),
    onSuccess: (data) => {
      // 下載 JSON 檔案
      const blob = new Blob([JSON.stringify(data.data || data, null, 2)], { type: 'application/json' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `training-data-${exportFormat}-${new Date().toISOString().slice(0, 10)}.json`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      URL.revokeObjectURL(url)
      toast.success(`已匯出 ${exportFormat.toUpperCase()} 格式訓練資料`)
    },
    onError: (error) => {
      console.error('匯出失敗:', error)
      toast.error('匯出訓練資料失敗')
    }
  })

  const stats = statsData?.data || statsData || {}
  const conversations = conversationsData?.data || conversationsData || []
  const training = trainingData?.data || trainingData || {}

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-purple-500 to-pink-600 flex items-center justify-center">
            <Brain className="w-6 h-6 text-white" />
          </div>
          <div>
            <h1 className="text-xl font-bold text-gray-900">AI 學習管理</h1>
            <p className="text-sm text-gray-500">回饋統計、對話記錄、訓練資料匯出</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {/* 日期範圍 */}
          <select
            value={dateRange}
            onChange={(e) => setDateRange(Number(e.target.value))}
            className="px-3 py-1.5 text-sm border border-gray-300 rounded-lg"
          >
            <option value={7}>最近 7 天</option>
            <option value={30}>最近 30 天</option>
            <option value={90}>最近 90 天</option>
          </select>
          <button
            onClick={() => {
              refetchStats()
              refetchConversations()
            }}
            className="p-2 text-gray-600 hover:bg-gray-100 rounded-lg"
          >
            <RefreshCw className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* 統計卡片 */}
      <div className="grid grid-cols-2 lg:grid-cols-5 gap-4">
        <StatCard
          icon={MessageSquare}
          label="總對話數"
          value={stats.total_conversations || 0}
          color="blue"
        />
        <StatCard
          icon={ThumbsUp}
          label="正面回饋"
          value={stats.positive_count || 0}
          subValue={stats.positive_rate ? `${(stats.positive_rate * 100).toFixed(1)}%` : null}
          color="green"
        />
        <StatCard
          icon={ThumbsDown}
          label="負面回饋"
          value={stats.negative_count || 0}
          subValue={stats.negative_rate ? `${(stats.negative_rate * 100).toFixed(1)}%` : null}
          color="red"
        />
        <StatCard
          icon={Star}
          label="平均評分"
          value={stats.avg_rating ? stats.avg_rating.toFixed(1) : '-'}
          color="yellow"
        />
        <StatCard
          icon={FileText}
          label="可匯出資料"
          value={training.exportable_count || 0}
          color="purple"
        />
      </div>

      {/* 主要內容區 */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* 對話歷史 */}
        <div className="lg:col-span-2 bg-white rounded-xl border border-gray-200">
          <div className="p-4 border-b border-gray-200">
            <h2 className="font-semibold text-gray-900 flex items-center gap-2">
              <Clock className="w-4 h-4" />
              最近對話記錄
            </h2>
          </div>
          <div className="p-4 space-y-2 max-h-[500px] overflow-y-auto">
            {conversationsLoading ? (
              <div className="text-center py-8 text-gray-500">載入中...</div>
            ) : conversations.length === 0 ? (
              <div className="text-center py-8 text-gray-500">暫無對話記錄</div>
            ) : (
              conversations.map((conv) => (
                <ConversationItem
                  key={conv.id}
                  conversation={conv}
                  isExpanded={expandedId === conv.id}
                  onToggle={() => setExpandedId(expandedId === conv.id ? null : conv.id)}
                />
              ))
            )}
          </div>
        </div>

        {/* 訓練資料匯出 */}
        <div className="bg-white rounded-xl border border-gray-200">
          <div className="p-4 border-b border-gray-200">
            <h2 className="font-semibold text-gray-900 flex items-center gap-2">
              <Download className="w-4 h-4" />
              訓練資料匯出
            </h2>
          </div>
          <div className="p-4 space-y-4">
            {/* 匯出格式說明 */}
            <div className="space-y-3">
              <div
                className={`p-3 rounded-lg border cursor-pointer transition-colors ${
                  exportFormat === 'sft'
                    ? 'border-blue-500 bg-blue-50'
                    : 'border-gray-200 hover:border-gray-300'
                }`}
                onClick={() => setExportFormat('sft')}
              >
                <div className="flex items-center gap-2">
                  <div className={`w-4 h-4 rounded-full border-2 ${
                    exportFormat === 'sft' ? 'border-blue-500 bg-blue-500' : 'border-gray-300'
                  }`}>
                    {exportFormat === 'sft' && (
                      <CheckCircle className="w-3 h-3 text-white" />
                    )}
                  </div>
                  <span className="font-medium text-sm">SFT 格式</span>
                </div>
                <p className="text-xs text-gray-500 mt-1 ml-6">
                  Supervised Fine-Tuning，適用於一般微調
                </p>
              </div>

              <div
                className={`p-3 rounded-lg border cursor-pointer transition-colors ${
                  exportFormat === 'rlhf'
                    ? 'border-blue-500 bg-blue-50'
                    : 'border-gray-200 hover:border-gray-300'
                }`}
                onClick={() => setExportFormat('rlhf')}
              >
                <div className="flex items-center gap-2">
                  <div className={`w-4 h-4 rounded-full border-2 ${
                    exportFormat === 'rlhf' ? 'border-blue-500 bg-blue-500' : 'border-gray-300'
                  }`}>
                    {exportFormat === 'rlhf' && (
                      <CheckCircle className="w-3 h-3 text-white" />
                    )}
                  </div>
                  <span className="font-medium text-sm">RLHF 格式</span>
                </div>
                <p className="text-xs text-gray-500 mt-1 ml-6">
                  強化學習人類回饋，包含偏好排序
                </p>
              </div>

              <div
                className={`p-3 rounded-lg border cursor-pointer transition-colors ${
                  exportFormat === 'dpo'
                    ? 'border-blue-500 bg-blue-50'
                    : 'border-gray-200 hover:border-gray-300'
                }`}
                onClick={() => setExportFormat('dpo')}
              >
                <div className="flex items-center gap-2">
                  <div className={`w-4 h-4 rounded-full border-2 ${
                    exportFormat === 'dpo' ? 'border-blue-500 bg-blue-500' : 'border-gray-300'
                  }`}>
                    {exportFormat === 'dpo' && (
                      <CheckCircle className="w-3 h-3 text-white" />
                    )}
                  </div>
                  <span className="font-medium text-sm">DPO 格式</span>
                </div>
                <p className="text-xs text-gray-500 mt-1 ml-6">
                  Direct Preference Optimization，需有修正對照
                </p>
              </div>
            </div>

            {/* 匯出統計 */}
            <div className="bg-gray-50 rounded-lg p-3 space-y-1">
              <div className="flex justify-between text-sm">
                <span className="text-gray-500">可匯出對話</span>
                <span className="font-medium">{training.exportable_count || 0} 筆</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-gray-500">有回饋對話</span>
                <span className="font-medium">{training.with_feedback_count || 0} 筆</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-gray-500">有修正對話</span>
                <span className="font-medium">{training.with_refinement_count || 0} 筆</span>
              </div>
            </div>

            {/* 匯出按鈕 */}
            <button
              onClick={() => exportMutation.mutate(exportFormat)}
              disabled={exportMutation.isPending || (training.exportable_count || 0) === 0}
              className="w-full px-4 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700 disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center gap-2"
            >
              {exportMutation.isPending ? (
                <>
                  <RefreshCw className="w-4 h-4 animate-spin" />
                  匯出中...
                </>
              ) : (
                <>
                  <Download className="w-4 h-4" />
                  匯出 {exportFormat.toUpperCase()} 訓練資料
                </>
              )}
            </button>
          </div>
        </div>
      </div>

      {/* 學習模式統計（如果有的話） */}
      {stats.top_improvement_tags && stats.top_improvement_tags.length > 0 && (
        <div className="bg-white rounded-xl border border-gray-200 p-4">
          <h2 className="font-semibold text-gray-900 mb-4 flex items-center gap-2">
            <TrendingUp className="w-4 h-4" />
            常見改進需求
          </h2>
          <div className="flex flex-wrap gap-2">
            {stats.top_improvement_tags.map((tag, i) => (
              <div
                key={i}
                className="px-3 py-1.5 bg-orange-100 text-orange-700 rounded-full text-sm flex items-center gap-1"
              >
                <span>{tag.tag}</span>
                <span className="bg-orange-200 px-1.5 rounded-full text-xs">{tag.count}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
