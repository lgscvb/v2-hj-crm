import { useState } from 'react'
import { useBranchRevenue, useDashboardStats, useTodayTasks, useOverdueDetails, useRenewalReminders, usePaymentsDue, useTodayBookings, useTerminationCases, usePendingSignContracts, useTerminationWorkspace } from '../hooks/useApi'
import { useNavigate } from 'react-router-dom'
import {
  Users,
  FileText,
  CreditCard,
  AlertTriangle,
  TrendingUp,
  Calendar,
  Bell,
  ArrowRight,
  Building2,
  DollarSign,
  CheckCircle,
  Clock,
  Zap,
  Send,
  Loader2,
  MessageCircle,
  History,
  Power,
  FileX,
  PenTool
} from 'lucide-react'
import { line } from '../services/api'
import StatCard from '../components/StatCard'
import Badge, { StatusBadge } from '../components/Badge'
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, PieChart, Pie, Cell } from 'recharts'

const COLORS = ['#22c55e', '#3b82f6', '#f59e0b', '#ef4444']

// ============================================================================
// 續約 Checklist 相關：直接使用 v_renewal_reminders 的計算欄位
// ============================================================================

// ★ 2026-01-01 重構：直接讀取 View 計算的 completion_score
// 不再在前端計算，保持 SSOT 原則
// ★ 修復：completion_score 已改為 0-7（7 步驟）
function getDisplayStatus(contract) {
  // 直接使用 View 的 completion_score（0-7）
  const score = contract.completion_score || 0

  if (score >= 7) return { stage: 'completed', progress: 7 }
  if (score === 0) return { stage: 'pending', progress: 0 }
  return { stage: 'in_progress', progress: score }
}

export default function Dashboard() {
  const navigate = useNavigate()
  const { data: branchRevenue, isLoading: revenueLoading } = useBranchRevenue()
  const { data: dashboardStats, isLoading: statsLoading } = useDashboardStats()
  const { data: todayTasks, isLoading: tasksLoading } = useTodayTasks()
  const { data: overdue, isLoading: overdueLoading, refetch: refetchOverdue } = useOverdueDetails()
  const { data: renewals } = useRenewalReminders()
  const { data: paymentsDue } = usePaymentsDue()
  const { data: todayBookings, isLoading: bookingsLoading } = useTodayBookings()
  const { data: terminationCases } = useTerminationCases()
  const { data: pendingSignContracts } = usePendingSignContracts()
  const { data: terminationWorkspace } = useTerminationWorkspace()

  // 催繳狀態
  const [sendingReminder, setSendingReminder] = useState({})
  const [reminderResult, setReminderResult] = useState({})

  // 自動通知開關
  const [autoNotifyEnabled, setAutoNotifyEnabled] = useState(false)

  // 通知記錄（TODO: 接入後端 API）
  const [notificationHistory] = useState([])

  // 發送催繳
  const handleSendReminder = async (item) => {
    const key = `${item.customer_id}-${item.payment_period}`
    setSendingReminder(prev => ({ ...prev, [key]: true }))
    setReminderResult(prev => ({ ...prev, [key]: null }))

    try {
      await line.sendPaymentReminder(
        item.customer_id,
        item.total_due || item.amount,
        item.due_date
      )
      setReminderResult(prev => ({ ...prev, [key]: 'success' }))
      // 3秒後清除成功狀態
      setTimeout(() => {
        setReminderResult(prev => ({ ...prev, [key]: null }))
      }, 3000)
    } catch (error) {
      console.error('催繳失敗:', error)
      setReminderResult(prev => ({ ...prev, [key]: 'error' }))
    } finally {
      setSendingReminder(prev => ({ ...prev, [key]: false }))
    }
  }

  // ★ 2025-12-31 重構：改用 v_dashboard_stats View（已在資料庫聚合）
  // 移除前端 reduce() 計算，保持 SSOT 原則
  const branchRevenueArr = Array.isArray(branchRevenue) ? branchRevenue : []

  // 從 View 取得聚合統計
  const receivable = Number(dashboardStats?.monthly_receivable) || 0
  const receivableCount = Number(dashboardStats?.receivable_count) || 0
  const received = Number(dashboardStats?.monthly_revenue) || 0
  const receivedCount = Number(dashboardStats?.paid_count) || 0
  const outstanding = Number(dashboardStats?.monthly_outstanding) || 0
  const outstandingCount = Number(dashboardStats?.outstanding_count) || 0
  const overdueAmount = Number(dashboardStats?.monthly_overdue) || 0
  const overdueCount = Number(dashboardStats?.overdue_count) || 0
  const monthlyPending = Number(dashboardStats?.monthly_pending) || 0

  // 圖表資料
  const chartData = branchRevenueArr.map((b) => ({
    name: b.branch_name,
    營收: b.current_month_revenue || 0,
    待收: b.current_month_pending || 0,
    逾期: b.current_month_overdue || 0
  }))

  const pieData = [
    { name: '已收款', value: received },
    { name: '待收款', value: monthlyPending },
    { name: '逾期', value: overdueAmount }
  ].filter(d => d.value > 0)

  const priorityIcon = {
    urgent: '🔴',
    high: '🟠',
    medium: '🟡',
    payment_due: '💰',
    contract_expiring: '📄',
    commission_due: '💼'
  }

  // 當月應催繳列表（待繳 + 逾期）
  const currentMonthDue = Array.isArray(paymentsDue) ? paymentsDue : []

  // 45天內到期的合約
  const upcomingRenewals = Array.isArray(renewals) ? renewals.filter(r => r.days_until_expiry <= 45) : []

  return (
    <div className="space-y-6">
      {/* 自動通知開關 */}
      <div className="card">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <Power className={`w-5 h-5 ${autoNotifyEnabled ? 'text-green-500' : 'text-gray-400'}`} />
            <div>
              <h3 className="font-semibold text-gray-900">自動通知系統</h3>
              <p className="text-sm text-gray-500">自動發送繳費提醒與續約通知</p>
            </div>
          </div>
          <button
            onClick={() => setAutoNotifyEnabled(!autoNotifyEnabled)}
            className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
              autoNotifyEnabled ? 'bg-green-500' : 'bg-gray-300'
            }`}
          >
            <span
              className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${
                autoNotifyEnabled ? 'translate-x-6' : 'translate-x-1'
              }`}
            />
          </button>
        </div>
      </div>

      {/* 今日預約 */}
      {todayBookings?.length > 0 && (
        <div className="card">
          <div className="card-header">
            <h3 className="card-title flex items-center gap-2">
              <Calendar className="w-5 h-5 text-blue-500" />
              今日會議室預約
            </h3>
            <button
              onClick={() => navigate('/bookings')}
              className="text-sm text-primary-600 hover:text-primary-700 flex items-center gap-1"
            >
              查看全部 <ArrowRight className="w-4 h-4" />
            </button>
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
            {todayBookings.map((booking) => (
              <div
                key={booking.id}
                className="flex items-center gap-3 p-3 bg-blue-50 rounded-lg border border-blue-100"
              >
                <div className="flex-shrink-0 w-12 h-12 bg-blue-100 rounded-lg flex flex-col items-center justify-center">
                  <span className="text-xs text-blue-600 font-medium">
                    {booking.start_time?.slice(0, 5)}
                  </span>
                  <span className="text-xs text-blue-400">
                    {booking.end_time?.slice(0, 5)}
                  </span>
                </div>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-gray-900 truncate">
                    {booking.customer_name}
                  </p>
                  <p className="text-xs text-gray-500 truncate">
                    {booking.company_name || '個人'} · {booking.duration_minutes}分鐘
                  </p>
                </div>
                <Badge variant="info">已確認</Badge>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* 財務統計卡片 - 最重要 */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          title="本期應收"
          value={`$${receivable.toLocaleString()}`}
          subtitle={`共 ${receivableCount} 筆`}
          icon={DollarSign}
          iconBg="bg-blue-100"
          iconColor="text-blue-600"
          loading={statsLoading}
        />
        <StatCard
          title="本期已收"
          value={`$${received.toLocaleString()}`}
          subtitle={`共 ${receivedCount} 筆`}
          icon={CheckCircle}
          iconBg="bg-green-100"
          iconColor="text-green-600"
          loading={statsLoading}
        />
        <StatCard
          title="本期未收"
          value={`$${outstanding.toLocaleString()}`}
          subtitle={`共 ${outstandingCount} 筆`}
          icon={Clock}
          iconBg="bg-amber-100"
          iconColor="text-amber-600"
          loading={statsLoading}
        />
        <StatCard
          title="逾期金額"
          value={`$${overdueAmount.toLocaleString()}`}
          subtitle={`共 ${overdueCount} 筆`}
          icon={AlertTriangle}
          iconBg="bg-red-100"
          iconColor="text-red-600"
          loading={statsLoading}
        />
      </div>

      {/* 續約流程（合併版）- 6 階段一條龍 */}
      {(renewals?.length > 0 || pendingSignContracts?.length > 0) && (() => {
        // 從 renewals 計算前段流程
        const renewalCounts = (renewals || []).reduce((acc, r) => {
          const status = getDisplayStatus(r)
          // 急件：7 天內到期且未完成
          if (r.days_until_expiry <= 7 && status.stage !== 'completed') {
            acc.urgent = (acc.urgent || 0) + 1
          }
          // 待通知：尚未開始（completion_score = 0）
          if (status.progress === 0) {
            acc.need_notify = (acc.need_notify || 0) + 1
          }
          // 確認中：已通知但尚未建立新合約（completion_score 1-3）
          else if (status.progress >= 1 && status.progress <= 3) {
            acc.confirming = (acc.confirming || 0) + 1
          }
          // 已完成
          if (status.stage === 'completed') {
            acc.completed = (acc.completed || 0) + 1
          }
          return acc
        }, { urgent: 0, need_notify: 0, confirming: 0, completed: 0 })

        // 從 pendingSignContracts 計算後段流程
        const signingCounts = (pendingSignContracts || []).reduce((acc, c) => {
          if (c.status === 'renewal_draft' && !c.sent_for_sign_at) {
            acc.need_send = (acc.need_send || 0) + 1
          } else if (c.status === 'pending_sign') {
            acc.waiting = (acc.waiting || 0) + 1
          } else if (c.status === 'signed') {
            acc.need_activate = (acc.need_activate || 0) + 1
          }
          return acc
        }, { need_send: 0, waiting: 0, need_activate: 0 })

        // 計算待處理總數（不含已完成）
        const totalPending = renewalCounts.urgent + renewalCounts.need_notify + renewalCounts.confirming +
          signingCounts.need_send + signingCounts.waiting + signingCounts.need_activate
        const totalContracts = (renewals?.length || 0)

        return (
          <div className="card">
            <div className="card-header">
              <h3 className="card-title flex items-center gap-2">
                <Bell className="w-5 h-5 text-orange-500" />
                續約流程
              </h3>
              <div className="flex gap-2">
                {renewalCounts.urgent > 0 && (
                  <Badge variant="danger">{renewalCounts.urgent} 急件</Badge>
                )}
                {totalPending > 0 && (
                  <Badge variant="warning">{totalPending} 待處理</Badge>
                )}
                <Badge variant="secondary">{totalContracts} 份</Badge>
              </div>
            </div>
            {/* 6 階段流程 */}
            <div className="grid grid-cols-3 sm:grid-cols-6 gap-2">
              {/* 1. 急件 */}
              <div
                className={`rounded-lg p-3 text-center cursor-pointer transition-colors relative ${
                  renewalCounts.urgent > 0
                    ? 'bg-red-100 text-red-700 hover:bg-red-200'
                    : 'bg-gray-50 text-gray-400'
                }`}
                onClick={() => navigate('/renewals')}
              >
                {renewalCounts.urgent > 0 && (
                  <Zap className="w-3 h-3 absolute top-1 right-1 opacity-50" />
                )}
                <div className="text-xl font-bold">{renewalCounts.urgent}</div>
                <div className="text-xs">急件</div>
              </div>
              {/* 2. 待通知 */}
              <div
                className={`rounded-lg p-3 text-center cursor-pointer transition-colors ${
                  renewalCounts.need_notify > 0
                    ? 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                    : 'bg-gray-50 text-gray-400'
                }`}
                onClick={() => navigate('/renewals')}
              >
                <div className="text-xl font-bold">{renewalCounts.need_notify}</div>
                <div className="text-xs">待通知</div>
              </div>
              {/* 3. 確認中 */}
              <div
                className={`rounded-lg p-3 text-center cursor-pointer transition-colors ${
                  renewalCounts.confirming > 0
                    ? 'bg-amber-100 text-amber-700 hover:bg-amber-200'
                    : 'bg-gray-50 text-gray-400'
                }`}
                onClick={() => navigate('/renewals')}
              >
                <div className="text-xl font-bold">{renewalCounts.confirming}</div>
                <div className="text-xs">確認中</div>
              </div>
              {/* 4. 待簽約 */}
              <div
                className={`rounded-lg p-3 text-center cursor-pointer transition-colors ${
                  signingCounts.need_send > 0
                    ? 'bg-blue-100 text-blue-700 hover:bg-blue-200'
                    : 'bg-gray-50 text-gray-400'
                }`}
                onClick={() => navigate('/contracts?tab=pending')}
              >
                <div className="text-xl font-bold">{signingCounts.need_send}</div>
                <div className="text-xs">待簽約</div>
              </div>
              {/* 5. 待回簽 */}
              <div
                className={`rounded-lg p-3 text-center cursor-pointer transition-colors ${
                  signingCounts.waiting > 0
                    ? 'bg-purple-100 text-purple-700 hover:bg-purple-200'
                    : 'bg-gray-50 text-gray-400'
                }`}
                onClick={() => navigate('/contracts?tab=pending')}
              >
                <div className="text-xl font-bold">{signingCounts.waiting}</div>
                <div className="text-xs">待回簽</div>
              </div>
              {/* 6. 待啟用 */}
              <div
                className={`rounded-lg p-3 text-center cursor-pointer transition-colors ${
                  signingCounts.need_activate > 0
                    ? 'bg-green-100 text-green-700 hover:bg-green-200'
                    : 'bg-gray-50 text-gray-400'
                }`}
                onClick={() => navigate('/contracts?tab=pending')}
              >
                <div className="text-xl font-bold">{signingCounts.need_activate}</div>
                <div className="text-xs">待啟用</div>
              </div>
            </div>
            {/* 流程指示 */}
            <div className="mt-2 text-xs text-gray-400 text-center">
              通知 → 確認意願 → 建立合約 → 發送簽署 → 回簽 → 啟用
            </div>
          </div>
        )
      })()}

      {/* 解約管理狀態（Decision 模式） */}
      {(terminationWorkspace?.length > 0 || terminationCases?.length > 0) && (() => {
        // 使用 workspace 數據（含 Decision），fallback 到舊數據
        const cases = terminationWorkspace?.length > 0 ? terminationWorkspace : terminationCases || []

        // 按卡點分類
        const blockedCounts = cases.reduce((acc, c) => {
          const blocked = c.decision_blocked_by || c.status
          // 搬遷相關
          if (['need_move_out', 'need_return_keys', 'need_inspect_room'].includes(blocked)) {
            acc.moving = (acc.moving || 0) + 1
          }
          // 公文相關
          else if (['need_submit_doc', 'waiting_doc_approval'].includes(blocked)) {
            acc.doc_pending = (acc.doc_pending || 0) + 1
          }
          // 公文逾期
          else if (blocked === 'doc_overdue' || c.is_doc_overdue) {
            acc.doc_overdue = (acc.doc_overdue || 0) + 1
          }
          // 結算相關
          else if (['need_calculate_settlement', 'settlement_overdue'].includes(blocked)) {
            acc.settlement = (acc.settlement || 0) + 1
          }
          // 退款相關
          else if (['need_process_refund', 'refund_overdue'].includes(blocked)) {
            acc.refund = (acc.refund || 0) + 1
          }
          // 其他（確認通知等）
          else {
            acc.other = (acc.other || 0) + 1
          }
          return acc
        }, { moving: 0, doc_pending: 0, doc_overdue: 0, settlement: 0, refund: 0, other: 0 })

        // 計算逾期數量
        const overdueCount = (blockedCounts.doc_overdue || 0) +
          cases.filter(c => c.is_settlement_overdue).length +
          cases.filter(c => c.is_refund_overdue).length

        return (
          <div className="card cursor-pointer hover:shadow-md transition-shadow" onClick={() => navigate('/terminations')}>
            <div className="card-header">
              <h3 className="card-title flex items-center gap-2">
                <FileX className="w-5 h-5 text-red-500" />
                解約流程待辦
              </h3>
              <div className="flex gap-2">
                {overdueCount > 0 && <Badge variant="danger">{overdueCount} 項逾期</Badge>}
                <Badge variant="secondary">{cases.length} 件</Badge>
              </div>
            </div>
            <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
              {/* 搬遷中 */}
              <div
                className="bg-orange-100 text-orange-700 rounded-lg p-3 text-center cursor-pointer hover:bg-orange-200 transition-colors"
                onClick={(e) => { e.stopPropagation(); navigate('/terminations') }}
              >
                <div className="text-2xl font-bold">{blockedCounts.moving + blockedCounts.other}</div>
                <div className="text-xs">搬遷中</div>
              </div>
              {/* 等待公文 */}
              <div
                className="bg-blue-100 text-blue-700 rounded-lg p-3 text-center cursor-pointer hover:bg-blue-200 transition-colors relative"
                onClick={(e) => { e.stopPropagation(); navigate('/terminations') }}
              >
                <Clock className="w-4 h-4 absolute top-2 right-2 opacity-50" />
                <div className="text-2xl font-bold">{blockedCounts.doc_pending}</div>
                <div className="text-xs">等待公文</div>
              </div>
              {/* 公文逾期 */}
              <div
                className={`rounded-lg p-3 text-center cursor-pointer transition-colors relative ${
                  blockedCounts.doc_overdue > 0
                    ? 'bg-red-100 text-red-700 hover:bg-red-200'
                    : 'bg-gray-100 text-gray-400'
                }`}
                onClick={(e) => { e.stopPropagation(); navigate('/terminations') }}
              >
                {blockedCounts.doc_overdue > 0 && (
                  <AlertTriangle className="w-4 h-4 absolute top-2 right-2 opacity-50" />
                )}
                <div className="text-2xl font-bold">{blockedCounts.doc_overdue}</div>
                <div className="text-xs">公文逾期</div>
              </div>
              {/* 押金結算 */}
              <div
                className="bg-purple-100 text-purple-700 rounded-lg p-3 text-center cursor-pointer hover:bg-purple-200 transition-colors"
                onClick={(e) => { e.stopPropagation(); navigate('/terminations') }}
              >
                <div className="text-2xl font-bold">{blockedCounts.settlement}</div>
                <div className="text-xs">待結算</div>
              </div>
              {/* 待退款 */}
              <div
                className="bg-green-100 text-green-700 rounded-lg p-3 text-center cursor-pointer hover:bg-green-200 transition-colors"
                onClick={(e) => { e.stopPropagation(); navigate('/terminations') }}
              >
                <div className="text-2xl font-bold">{blockedCounts.refund}</div>
                <div className="text-xs">待退款</div>
              </div>
            </div>
          </div>
        )
      })()}

      {/* 圖表區與新增區塊 */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* 收款狀態圓餅圖 */}
        <div className="card">
          <div className="card-header">
            <h3 className="card-title">本月收款狀態</h3>
          </div>
          <div className="h-72">
            {revenueLoading ? (
              <div className="h-full flex items-center justify-center">
                <div className="animate-spin w-8 h-8 border-2 border-primary-500 border-t-transparent rounded-full" />
              </div>
            ) : (
              <ResponsiveContainer width="100%" height="100%">
                <PieChart>
                  <Pie
                    data={pieData}
                    cx="50%"
                    cy="50%"
                    innerRadius={60}
                    outerRadius={90}
                    dataKey="value"
                    label={({ name, percent }) => `${name} ${(percent * 100).toFixed(0)}%`}
                    labelLine={false}
                  >
                    {pieData.map((entry, index) => (
                      <Cell key={`cell-${index}`} fill={COLORS[index % COLORS.length]} />
                    ))}
                  </Pie>
                  <Tooltip formatter={(value) => `$${value.toLocaleString()}`} />
                </PieChart>
              </ResponsiveContainer>
            )}
          </div>
        </div>

        {/* 當月應催繳 */}
        <div className="card lg:col-span-2">
          <div className="card-header">
            <h3 className="card-title flex items-center gap-2">
              <CreditCard className="w-5 h-5 text-orange-500" />
              當月應催繳
            </h3>
            <button
              onClick={() => navigate('/payments')}
              className="text-sm text-primary-600 hover:text-primary-700 flex items-center gap-1"
            >
              查看全部 <ArrowRight className="w-4 h-4" />
            </button>
          </div>
          <div className="space-y-2 max-h-72 overflow-y-auto">
            {currentMonthDue?.length === 0 ? (
              <div className="py-8 text-center text-gray-500">
                ✅ 當月無待催繳款項
              </div>
            ) : (
              currentMonthDue?.slice(0, 8).map((item, index) => {
                const key = `${item.customer_id}-${item.payment_period}`
                const isSending = sendingReminder[key]
                const result = reminderResult[key]
                const isOverdue = item.payment_status === 'overdue'

                return (
                  <div
                    key={item.id || `due-${index}`}
                    className={`flex items-center justify-between p-3 rounded-lg border ${
                      isOverdue ? 'bg-red-50 border-red-100' : 'bg-amber-50 border-amber-100'
                    }`}
                  >
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-medium text-gray-900 truncate">
                        {item.company_name || item.customer_name}
                      </p>
                      <p className="text-xs text-gray-500">
                        {item.company_name ? item.customer_name + ' · ' : ''}{item.branch_name} · {item.payment_period}
                      </p>
                    </div>
                    <div className="text-right mr-3">
                      <p className={`text-sm font-semibold ${isOverdue ? 'text-red-600' : 'text-amber-600'}`}>
                        ${(item.amount || item.total_due || 0).toLocaleString()}
                      </p>
                      {isOverdue && item.days_overdue && (
                        <p className="text-xs text-red-500">
                          逾期 {item.days_overdue} 天
                        </p>
                      )}
                    </div>
                    <button
                      onClick={(e) => {
                        e.stopPropagation()
                        handleSendReminder(item)
                      }}
                      disabled={isSending}
                      className={`flex items-center gap-1 px-2 py-1 rounded text-xs font-medium transition-colors ${
                        result === 'success'
                          ? 'bg-green-100 text-green-700'
                          : result === 'error'
                          ? 'bg-red-200 text-red-700'
                          : 'bg-orange-100 text-orange-700 hover:bg-orange-200'
                      }`}
                      title="發送 LINE 催繳通知"
                    >
                      {isSending ? (
                        <Loader2 className="w-3 h-3 animate-spin" />
                      ) : result === 'success' ? (
                        <CheckCircle className="w-3 h-3" />
                      ) : (
                        <Send className="w-3 h-3" />
                      )}
                      {isSending ? '發送中' : result === 'success' ? '已發送' : result === 'error' ? '失敗' : '催繳'}
                    </button>
                  </div>
                )
              })
            )}
          </div>
        </div>
      </div>

      {/* 續約通知與通知記錄 */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* 續約通知 */}
        <div className="card">
          <div className="card-header">
            <h3 className="card-title flex items-center gap-2">
              <Bell className="w-5 h-5 text-orange-500" />
              續約通知（45天內到期）
            </h3>
            <button
              onClick={() => navigate('/renewals')}
              className="text-sm text-primary-600 hover:text-primary-700 flex items-center gap-1"
            >
              查看全部 <ArrowRight className="w-4 h-4" />
            </button>
          </div>
          <div className="space-y-2 max-h-80 overflow-y-auto">
            {upcomingRenewals.length === 0 ? (
              <div className="py-8 text-center text-gray-500">
                ✅ 無即將到期的合約
              </div>
            ) : (
              upcomingRenewals.slice(0, 8).map((renewal, index) => {
                const isUrgent = renewal.days_until_expiry <= 7
                const status = getDisplayStatus(renewal)

                return (
                  <div
                    key={renewal.contract_id || `renewal-${index}`}
                    className={`flex items-center justify-between p-3 rounded-lg border ${
                      isUrgent ? 'bg-red-50 border-red-100' : 'bg-amber-50 border-amber-100'
                    }`}
                  >
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-medium text-gray-900 truncate">
                        {renewal.company_name || renewal.customer_name}
                      </p>
                      <p className="text-xs text-gray-500">
                        {renewal.company_name ? renewal.customer_name + ' · ' : ''}{renewal.branch_name}
                      </p>
                    </div>
                    <div className="text-right">
                      <Badge variant={isUrgent ? 'danger' : 'warning'}>
                        {renewal.days_until_expiry <= 0
                          ? '已到期'
                          : `${renewal.days_until_expiry} 天後到期`}
                      </Badge>
                      <p className="text-xs text-gray-500 mt-1">
                        進度 {status.progress}/7
                      </p>
                    </div>
                  </div>
                )
              })
            )}
          </div>
        </div>

        {/* 逾期款項提醒 */}
        <div className="card">
          <div className="card-header">
            <h3 className="card-title flex items-center gap-2">
              <AlertTriangle className="w-5 h-5 text-red-500" />
              逾期款項
            </h3>
            <button
              onClick={() => navigate('/payments')}
              className="text-sm text-primary-600 hover:text-primary-700 flex items-center gap-1"
            >
              查看全部 <ArrowRight className="w-4 h-4" />
            </button>
          </div>
          <div className="space-y-3 max-h-80 overflow-y-auto">
            {overdueLoading ? (
              <div className="py-8 text-center text-gray-500">載入中...</div>
            ) : overdue?.length === 0 ? (
              <div className="py-8 text-center text-gray-500">
                ✅ 沒有逾期款項
              </div>
            ) : (
              overdue?.slice(0, 6).map((item, index) => {
                const key = `${item.customer_id}-${item.payment_period}`
                const isSending = sendingReminder[key]
                const result = reminderResult[key]

                return (
                  <div
                    key={item.id || `overdue-${index}`}
                    className="flex items-center justify-between p-3 bg-red-50 rounded-lg border border-red-100"
                  >
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-medium text-gray-900 truncate">
                        {item.company_name || item.customer_name}
                      </p>
                      <p className="text-xs text-gray-500">
                        {item.company_name ? item.customer_name + ' · ' : ''}{item.branch_name} · {item.payment_period}
                      </p>
                    </div>
                    <div className="text-right mr-3">
                      <p className="text-sm font-semibold text-red-600">
                        ${(item.total_due || 0).toLocaleString()}
                      </p>
                      <p className="text-xs text-red-500">
                        逾期 {item.days_overdue} 天
                      </p>
                    </div>
                    <button
                      onClick={(e) => {
                        e.stopPropagation()
                        handleSendReminder(item)
                      }}
                      disabled={isSending}
                      className={`flex items-center gap-1 px-2 py-1 rounded text-xs font-medium transition-colors ${
                        result === 'success'
                          ? 'bg-green-100 text-green-700'
                          : result === 'error'
                          ? 'bg-red-200 text-red-700'
                          : 'bg-orange-100 text-orange-700 hover:bg-orange-200'
                      }`}
                      title="發送 LINE 催繳通知"
                    >
                      {isSending ? (
                        <Loader2 className="w-3 h-3 animate-spin" />
                      ) : result === 'success' ? (
                        <CheckCircle className="w-3 h-3" />
                      ) : (
                        <Send className="w-3 h-3" />
                      )}
                      {isSending ? '發送中' : result === 'success' ? '已發送' : result === 'error' ? '失敗' : '催繳'}
                    </button>
                  </div>
                )
              })
            )}
          </div>
        </div>
      </div>

      {/* 下方區塊 */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* 今日待辦 */}
        <div className="card">
          <div className="card-header">
            <h3 className="card-title flex items-center gap-2">
              <Calendar className="w-5 h-5 text-primary-500" />
              今日待辦
            </h3>
            <Badge variant="info">{todayTasks?.length || 0} 項</Badge>
          </div>
          <div className="space-y-3 max-h-80 overflow-y-auto">
            {tasksLoading ? (
              <div className="py-8 text-center text-gray-500">載入中...</div>
            ) : todayTasks?.length === 0 ? (
              <div className="py-8 text-center text-gray-500">
                🎉 今日沒有待辦事項
              </div>
            ) : (
              todayTasks?.slice(0, 8).map((task, index) => (
                <div
                  key={`task-${index}`}
                  className="flex items-center justify-between p-3 bg-gray-50 rounded-lg hover:bg-gray-100 transition-colors cursor-pointer"
                  onClick={() => {
                    if (task.task_type === 'payment_due') navigate('/payments')
                    else if (task.task_type === 'contract_expiring') navigate('/renewals')
                    else if (task.task_type === 'commission_due') navigate('/commissions')
                  }}
                >
                  <div className="flex items-center gap-3">
                    <span className="text-lg">
                      {priorityIcon[task.priority] || priorityIcon[task.task_type] || '📌'}
                    </span>
                    <div>
                      <p className="text-sm font-medium text-gray-900">
                        {task.task_description}
                      </p>
                      <p className="text-xs text-gray-500">
                        {task.company_name && `${task.company_name} · `}{task.branch_name}
                      </p>
                    </div>
                  </div>
                  {task.amount && (
                    <div className="text-right">
                      <span className="text-sm font-semibold text-gray-700">
                        ${task.amount.toLocaleString()}
                      </span>
                      {task.amountLabel && (
                        <p className="text-xs text-gray-400">{task.amountLabel}</p>
                      )}
                    </div>
                  )}
                </div>
              ))
            )}
          </div>
        </div>

        {/* 通知記錄 */}
        <div className="card">
          <div className="card-header">
            <h3 className="card-title flex items-center gap-2">
              <History className="w-5 h-5 text-blue-500" />
              通知記錄
            </h3>
          </div>
          <div className="space-y-2 max-h-80 overflow-y-auto">
            {notificationHistory.length === 0 ? (
              <div className="py-8 text-center text-gray-500">
                無通知記錄
              </div>
            ) : (
              notificationHistory.map((record) => (
                <div
                  key={record.id}
                  className="flex items-start gap-3 p-3 bg-gray-50 rounded-lg"
                >
                  <div className="flex-shrink-0">
                    {record.status === 'success' ? (
                      <CheckCircle className="w-5 h-5 text-green-500" />
                    ) : record.status === 'error' ? (
                      <AlertTriangle className="w-5 h-5 text-red-500" />
                    ) : (
                      <MessageCircle className="w-5 h-5 text-blue-500" />
                    )}
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium text-gray-900">
                      {record.customer}
                    </p>
                    <p className="text-xs text-gray-600">
                      {record.message}
                    </p>
                    <p className="text-xs text-gray-400 mt-1">
                      {record.timestamp}
                    </p>
                  </div>
                  <Badge variant={record.status === 'success' ? 'success' : 'danger'}>
                    {record.type === 'payment_reminder' ? '催繳' : '續約'}
                  </Badge>
                </div>
              ))
            )}
          </div>
        </div>
      </div>

      {/* 分館詳情 */}
      <div className="card">
        <div className="card-header">
          <h3 className="card-title flex items-center gap-2">
            <Building2 className="w-5 h-5 text-jungle-500" />
            分館營運概況
          </h3>
        </div>
        <div className="overflow-x-auto">
          <table className="data-table">
            <thead>
              <tr>
                <th>分館</th>
                <th>活躍客戶</th>
                <th>有效合約</th>
                <th>本月營收</th>
                <th>待收款</th>
                <th>逾期</th>
                <th>即將到期</th>
              </tr>
            </thead>
            <tbody>
              {revenueLoading ? (
                <tr>
                  <td colSpan={7} className="text-center py-8 text-gray-500">
                    載入中...
                  </td>
                </tr>
              ) : (
                branchRevenueArr.map((branch) => (
                  <tr key={branch.branch_id || branch.branch_name}>
                    <td className="font-medium">{branch.branch_name}</td>
                    <td>{branch.active_customers || 0}</td>
                    <td>{branch.active_contracts || 0}</td>
                    <td className="text-green-600 font-medium">
                      ${(branch.current_month_revenue || 0).toLocaleString()}
                    </td>
                    <td className="text-blue-600">
                      ${(branch.current_month_pending || 0).toLocaleString()}
                    </td>
                    <td className="text-red-600">
                      ${(branch.current_month_overdue || 0).toLocaleString()}
                    </td>
                    <td>
                      {branch.contracts_expiring_30days > 0 ? (
                        <Badge variant="warning">
                          {branch.contracts_expiring_30days} 份
                        </Badge>
                      ) : (
                        <span className="text-gray-400">-</span>
                      )}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
