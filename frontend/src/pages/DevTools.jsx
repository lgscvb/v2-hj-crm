/**
 * 開發者工具頁面
 *
 * 功能：
 * - 測試資料清理
 * - 系統狀態檢查
 */

import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { Trash2, AlertTriangle, CheckCircle, XCircle, Terminal, RefreshCw } from 'lucide-react'
import { devTools } from '../services/api'
import { toast } from 'react-hot-toast'

export default function DevTools() {
  const [quoteId, setQuoteId] = useState('')
  const [contractId, setContractId] = useState('')
  const [customerId, setCustomerId] = useState('')
  const [result, setResult] = useState(null)

  const cleanupMutation = useMutation({
    mutationFn: (data) => devTools.cleanupTestData(data),
    onSuccess: (data) => {
      setResult(data)
      if (data.success) {
        toast.success('測試資料已清理')
      } else {
        toast.error(data.message || '清理失敗')
      }
    },
    onError: (error) => {
      toast.error(`清理失敗: ${error.message}`)
      setResult({ success: false, error: error.message })
    }
  })

  const handleCleanup = () => {
    if (!quoteId && !contractId && !customerId) {
      toast.error('請至少輸入一個 ID')
      return
    }

    if (!confirm('確定要刪除這些測試資料嗎？此操作無法復原！')) {
      return
    }

    cleanupMutation.mutate({
      quoteId: quoteId ? parseInt(quoteId) : null,
      contractId: contractId ? parseInt(contractId) : null,
      customerId: customerId ? parseInt(customerId) : null
    })
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center gap-3">
        <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-gray-700 to-gray-900 flex items-center justify-center">
          <Terminal className="w-6 h-6 text-white" />
        </div>
        <div>
          <h1 className="text-xl font-bold text-gray-900">開發者工具</h1>
          <p className="text-sm text-gray-500">測試資料清理、系統診斷</p>
        </div>
      </div>

      {/* 警告 */}
      <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4 flex items-start gap-3">
        <AlertTriangle className="w-5 h-5 text-yellow-600 flex-shrink-0 mt-0.5" />
        <div>
          <p className="font-medium text-yellow-800">注意：此頁面僅供開發測試使用</p>
          <p className="text-sm text-yellow-700 mt-1">
            刪除操作無法復原，請確認 ID 正確後再執行
          </p>
        </div>
      </div>

      {/* 測試資料清理 */}
      <div className="bg-white rounded-xl border border-gray-200 p-6">
        <h2 className="text-lg font-semibold text-gray-900 mb-4 flex items-center gap-2">
          <Trash2 className="w-5 h-5 text-red-500" />
          測試資料清理
        </h2>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              報價單 ID
            </label>
            <input
              type="number"
              value={quoteId}
              onChange={(e) => setQuoteId(e.target.value)}
              placeholder="如：89"
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500 focus:border-red-500"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              合約 ID
            </label>
            <input
              type="number"
              value={contractId}
              onChange={(e) => setContractId(e.target.value)}
              placeholder="如：1240"
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500 focus:border-red-500"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              客戶 ID（可選）
            </label>
            <input
              type="number"
              value={customerId}
              onChange={(e) => setCustomerId(e.target.value)}
              placeholder="如：2361"
              className="w-full px-3 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-red-500 focus:border-red-500"
            />
          </div>
        </div>

        <p className="text-sm text-gray-500 mb-4">
          刪除順序：付款記錄 → 合約 → 報價單 → 客戶（如無其他合約）
        </p>

        <button
          onClick={handleCleanup}
          disabled={cleanupMutation.isPending}
          className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2"
        >
          {cleanupMutation.isPending ? (
            <>
              <RefreshCw className="w-4 h-4 animate-spin" />
              清理中...
            </>
          ) : (
            <>
              <Trash2 className="w-4 h-4" />
              刪除測試資料
            </>
          )}
        </button>
      </div>

      {/* 執行結果 */}
      {result && (
        <div className={`rounded-xl border p-6 ${
          result.success ? 'bg-green-50 border-green-200' : 'bg-red-50 border-red-200'
        }`}>
          <h3 className={`font-semibold mb-3 flex items-center gap-2 ${
            result.success ? 'text-green-800' : 'text-red-800'
          }`}>
            {result.success ? (
              <CheckCircle className="w-5 h-5" />
            ) : (
              <XCircle className="w-5 h-5" />
            )}
            執行結果
          </h3>

          {result.deleted && result.deleted.length > 0 && (
            <div className="mb-3">
              <p className="text-sm font-medium text-gray-700 mb-1">已刪除：</p>
              <ul className="list-disc list-inside text-sm text-gray-600 space-y-1">
                {result.deleted.map((item, i) => (
                  <li key={i}>{item}</li>
                ))}
              </ul>
            </div>
          )}

          {result.errors && result.errors.length > 0 && (
            <div>
              <p className="text-sm font-medium text-red-700 mb-1">錯誤：</p>
              <ul className="list-disc list-inside text-sm text-red-600 space-y-1">
                {result.errors.map((err, i) => (
                  <li key={i}>{err}</li>
                ))}
              </ul>
            </div>
          )}

          {result.error && (
            <p className="text-sm text-red-600">{result.error}</p>
          )}

          {result.message && (
            <p className="text-sm text-gray-600">{result.message}</p>
          )}
        </div>
      )}
    </div>
  )
}
