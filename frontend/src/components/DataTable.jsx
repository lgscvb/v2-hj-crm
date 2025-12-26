import { useState, useId, useEffect } from 'react'
import PropTypes from 'prop-types'
import {
  ChevronUp,
  ChevronDown,
  ChevronsUpDown,
  ChevronLeft,
  ChevronRight,
  Search,
  Download,
  RefreshCw
} from 'lucide-react'

/**
 * DataTable 通用表格組件
 *
 * @param {Object[]} columns - 欄位定義陣列
 * @param {string} columns[].header - 表頭標題（必填）
 * @param {string} [columns[].accessor] - 資料欄位名稱（用於取值和排序）
 * @param {Function} [columns[].cell] - 自定義渲染函數 (row, index) => ReactNode
 * @param {boolean} [columns[].sortable=true] - 是否可排序
 * @param {string} [columns[].width] - 欄位寬度
 * @param {string} [columns[].className] - 額外 CSS class
 * @param {Object[]} data - 資料陣列
 * @param {boolean} [loading=false] - 載入中狀態
 * @param {boolean} [searchable=true] - 是否顯示搜尋框
 * @param {boolean} [exportable=true] - 是否顯示匯出按鈕
 * @param {boolean} [pagination=true] - 是否啟用分頁
 * @param {number} [pageSize=10] - 每頁筆數
 * @param {Function} [onRefresh] - 重新整理回調
 * @param {Function} [onRowClick] - 列點擊回調
 * @param {string} [emptyMessage='沒有資料'] - 空資料訊息
 * @param {ReactNode} [actions] - 額外操作按鈕
 * @param {string} [id] - 表格 ID
 */
export default function DataTable({
  columns,
  data = [],
  loading = false,
  searchable = true,
  exportable = true,
  pagination = true,
  pageSize = 10,
  onRefresh,
  onRowClick,
  emptyMessage = '沒有資料',
  actions,
  id: tableId
}) {
  // 開發環境：檢查 columns 格式是否正確
  useEffect(() => {
    if (process.env.NODE_ENV === 'development' && columns) {
      columns.forEach((col, index) => {
        // 檢查是否使用了錯誤的屬性名稱
        if (col.key !== undefined && col.accessor === undefined) {
          console.warn(
            `[DataTable] columns[${index}] 使用了 "key" 屬性，應改為 "accessor"。` +
            `\n正確格式：{ accessor: '${col.key}', header: '...', cell: (row) => ... }`
          )
        }
        if (col.label !== undefined && col.header === undefined) {
          console.warn(
            `[DataTable] columns[${index}] 使用了 "label" 屬性，應改為 "header"。` +
            `\n正確格式：{ accessor: '...', header: '${col.label}', cell: (row) => ... }`
          )
        }
        if (col.render !== undefined && col.cell === undefined) {
          console.warn(
            `[DataTable] columns[${index}] 使用了 "render" 屬性，應改為 "cell"。` +
            `\n注意：cell 函數簽名是 (row, index) => ReactNode，而非 (value, row) => ReactNode`
          )
        }
        // 檢查必填屬性
        if (!col.header) {
          console.warn(
            `[DataTable] columns[${index}] 缺少 "header" 屬性（表頭標題）。`
          )
        }
      })
    }
  }, [columns])

  // 生成唯一 ID（若未提供）
  const generatedId = useId()
  const uniqueId = tableId || generatedId
  const [search, setSearch] = useState('')
  const [sortKey, setSortKey] = useState(null)
  const [sortDir, setSortDir] = useState('asc')
  const [currentPage, setCurrentPage] = useState(1)

  // 確保 data 是陣列
  const safeData = Array.isArray(data) ? data : []

  // 搜尋過濾
  const filteredData = safeData.filter((row) => {
    if (!search) return true
    return columns.some((col) => {
      const value = col.accessor ? row[col.accessor] : ''
      return String(value).toLowerCase().includes(search.toLowerCase())
    })
  })

  // 排序
  const sortedData = [...filteredData].sort((a, b) => {
    if (!sortKey) return 0
    const aVal = a[sortKey]
    const bVal = b[sortKey]
    if (aVal < bVal) return sortDir === 'asc' ? -1 : 1
    if (aVal > bVal) return sortDir === 'asc' ? 1 : -1
    return 0
  })

  // 分頁
  const totalPages = Math.ceil(sortedData.length / pageSize)
  const paginatedData = pagination
    ? sortedData.slice((currentPage - 1) * pageSize, currentPage * pageSize)
    : sortedData

  const handleSort = (key) => {
    if (sortKey === key) {
      setSortDir(sortDir === 'asc' ? 'desc' : 'asc')
    } else {
      setSortKey(key)
      setSortDir('asc')
    }
  }

  const handleExport = () => {
    const headers = columns.map((col) => col.header).join(',')
    const rows = sortedData
      .map((row) =>
        columns
          .map((col) => {
            const value = col.accessor ? row[col.accessor] : ''
            return `"${String(value).replace(/"/g, '""')}"`
          })
          .join(',')
      )
      .join('\n')

    const csv = `${headers}\n${rows}`
    const blob = new Blob(['\ufeff' + csv], { type: 'text/csv;charset=utf-8;' })
    const url = URL.createObjectURL(blob)
    const link = document.createElement('a')
    link.href = url
    link.download = `export_${new Date().toISOString().split('T')[0]}.csv`
    link.click()
  }

  return (
    <div className="bg-white rounded-xl shadow-sm border border-gray-200 overflow-hidden">
      {/* Toolbar */}
      <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4 p-4 border-b border-gray-200">
        <div className="flex items-center gap-3 w-full sm:w-auto">
          {searchable && (
            <div className="relative flex-1 sm:w-64">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
              <input
                id={`${uniqueId}-search`}
                name={`${uniqueId}-search`}
                type="text"
                placeholder="搜尋..."
                aria-label="搜尋表格"
                value={search}
                onChange={(e) => {
                  setSearch(e.target.value)
                  setCurrentPage(1)
                }}
                className="w-full pl-9 pr-4 py-2 text-sm border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
              />
            </div>
          )}
        </div>

        <div className="flex items-center gap-2">
          {actions}
          {onRefresh && (
            <button
              onClick={onRefresh}
              className="p-2 text-gray-500 hover:text-gray-700 hover:bg-gray-100 rounded-lg"
              title="重新整理"
            >
              <RefreshCw className="w-4 h-4" />
            </button>
          )}
          {exportable && (
            <button
              onClick={handleExport}
              className="p-2 text-gray-500 hover:text-gray-700 hover:bg-gray-100 rounded-lg"
              title="匯出 CSV"
            >
              <Download className="w-4 h-4" />
            </button>
          )}
        </div>
      </div>

      {/* Table */}
      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-gray-200">
          <thead className="bg-gray-50">
            <tr>
              {columns.map((col) => (
                <th
                  key={col.accessor || col.header}
                  scope="col"
                  className={`px-4 py-3 text-left text-xs font-semibold text-gray-600 uppercase tracking-wider ${
                    col.sortable !== false ? 'cursor-pointer hover:bg-gray-100' : ''
                  } ${col.className || ''}`}
                  style={col.width ? { width: col.width, minWidth: col.width } : undefined}
                  onClick={() => col.sortable !== false && col.accessor && handleSort(col.accessor)}
                >
                  <div className="flex items-center gap-1">
                    {col.header}
                    {col.sortable !== false && col.accessor && (
                      <span className="text-gray-400">
                        {sortKey === col.accessor ? (
                          sortDir === 'asc' ? (
                            <ChevronUp className="w-4 h-4" />
                          ) : (
                            <ChevronDown className="w-4 h-4" />
                          )
                        ) : (
                          <ChevronsUpDown className="w-4 h-4" />
                        )}
                      </span>
                    )}
                  </div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="bg-white divide-y divide-gray-200">
            {loading ? (
              <tr>
                <td colSpan={columns.length} className="px-4 py-12 text-center">
                  <div className="flex flex-col items-center gap-2">
                    <RefreshCw className="w-6 h-6 text-gray-400 animate-spin" />
                    <span className="text-gray-500">載入中...</span>
                  </div>
                </td>
              </tr>
            ) : paginatedData.length === 0 ? (
              <tr>
                <td colSpan={columns.length} className="px-4 py-12 text-center text-gray-500">
                  {emptyMessage}
                </td>
              </tr>
            ) : (
              paginatedData.map((row, rowIndex) => (
                <tr
                  key={row.id || rowIndex}
                  onClick={() => onRowClick?.(row)}
                  className={`hover:bg-gray-50 transition-colors ${
                    onRowClick ? 'cursor-pointer' : ''
                  }`}
                >
                  {columns.map((col) => (
                    <td
                      key={col.accessor || col.header}
                      className={`px-4 py-3 text-sm text-gray-700 whitespace-nowrap ${col.className || ''}`}
                      style={col.width ? { width: col.width, minWidth: col.width } : undefined}
                    >
                      {col.cell ? col.cell(row, (currentPage - 1) * pageSize + rowIndex) : row[col.accessor]}
                    </td>
                  ))}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>

      {/* Pagination */}
      {pagination && totalPages > 1 && (
        <div className="flex items-center justify-between px-4 py-3 border-t border-gray-200 bg-gray-50">
          <div className="text-sm text-gray-500">
            顯示 {(currentPage - 1) * pageSize + 1} -{' '}
            {Math.min(currentPage * pageSize, sortedData.length)} 筆，共 {sortedData.length} 筆
          </div>
          <div className="flex items-center gap-1">
            <button
              onClick={() => setCurrentPage(Math.max(1, currentPage - 1))}
              disabled={currentPage === 1}
              className="p-2 text-gray-500 hover:text-gray-700 hover:bg-gray-200 rounded-lg disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <ChevronLeft className="w-4 h-4" />
            </button>
            {Array.from({ length: Math.min(5, totalPages) }, (_, i) => {
              let pageNum
              if (totalPages <= 5) {
                pageNum = i + 1
              } else if (currentPage <= 3) {
                pageNum = i + 1
              } else if (currentPage >= totalPages - 2) {
                pageNum = totalPages - 4 + i
              } else {
                pageNum = currentPage - 2 + i
              }
              return (
                <button
                  key={pageNum}
                  onClick={() => setCurrentPage(pageNum)}
                  className={`w-8 h-8 text-sm rounded-lg ${
                    currentPage === pageNum
                      ? 'bg-primary-600 text-white'
                      : 'text-gray-600 hover:bg-gray-200'
                  }`}
                >
                  {pageNum}
                </button>
              )
            })}
            <button
              onClick={() => setCurrentPage(Math.min(totalPages, currentPage + 1))}
              disabled={currentPage === totalPages}
              className="p-2 text-gray-500 hover:text-gray-700 hover:bg-gray-200 rounded-lg disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <ChevronRight className="w-4 h-4" />
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

// PropTypes 定義
DataTable.propTypes = {
  /** 欄位定義陣列 */
  columns: PropTypes.arrayOf(
    PropTypes.shape({
      /** 表頭標題（必填） */
      header: PropTypes.string.isRequired,
      /** 資料欄位名稱（用於取值和排序） */
      accessor: PropTypes.string,
      /** 自定義渲染函數 (row, index) => ReactNode */
      cell: PropTypes.func,
      /** 是否可排序（預設 true） */
      sortable: PropTypes.bool,
      /** 欄位寬度 */
      width: PropTypes.string,
      /** 額外 CSS class */
      className: PropTypes.string
    })
  ).isRequired,
  /** 資料陣列 */
  data: PropTypes.array,
  /** 載入中狀態 */
  loading: PropTypes.bool,
  /** 是否顯示搜尋框 */
  searchable: PropTypes.bool,
  /** 是否顯示匯出按鈕 */
  exportable: PropTypes.bool,
  /** 是否啟用分頁 */
  pagination: PropTypes.bool,
  /** 每頁筆數 */
  pageSize: PropTypes.number,
  /** 重新整理回調 */
  onRefresh: PropTypes.func,
  /** 列點擊回調 */
  onRowClick: PropTypes.func,
  /** 空資料訊息 */
  emptyMessage: PropTypes.string,
  /** 額外操作按鈕 */
  actions: PropTypes.node,
  /** 表格 ID */
  id: PropTypes.string
}
