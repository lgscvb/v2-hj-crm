/**
 * AI 回覆回饋按鈕元件
 *
 * 功能：
 * 1. 👍/👎 快速回饋
 * 2. 點擊後可展開詳細評分（1-5 星）
 * 3. 可選擇改進標籤
 * 4. 可填寫回饋原因
 */

import { useState } from 'react'
import { ThumbsUp, ThumbsDown, Star, X, ChevronDown, ChevronUp } from 'lucide-react'

// 改進標籤選項
const IMPROVEMENT_TAGS = [
  { id: 'tone_too_formal', label: '語氣太正式' },
  { id: 'tone_too_casual', label: '語氣太隨便' },
  { id: 'too_long', label: '回覆太長' },
  { id: 'too_short', label: '回覆太短' },
  { id: 'missing_info', label: '缺少資訊' },
  { id: 'wrong_info', label: '資訊錯誤' },
  { id: 'wrong_tool', label: '呼叫錯誤工具' },
  { id: 'not_helpful', label: '沒有幫助' }
]

export default function FeedbackButtons({
  conversationId,
  onFeedbackSubmit,
  onRefineClick,
  disabled = false,
  compact = false
}) {
  const [isGood, setIsGood] = useState(null)
  const [showDetail, setShowDetail] = useState(false)
  const [rating, setRating] = useState(0)
  const [hoverRating, setHoverRating] = useState(0)
  const [selectedTags, setSelectedTags] = useState([])
  const [reason, setReason] = useState('')
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [submitted, setSubmitted] = useState(false)

  const handleQuickFeedback = async (good) => {
    setIsGood(good)

    if (good) {
      // 正面回饋直接提交
      await submitFeedback({ is_good: true })
    } else {
      // 負面回饋展開詳細表單
      setShowDetail(true)
    }
  }

  const toggleTag = (tagId) => {
    setSelectedTags(prev =>
      prev.includes(tagId)
        ? prev.filter(t => t !== tagId)
        : [...prev, tagId]
    )
  }

  const submitFeedback = async (data) => {
    if (!conversationId) return

    setIsSubmitting(true)
    try {
      const payload = {
        conversation_id: conversationId,
        ...data
      }

      if (rating > 0) payload.rating = rating
      if (selectedTags.length > 0) payload.improvement_tags = selectedTags
      if (reason.trim()) payload.feedback_reason = reason.trim()

      if (onFeedbackSubmit) {
        await onFeedbackSubmit(payload)
      }

      setSubmitted(true)
      setShowDetail(false)
    } catch (error) {
      console.error('Submit feedback error:', error)
    } finally {
      setIsSubmitting(false)
    }
  }

  const handleSubmitDetail = () => {
    submitFeedback({
      is_good: isGood,
      rating: rating || undefined,
      improvement_tags: selectedTags.length > 0 ? selectedTags : undefined,
      feedback_reason: reason.trim() || undefined
    })
  }

  // 已提交狀態
  if (submitted) {
    return (
      <div className="flex items-center gap-2 text-sm text-gray-500">
        <span className="text-green-600">感謝您的回饋！</span>
        {onRefineClick && (
          <button
            onClick={() => onRefineClick(conversationId)}
            className="text-blue-600 hover:text-blue-700 underline"
          >
            修正回覆
          </button>
        )}
      </div>
    )
  }

  return (
    <div className={`${compact ? 'inline-flex items-center gap-1' : ''}`}>
      {/* 快速回饋按鈕 */}
      <div className="flex items-center gap-1">
        <button
          onClick={() => handleQuickFeedback(true)}
          disabled={disabled || isSubmitting}
          className={`p-1.5 rounded-lg transition-colors ${
            isGood === true
              ? 'bg-green-100 text-green-600'
              : 'text-gray-400 hover:text-green-600 hover:bg-green-50'
          } disabled:opacity-50 disabled:cursor-not-allowed`}
          title="這個回覆很好"
        >
          <ThumbsUp className="w-4 h-4" />
        </button>

        <button
          onClick={() => handleQuickFeedback(false)}
          disabled={disabled || isSubmitting}
          className={`p-1.5 rounded-lg transition-colors ${
            isGood === false
              ? 'bg-red-100 text-red-600'
              : 'text-gray-400 hover:text-red-600 hover:bg-red-50'
          } disabled:opacity-50 disabled:cursor-not-allowed`}
          title="這個回覆需要改進"
        >
          <ThumbsDown className="w-4 h-4" />
        </button>

        {onRefineClick && !compact && (
          <button
            onClick={() => onRefineClick(conversationId)}
            disabled={disabled}
            className="ml-2 text-xs text-blue-600 hover:text-blue-700 hover:underline disabled:opacity-50"
          >
            修正
          </button>
        )}

        {/* 展開/收起詳細表單 */}
        {isGood !== null && !showDetail && (
          <button
            onClick={() => setShowDetail(true)}
            className="ml-1 p-1 text-gray-400 hover:text-gray-600"
            title="詳細回饋"
          >
            <ChevronDown className="w-4 h-4" />
          </button>
        )}
      </div>

      {/* 詳細回饋表單 */}
      {showDetail && (
        <div className="mt-3 p-4 bg-gray-50 rounded-lg border border-gray-200">
          <div className="flex justify-between items-center mb-3">
            <span className="text-sm font-medium text-gray-700">詳細回饋</span>
            <button
              onClick={() => setShowDetail(false)}
              className="text-gray-400 hover:text-gray-600"
            >
              <X className="w-4 h-4" />
            </button>
          </div>

          {/* 星級評分 */}
          <div className="mb-3">
            <label className="block text-xs text-gray-500 mb-1">評分</label>
            <div className="flex gap-1">
              {[1, 2, 3, 4, 5].map((star) => (
                <button
                  key={star}
                  onClick={() => setRating(star)}
                  onMouseEnter={() => setHoverRating(star)}
                  onMouseLeave={() => setHoverRating(0)}
                  className="p-0.5"
                >
                  <Star
                    className={`w-5 h-5 ${
                      star <= (hoverRating || rating)
                        ? 'text-yellow-400 fill-yellow-400'
                        : 'text-gray-300'
                    }`}
                  />
                </button>
              ))}
            </div>
          </div>

          {/* 改進標籤 */}
          <div className="mb-3">
            <label className="block text-xs text-gray-500 mb-1">需要改進的地方</label>
            <div className="flex flex-wrap gap-1.5">
              {IMPROVEMENT_TAGS.map((tag) => (
                <button
                  key={tag.id}
                  onClick={() => toggleTag(tag.id)}
                  className={`px-2 py-1 text-xs rounded-full transition-colors ${
                    selectedTags.includes(tag.id)
                      ? 'bg-blue-100 text-blue-700 border border-blue-300'
                      : 'bg-white text-gray-600 border border-gray-300 hover:border-gray-400'
                  }`}
                >
                  {tag.label}
                </button>
              ))}
            </div>
          </div>

          {/* 回饋原因 */}
          <div className="mb-3">
            <label className="block text-xs text-gray-500 mb-1">補充說明（選填）</label>
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="請描述具體的問題或建議..."
              className="w-full px-3 py-2 text-sm border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 resize-none"
              rows={2}
            />
          </div>

          {/* 提交按鈕 */}
          <div className="flex justify-end gap-2">
            <button
              onClick={() => setShowDetail(false)}
              className="px-3 py-1.5 text-sm text-gray-600 hover:text-gray-800"
            >
              取消
            </button>
            <button
              onClick={handleSubmitDetail}
              disabled={isSubmitting}
              className="px-3 py-1.5 text-sm bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50"
            >
              {isSubmitting ? '提交中...' : '提交回饋'}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
