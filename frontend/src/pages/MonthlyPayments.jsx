import { useState, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import {
  Calendar,
  List,
  ChevronLeft,
  ChevronRight,
  DollarSign,
  Clock,
  CheckCircle,
  AlertTriangle,
  TrendingUp,
  Filter
} from 'lucide-react'
import api from '../services/api'
import useStore from '../store/useStore'
import Badge from '../components/Badge'

// 月份名稱
const MONTH_NAMES = ['一月', '二月', '三月', '四月', '五月', '六月', '七月', '八月', '九月', '十月', '十一月', '十二月']
const WEEKDAY_NAMES = ['日', '一', '二', '三', '四', '五', '六']

// 付款方式對照
const PAYMENT_METHODS = {
  cash: '現金',
  transfer: '轉帳',
  credit_card: '信用卡',
  check: '支票'
}

// 狀態篩選選項
const STATUS_OPTIONS = [
  { value: 'all', label: '全部' },
  { value: 'paid', label: '已收款' },
  { value: 'pending', label: '待收款' },
  { value: 'overdue', label: '逾期' },
  { value: 'waived', label: '已減免' }
]

export default function MonthlyPayments() {
  const navigate = useNavigate()
  const selectedBranch = useStore((state) => state.selectedBranch)

  // 當前選擇的年月
  const [currentDate, setCurrentDate] = useState(() => {
    const now = new Date()
    return { year: now.getFullYear(), month: now.getMonth() }
  })

  // 視圖模式：calendar | list
  const [viewMode, setViewMode] = useState('calendar')

  // 狀態篩選
  const [statusFilter, setStatusFilter] = useState('all')

  // 計算月份範圍（使用本地日期格式，避免 toISOString UTC 時區偏移）
  const { startDate, endDate } = useMemo(() => {
    const year = currentDate.year
    const month = currentDate.month + 1 // 0-indexed to 1-indexed
    const lastDay = new Date(year, month, 0).getDate() // 該月最後一天
    return {
      startDate: `${year}-${String(month).padStart(2, '0')}-01`,
      endDate: `${year}-${String(month).padStart(2, '0')}-${String(lastDay).padStart(2, '0')}`
    }
  }, [currentDate])

  // 查詢該月的所有付款記錄
  const { data: payments = [], isLoading } = useQuery({
    queryKey: ['monthly-payments', currentDate.year, currentDate.month, selectedBranch],
    queryFn: async () => {
      // 查詢該月到期或付款的記錄
      // PostgREST 語法：or=(and(cond1,cond2),and(cond3,cond4)) 表示 (cond1 AND cond2) OR (cond3 AND cond4)
      const params = {
        select: 'id,contract_id,customer_id,branch_id,payment_period,amount,due_date,paid_at,payment_status,payment_method,notes,customer:customers(name,company_name),branch:branches(name),contract:contracts(contract_number)',
        or: `(and(due_date.gte.${startDate},due_date.lte.${endDate}),and(paid_at.gte.${startDate},paid_at.lte.${endDate}))`,
        order: 'due_date.asc',
        limit: 500
      }
      if (selectedBranch) {
        params.branch_id = `eq.${selectedBranch}`
      }
      // api.js 攔截器已回傳 response.data，這裡直接用 response
      const data = await api.get('/api/db/payments', { params })
      return data || []
    }
  })

  // 根據狀態篩選
  const filteredPayments = useMemo(() => {
    if (statusFilter === 'all') return payments

    const today = new Date().toISOString().split('T')[0]
    return payments.filter(p => {
      if (statusFilter === 'paid') return p.payment_status === 'paid'
      if (statusFilter === 'waived') return p.payment_status === 'waived'
      if (statusFilter === 'pending') return p.payment_status === 'pending' && p.due_date >= today
      if (statusFilter === 'overdue') return p.payment_status === 'pending' && p.due_date < today
      return true
    })
  }, [payments, statusFilter])

  // 統計數據
  const stats = useMemo(() => {
    const today = new Date().toISOString().split('T')[0]
    let collected = 0
    let pending = 0
    let overdue = 0
    let waived = 0
    let collectedCount = 0
    let pendingCount = 0
    let overdueCount = 0

    payments.forEach(p => {
      if (p.payment_status === 'paid') {
        collected += p.amount
        collectedCount++
      } else if (p.payment_status === 'waived') {
        waived += p.amount
      } else if (p.due_date < today) {
        overdue += p.amount
        overdueCount++
      } else {
        pending += p.amount
        pendingCount++
      }
    })

    return { collected, pending, overdue, waived, collectedCount, pendingCount, overdueCount }
  }, [payments])

  // 按日期分組（用於月曆視圖）
  const paymentsByDate = useMemo(() => {
    const map = {}
    filteredPayments.forEach(p => {
      // 優先使用付款日期，否則使用到期日
      const date = p.paid_at ? p.paid_at.split('T')[0] : p.due_date
      if (!map[date]) map[date] = []
      map[date].push(p)
    })
    return map
  }, [filteredPayments])

  // 生成月曆格子
  const calendarDays = useMemo(() => {
    const firstDay = new Date(currentDate.year, currentDate.month, 1)
    const lastDay = new Date(currentDate.year, currentDate.month + 1, 0)
    const startPadding = firstDay.getDay()
    const totalDays = lastDay.getDate()

    const days = []

    // 填充前面的空白
    for (let i = 0; i < startPadding; i++) {
      days.push({ day: null, date: null })
    }

    // 填充日期
    for (let d = 1; d <= totalDays; d++) {
      const date = `${currentDate.year}-${String(currentDate.month + 1).padStart(2, '0')}-${String(d).padStart(2, '0')}`
      days.push({ day: d, date, payments: paymentsByDate[date] || [] })
    }

    return days
  }, [currentDate, paymentsByDate])

  // 切換月份
  const changeMonth = (delta) => {
    setCurrentDate(prev => {
      let newMonth = prev.month + delta
      let newYear = prev.year

      if (newMonth < 0) {
        newMonth = 11
        newYear--
      } else if (newMonth > 11) {
        newMonth = 0
        newYear++
      }

      return { year: newYear, month: newMonth }
    })
  }

  // 跳到今天
  const goToToday = () => {
    const now = new Date()
    setCurrentDate({ year: now.getFullYear(), month: now.getMonth() })
  }

  // 格式化金額
  const formatAmount = (amount) => {
    return new Intl.NumberFormat('zh-TW').format(amount)
  }

  // 判斷是否為今天
  const isToday = (date) => {
    if (!date) return false
    return date === new Date().toISOString().split('T')[0]
  }

  // 取得狀態顏色
  const getStatusColor = (payment) => {
    const today = new Date().toISOString().split('T')[0]
    if (payment.payment_status === 'paid') return 'bg-green-100 text-green-800'
    if (payment.payment_status === 'waived') return 'bg-purple-100 text-purple-800'
    if (payment.due_date < today) return 'bg-red-100 text-red-800'
    return 'bg-yellow-100 text-yellow-800'
  }

  // 取得狀態文字
  const getStatusText = (payment) => {
    const today = new Date().toISOString().split('T')[0]
    if (payment.payment_status === 'paid') return '已收'
    if (payment.payment_status === 'waived') return '減免'
    if (payment.due_date < today) return '逾期'
    return '待收'
  }

  return (
    <div className="space-y-6">
      {/* 頁面標題與控制 */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">每月收款記錄</h1>
          <p className="text-gray-500 mt-1">追蹤每月收款狀況</p>
        </div>

        <div className="flex items-center gap-3">
          {/* 視圖切換 */}
          <div className="flex bg-gray-100 rounded-lg p-1">
            <button
              onClick={() => setViewMode('calendar')}
              className={`flex items-center gap-2 px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                viewMode === 'calendar'
                  ? 'bg-white text-gray-900 shadow-sm'
                  : 'text-gray-600 hover:text-gray-900'
              }`}
            >
              <Calendar className="w-4 h-4" />
              月曆
            </button>
            <button
              onClick={() => setViewMode('list')}
              className={`flex items-center gap-2 px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                viewMode === 'list'
                  ? 'bg-white text-gray-900 shadow-sm'
                  : 'text-gray-600 hover:text-gray-900'
              }`}
            >
              <List className="w-4 h-4" />
              列表
            </button>
          </div>

          {/* 狀態篩選 */}
          <div className="relative">
            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              className="appearance-none bg-white border border-gray-200 rounded-lg px-3 py-2 pr-8 text-sm focus:outline-none focus:ring-2 focus:ring-jungle-500"
            >
              {STATUS_OPTIONS.map(opt => (
                <option key={opt.value} value={opt.value}>{opt.label}</option>
              ))}
            </select>
            <Filter className="absolute right-2 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400 pointer-events-none" />
          </div>
        </div>
      </div>

      {/* 統計卡片 */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <div className="bg-white rounded-xl border border-gray-200 p-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-green-100 rounded-lg flex items-center justify-center">
              <CheckCircle className="w-5 h-5 text-green-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">已收款</p>
              <p className="text-xl font-bold text-gray-900">${formatAmount(stats.collected)}</p>
              <p className="text-xs text-gray-400">{stats.collectedCount} 筆</p>
            </div>
          </div>
        </div>

        <div className="bg-white rounded-xl border border-gray-200 p-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-yellow-100 rounded-lg flex items-center justify-center">
              <Clock className="w-5 h-5 text-yellow-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">待收款</p>
              <p className="text-xl font-bold text-gray-900">${formatAmount(stats.pending)}</p>
              <p className="text-xs text-gray-400">{stats.pendingCount} 筆</p>
            </div>
          </div>
        </div>

        <div className="bg-white rounded-xl border border-gray-200 p-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-red-100 rounded-lg flex items-center justify-center">
              <AlertTriangle className="w-5 h-5 text-red-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">逾期</p>
              <p className="text-xl font-bold text-red-600">${formatAmount(stats.overdue)}</p>
              <p className="text-xs text-gray-400">{stats.overdueCount} 筆</p>
            </div>
          </div>
        </div>

        <div className="bg-white rounded-xl border border-gray-200 p-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-jungle-100 rounded-lg flex items-center justify-center">
              <TrendingUp className="w-5 h-5 text-jungle-600" />
            </div>
            <div>
              <p className="text-sm text-gray-500">收款率</p>
              <p className="text-xl font-bold text-gray-900">
                {stats.collected + stats.pending + stats.overdue > 0
                  ? Math.round((stats.collected / (stats.collected + stats.pending + stats.overdue)) * 100)
                  : 0}%
              </p>
              <p className="text-xs text-gray-400">減免 ${formatAmount(stats.waived)}</p>
            </div>
          </div>
        </div>
      </div>

      {/* 月份導航 */}
      <div className="bg-white rounded-xl border border-gray-200 p-4">
        <div className="flex items-center justify-between">
          <button
            onClick={() => changeMonth(-1)}
            className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
          >
            <ChevronLeft className="w-5 h-5" />
          </button>

          <div className="flex items-center gap-4">
            <h2 className="text-xl font-bold text-gray-900">
              {currentDate.year} 年 {MONTH_NAMES[currentDate.month]}
            </h2>
            <button
              onClick={goToToday}
              className="px-3 py-1 text-sm text-jungle-600 hover:bg-jungle-50 rounded-lg transition-colors"
            >
              今天
            </button>
          </div>

          <button
            onClick={() => changeMonth(1)}
            className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
          >
            <ChevronRight className="w-5 h-5" />
          </button>
        </div>
      </div>

      {/* 主要內容區 */}
      {isLoading ? (
        <div className="flex items-center justify-center py-12">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-jungle-600"></div>
        </div>
      ) : viewMode === 'calendar' ? (
        /* 月曆視圖 */
        <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
          {/* 星期標題 */}
          <div className="grid grid-cols-7 bg-gray-50 border-b border-gray-200">
            {WEEKDAY_NAMES.map(name => (
              <div key={name} className="p-3 text-center text-sm font-medium text-gray-500">
                {name}
              </div>
            ))}
          </div>

          {/* 日曆格子 */}
          <div className="grid grid-cols-7">
            {calendarDays.map((cell, idx) => (
              <div
                key={idx}
                className={`min-h-[120px] border-b border-r border-gray-100 p-2 ${
                  cell.day === null ? 'bg-gray-50' : ''
                } ${isToday(cell.date) ? 'bg-jungle-50' : ''}`}
              >
                {cell.day && (
                  <>
                    <div className={`text-sm font-medium mb-1 ${
                      isToday(cell.date) ? 'text-jungle-600' : 'text-gray-900'
                    }`}>
                      {cell.day}
                    </div>
                    <div className="space-y-1 max-h-[80px] overflow-y-auto">
                      {cell.payments.slice(0, 3).map(payment => (
                        <div
                          key={payment.id}
                          onClick={() => navigate(`/contracts/${payment.contract_id}`)}
                          className={`text-xs px-1.5 py-0.5 rounded cursor-pointer hover:opacity-80 truncate ${getStatusColor(payment)}`}
                          title={`${payment.customer?.company_name || payment.customer?.name} - $${formatAmount(payment.amount)}`}
                        >
                          ${formatAmount(payment.amount)}
                        </div>
                      ))}
                      {cell.payments.length > 3 && (
                        <div className="text-xs text-gray-400 text-center">
                          +{cell.payments.length - 3} 筆
                        </div>
                      )}
                    </div>
                  </>
                )}
              </div>
            ))}
          </div>
        </div>
      ) : (
        /* 列表視圖 */
        <div className="bg-white rounded-xl border border-gray-200 overflow-hidden">
          <table className="w-full">
            <thead className="bg-gray-50 border-b border-gray-200">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-500">日期</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-500">客戶</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-500">合約</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-500">期別</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-500">金額</th>
                <th className="px-4 py-3 text-center text-sm font-medium text-gray-500">狀態</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-500">付款方式</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100">
              {filteredPayments.length === 0 ? (
                <tr>
                  <td colSpan={7} className="px-4 py-12 text-center text-gray-500">
                    本月無收款記錄
                  </td>
                </tr>
              ) : (
                filteredPayments.map(payment => (
                  <tr
                    key={payment.id}
                    onClick={() => navigate(`/contracts/${payment.contract_id}`)}
                    className="hover:bg-gray-50 cursor-pointer"
                  >
                    <td className="px-4 py-3">
                      <div className="text-sm text-gray-900">
                        {payment.paid_at ? payment.paid_at.split('T')[0] : payment.due_date}
                      </div>
                      <div className="text-xs text-gray-400">
                        {payment.paid_at ? '付款日' : '到期日'}
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      <div className="text-sm font-medium text-gray-900">
                        {payment.customer?.company_name || payment.customer?.name}
                      </div>
                      {payment.branch?.name && (
                        <div className="text-xs text-gray-400">{payment.branch.name}</div>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <span className="text-sm text-jungle-600 font-medium">
                        {payment.contract?.contract_number}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-sm text-gray-600">
                      第 {payment.payment_period} 期
                    </td>
                    <td className="px-4 py-3 text-right">
                      <span className="text-sm font-medium text-gray-900">
                        ${formatAmount(payment.amount)}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-center">
                      <span className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${getStatusColor(payment)}`}>
                        {getStatusText(payment)}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-sm text-gray-600">
                      {payment.payment_method ? PAYMENT_METHODS[payment.payment_method] || payment.payment_method : '-'}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      )}

      {/* 圖例說明 */}
      <div className="flex items-center justify-center gap-6 text-sm text-gray-500">
        <div className="flex items-center gap-2">
          <span className="w-3 h-3 bg-green-100 rounded"></span>
          <span>已收款</span>
        </div>
        <div className="flex items-center gap-2">
          <span className="w-3 h-3 bg-yellow-100 rounded"></span>
          <span>待收款</span>
        </div>
        <div className="flex items-center gap-2">
          <span className="w-3 h-3 bg-red-100 rounded"></span>
          <span>逾期</span>
        </div>
        <div className="flex items-center gap-2">
          <span className="w-3 h-3 bg-purple-100 rounded"></span>
          <span>已減免</span>
        </div>
      </div>
    </div>
  )
}
