/**
 * 多輪修正對話元件
 *
 * 功能：
 * 1. 顯示原始 AI 回覆
 * 2. 輸入修正指令
 * 3. 顯示修正後結果
 * 4. 偵測知識點時顯示儲存建議
 * 5. 標記修正為接受/拒絕
 */

import { useState, useEffect } from 'react'
import { Send, Check, X, Lightbulb, History, RefreshCw } from 'lucide-react'
import api from '../../services/api'

// 常用快捷指令
const QUICK_INSTRUCTIONS = [
  '語氣更親切',
  '更簡潔',
  '更正式',
  '加入更多細節',
  '用列表方式呈現'
]

export default function RefinementChat({
  conversationId,
  originalContent,
  onClose,
  onAccept,
  onUseVersion
}) {
  const [instruction, setInstruction] = useState('')
  const [refinements, setRefinements] = useState([])
  const [isRefining, setIsRefining] = useState(false)
  const [knowledgeSuggestion, setKnowledgeSuggestion] = useState(null)
  const [savingKnowledge, setSavingKnowledge] = useState(false)
  const [error, setError] = useState(null)

  // 載入修正歷史
  useEffect(() => {
    if (conversationId) {
      loadRefinementHistory()
    }
  }, [conversationId])

  const loadRefinementHistory = async () => {
    try {
      const response = await api.get(`/ai/conversations/${conversationId}/refinements`)
      if (response.data.success) {
        setRefinements(response.data.refinements || [])
      }
    } catch (err) {
      console.error('Load refinement history error:', err)
    }
  }

  const handleRefine = async () => {
    if (!instruction.trim() || !conversationId) return

    setIsRefining(true)
    setError(null)

    try {
      const response = await api.post('/ai/refine', {
        conversation_id: conversationId,
        instruction: instruction.trim()
      })

      if (response.data.success) {
        const newRefinement = {
          id: response.data.refinement_id,
          round_number: response.data.round_number,
          instruction: instruction.trim(),
          refined_content: response.data.refined_content,
          operator_intent: response.data.operator_intent
        }

        setRefinements(prev => [...prev, newRefinement])
        setInstruction('')

        // 檢查知識建議
        if (response.data.knowledge_suggestion?.detected) {
          setKnowledgeSuggestion({
            items: response.data.knowledge_suggestion.items,
            refinementId: response.data.refinement_id
          })
        }
      } else {
        setError(response.data.message || '修正失敗')
      }
    } catch (err) {
      console.error('Refine error:', err)
      setError('修正失敗，請稍後再試')
    } finally {
      setIsRefining(false)
    }
  }

  const handleAcceptRefinement = async (refinementId) => {
    try {
      await api.post(`/ai/refinements/${refinementId}/accept`)
      // 更新本地狀態
      setRefinements(prev =>
        prev.map(r => r.id === refinementId ? { ...r, is_accepted: true } : r)
      )
      if (onAccept) onAccept(refinementId)
    } catch (err) {
      console.error('Accept refinement error:', err)
    }
  }

  const handleRejectRefinement = async (refinementId) => {
    try {
      await api.post(`/ai/refinements/${refinementId}/reject`)
      setRefinements(prev =>
        prev.map(r => r.id === refinementId ? { ...r, is_accepted: false } : r)
      )
    } catch (err) {
      console.error('Reject refinement error:', err)
    }
  }

  const handleSaveKnowledge = async (item, index) => {
    setSavingKnowledge(true)
    try {
      // 調用 Brain 知識儲存 API
      await api.post('/tools/call', {
        name: 'brain_save_knowledge',
        arguments: {
          content: item.content,
          category: item.category || 'faq',
          source: 'crm_refinement'
        }
      })

      // 移除已儲存的項目
      setKnowledgeSuggestion(prev => ({
        ...prev,
        items: prev.items.filter((_, i) => i !== index)
      }))

      // 如果所有項目都已處理，關閉建議
      if (knowledgeSuggestion.items.length <= 1) {
        setKnowledgeSuggestion(null)
      }
    } catch (err) {
      console.error('Save knowledge error:', err)
    } finally {
      setSavingKnowledge(false)
    }
  }

  const handleDismissKnowledge = () => {
    setKnowledgeSuggestion(null)
  }

  const handleUseVersion = (content) => {
    if (onUseVersion) {
      onUseVersion(content)
    }
  }

  // 取得目前最新版本的內容
  const currentContent = refinements.length > 0
    ? refinements[refinements.length - 1].refined_content
    : originalContent

  return (
    <div className="flex flex-col h-full bg-white rounded-lg shadow-lg">
      {/* 標題列 */}
      <div className="flex items-center justify-between px-4 py-3 border-b">
        <div className="flex items-center gap-2">
          <RefreshCw className="w-5 h-5 text-blue-600" />
          <h3 className="font-medium text-gray-900">修正 AI 回覆</h3>
          {refinements.length > 0 && (
            <span className="px-2 py-0.5 text-xs bg-blue-100 text-blue-700 rounded-full">
              第 {refinements.length} 輪
            </span>
          )}
        </div>
        <button
          onClick={onClose}
          className="p-1 text-gray-400 hover:text-gray-600 rounded"
        >
          <X className="w-5 h-5" />
        </button>
      </div>

      {/* 內容區域 */}
      <div className="flex-1 overflow-y-auto p-4 space-y-4">
        {/* 原始回覆 */}
        <div className="p-3 bg-gray-50 rounded-lg">
          <div className="flex items-center gap-2 mb-2">
            <span className="text-xs font-medium text-gray-500">原始回覆</span>
          </div>
          <p className="text-sm text-gray-700 whitespace-pre-wrap">{originalContent}</p>
        </div>

        {/* 修正歷史 */}
        {refinements.map((ref, index) => (
          <div key={ref.id || index} className="p-3 bg-blue-50 rounded-lg border border-blue-100">
            <div className="flex items-center justify-between mb-2">
              <div className="flex items-center gap-2">
                <History className="w-4 h-4 text-blue-600" />
                <span className="text-xs font-medium text-blue-700">
                  第 {ref.round_number || index + 1} 輪修正
                </span>
                <span className="text-xs text-gray-500">
                  「{ref.instruction}」
                </span>
              </div>
              <div className="flex items-center gap-1">
                {ref.is_accepted === true && (
                  <span className="px-2 py-0.5 text-xs bg-green-100 text-green-700 rounded">
                    已接受
                  </span>
                )}
                {ref.is_accepted === false && (
                  <span className="px-2 py-0.5 text-xs bg-red-100 text-red-700 rounded">
                    已拒絕
                  </span>
                )}
                {ref.is_accepted === null || ref.is_accepted === undefined ? (
                  <>
                    <button
                      onClick={() => handleAcceptRefinement(ref.id)}
                      className="p-1 text-green-600 hover:bg-green-100 rounded"
                      title="接受此修正"
                    >
                      <Check className="w-4 h-4" />
                    </button>
                    <button
                      onClick={() => handleRejectRefinement(ref.id)}
                      className="p-1 text-red-600 hover:bg-red-100 rounded"
                      title="拒絕此修正"
                    >
                      <X className="w-4 h-4" />
                    </button>
                  </>
                ) : null}
              </div>
            </div>
            <p className="text-sm text-gray-700 whitespace-pre-wrap mb-2">
              {ref.refined_content}
            </p>
            <button
              onClick={() => handleUseVersion(ref.refined_content)}
              className="text-xs text-blue-600 hover:text-blue-700 hover:underline"
            >
              使用此版本
            </button>
          </div>
        ))}

        {/* 知識建議 */}
        {knowledgeSuggestion && knowledgeSuggestion.items?.length > 0 && (
          <div className="p-3 bg-yellow-50 rounded-lg border border-yellow-200">
            <div className="flex items-center gap-2 mb-2">
              <Lightbulb className="w-4 h-4 text-yellow-600" />
              <span className="text-sm font-medium text-yellow-800">
                偵測到可儲存的知識
              </span>
              <button
                onClick={handleDismissKnowledge}
                className="ml-auto text-gray-400 hover:text-gray-600"
              >
                <X className="w-4 h-4" />
              </button>
            </div>
            <div className="space-y-2">
              {knowledgeSuggestion.items.map((item, index) => (
                <div key={index} className="p-2 bg-white rounded border border-yellow-100">
                  <p className="text-sm text-gray-700 mb-1">{item.content}</p>
                  <div className="flex items-center justify-between">
                    <span className="text-xs text-gray-500">
                      分類：{item.category}
                    </span>
                    <button
                      onClick={() => handleSaveKnowledge(item, index)}
                      disabled={savingKnowledge}
                      className="px-2 py-1 text-xs bg-yellow-600 text-white rounded hover:bg-yellow-700 disabled:opacity-50"
                    >
                      {savingKnowledge ? '儲存中...' : '儲存到知識庫'}
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* 錯誤訊息 */}
        {error && (
          <div className="p-3 bg-red-50 text-red-700 text-sm rounded-lg">
            {error}
          </div>
        )}
      </div>

      {/* 輸入區域 */}
      <div className="p-4 border-t">
        {/* 快捷指令 */}
        <div className="flex flex-wrap gap-1.5 mb-3">
          {QUICK_INSTRUCTIONS.map((cmd) => (
            <button
              key={cmd}
              onClick={() => setInstruction(cmd)}
              className="px-2 py-1 text-xs bg-gray-100 text-gray-600 rounded-full hover:bg-gray-200"
            >
              {cmd}
            </button>
          ))}
        </div>

        {/* 輸入框 */}
        <div className="flex gap-2">
          <input
            type="text"
            value={instruction}
            onChange={(e) => setInstruction(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && !e.shiftKey && handleRefine()}
            placeholder="輸入修正指令，如「語氣更親切」「更簡潔」..."
            className="flex-1 px-3 py-2 text-sm border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
            disabled={isRefining}
          />
          <button
            onClick={handleRefine}
            disabled={!instruction.trim() || isRefining}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
          >
            {isRefining ? (
              <>
                <RefreshCw className="w-4 h-4 animate-spin" />
                修正中
              </>
            ) : (
              <>
                <Send className="w-4 h-4" />
                送出
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  )
}
