import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { db, callTool } from '../services/api'
import useStore from '../store/useStore'
import DataTable from '../components/DataTable'
import Modal from '../components/Modal'
import {
  FileX, Clock, FileCheck, DollarSign, CheckCircle,
  AlertCircle, ChevronRight, Building2, User, Phone,
  Calendar, Loader2, XCircle, Ban, AlertTriangle, Send,
  CreditCard, FileWarning
} from 'lucide-react'

// 狀態配置
const STATUS_CONFIG = {
  notice_received: { label: '已收到通知', color: 'yellow', icon: Clock },
  moving_out: { label: '搬遷中', color: 'orange', icon: FileX },
  pending_doc: { label: '等待公文', color: 'blue', icon: FileCheck },
  pending_settlement: { label: '押金結算中', color: 'purple', icon: DollarSign },
  pending_authority: { label: '通報主管機關', color: 'red', icon: FileWarning },
  completed: { label: '已完成', color: 'green', icon: CheckCircle },
  cancelled: { label: '已取消', color: 'gray', icon: Ban }
}

// 解約類型配置
const TYPE_CONFIG = {
  early: { label: '提前解約', color: 'red' },
  not_renewing: { label: '到期不續約', color: 'blue' },
  breach: { label: '違約終止', color: 'orange' }
}

// Checklist 項目（基本項目 - 所有合約都有）
const BASE_CHECKLIST_ITEMS = [
  { key: 'notice_confirmed', label: '解約通知已確認' },
  { key: 'doc_submitted', label: '公文已送件' },
  { key: 'doc_approved', label: '公文已核准' },
  { key: 'settlement_calculated', label: '押金已結算' },
  { key: 'refund_processed', label: '押金已退還' }
]

// 實體辦公室專用項目
const PHYSICAL_OFFICE_ITEMS = [
  { key: 'belongings_removed', label: '物品已搬離' },
  { key: 'keys_returned', label: '鑰匙已歸還' },
  { key: 'room_inspected', label: '房間已檢查' }
]

// 取得 checklist 項目（根據合約類型）
const getChecklistItems = (isPhysicalOffice) => {
  if (isPhysicalOffice) {
    // 實體辦公室：notice_confirmed → 物品/鑰匙/檢查 → 公文 → 結算 → 退還
    return [
      BASE_CHECKLIST_ITEMS[0], // notice_confirmed
      ...PHYSICAL_OFFICE_ITEMS,
      ...BASE_CHECKLIST_ITEMS.slice(1)
    ]
  }
  // 虛擬辦公室/純登記：只有基本項目
  return BASE_CHECKLIST_ITEMS
}

export default function Terminations() {
  const { addNotification } = useStore()
  const queryClient = useQueryClient()

  // 狀態
  const [statusFilter, setStatusFilter] = useState('')
  const [showDetailModal, setShowDetailModal] = useState(false)
  const [selectedCase, setSelectedCase] = useState(null)
  const [showSettlementModal, setShowSettlementModal] = useState(false)
  const [showRefundModal, setShowRefundModal] = useState(false)
  const [showCancelModal, setShowCancelModal] = useState(false)

  // 結算表單
  const [settlementForm, setSettlementForm] = useState({
    doc_approved_date: new Date().toISOString().split('T')[0],
    other_deductions: 0,
    other_deduction_notes: ''
  })

  // 退款表單
  const [refundForm, setRefundForm] = useState({
    refund_method: 'transfer',
    refund_account: '',
    refund_receipt: '',
    notes: ''
  })

  // 取消原因
  const [cancelReason, setCancelReason] = useState('')

  // 新增解約案件
  const [showCreateModal, setShowCreateModal] = useState(false)
  const [createForm, setCreateForm] = useState({
    contract_id: '',
    termination_type: 'not_renewing',
    notice_date: new Date().toISOString().split('T')[0],
    notes: ''
  })
  const [contractSearch, setContractSearch] = useState('')
  const [contractOptions, setContractOptions] = useState([])

  // 取得解約案件列表
  const { data: cases = [], isLoading, error } = useQuery({
    queryKey: ['termination_cases', statusFilter],
    queryFn: async () => {
      const params = { order: 'created_at.desc' }
      if (statusFilter) {
        params.status = `eq.${statusFilter}`
      } else {
        params.status = 'not.in.(completed,cancelled)'
      }
      const result = await db.query('v_termination_cases', params)
      return result || []
    }
  })

  // 更新 Checklist
  const updateChecklist = useMutation({
    mutationFn: async ({ caseId, item, value }) => {
      return await callTool('termination_update_checklist', {
        case_id: caseId,
        item,
        value
      })
    },
    onSuccess: (result) => {
      if (result.success) {
        queryClient.invalidateQueries(['termination_cases'])
        addNotification({ type: 'success', message: '已更新' })
        // 更新 selectedCase
        if (selectedCase) {
          setSelectedCase(prev => ({
            ...prev,
            checklist: result.checklist,
            progress: result.progress
          }))
        }
      } else {
        addNotification({ type: 'error', message: result.error || '更新失敗' })
      }
    }
  })

  // 更新狀態
  const updateStatus = useMutation({
    mutationFn: async ({ caseId, status, notes }) => {
      return await callTool('termination_update_status', {
        case_id: caseId,
        status,
        notes
      })
    },
    onSuccess: (result) => {
      if (result.success) {
        queryClient.invalidateQueries(['termination_cases'])
        addNotification({ type: 'success', message: '狀態已更新' })
      } else {
        addNotification({ type: 'error', message: result.error || '更新失敗' })
      }
    }
  })

  // 計算押金結算
  const calculateSettlement = useMutation({
    mutationFn: async (data) => {
      return await callTool('termination_calculate_settlement', data)
    },
    onSuccess: (result) => {
      if (result.success) {
        queryClient.invalidateQueries(['termination_cases'])
        addNotification({ type: 'success', message: result.message })
        setShowSettlementModal(false)
        // 重新載入案件詳情
        if (selectedCase) {
          loadCaseDetail(selectedCase.id)
        }
      } else {
        addNotification({ type: 'error', message: result.error || '結算失敗' })
      }
    }
  })

  // 處理退款
  const processRefund = useMutation({
    mutationFn: async (data) => {
      return await callTool('termination_process_refund', data)
    },
    onSuccess: (result) => {
      if (result.success) {
        queryClient.invalidateQueries(['termination_cases'])
        addNotification({ type: 'success', message: result.message })
        setShowRefundModal(false)
        setShowDetailModal(false)
      } else {
        addNotification({ type: 'error', message: result.error || '退款處理失敗' })
      }
    }
  })

  // 取消解約
  const cancelCase = useMutation({
    mutationFn: async ({ caseId, reason }) => {
      return await callTool('termination_cancel_case', {
        case_id: caseId,
        reason
      })
    },
    onSuccess: (result) => {
      if (result.success) {
        queryClient.invalidateQueries(['termination_cases'])
        addNotification({ type: 'success', message: result.message })
        setShowCancelModal(false)
        setShowDetailModal(false)
      } else {
        addNotification({ type: 'error', message: result.error || '取消失敗' })
      }
    }
  })

  // 建立解約案件
  const createCase = useMutation({
    mutationFn: async (data) => {
      return await callTool('termination_create_case', data)
    },
    onSuccess: (result) => {
      if (result.success) {
        queryClient.invalidateQueries(['termination_cases'])
        addNotification({ type: 'success', message: result.message })
        setShowCreateModal(false)
        setCreateForm({
          contract_id: '',
          termination_type: 'not_renewing',
          notice_date: new Date().toISOString().split('T')[0],
          notes: ''
        })
        setContractSearch('')
        setContractOptions([])
      } else {
        addNotification({ type: 'error', message: result.error || '建立失敗' })
      }
    }
  })

  // 搜尋合約
  const searchContracts = async (keyword) => {
    if (!keyword || keyword.length < 2) {
      setContractOptions([])
      return
    }
    try {
      // 搜尋生效中的合約
      const result = await db.query('contracts', {
        or: `(contract_number.ilike.*${keyword}*,customer_id.in.(select id from customers where name ilike '%${keyword}%' or company_name ilike '%${keyword}%'))`,
        status: 'eq.active',
        select: 'id,contract_number,customer_id,monthly_rent,end_date,customers(name,company_name)',
        limit: 10
      })
      setContractOptions(result || [])
    } catch (e) {
      console.error('搜尋合約失敗:', e)
    }
  }

  // 載入案件詳情
  const loadCaseDetail = async (caseId) => {
    const result = await callTool('termination_get_case', { case_id: caseId })
    if (result.success) {
      setSelectedCase(result.case)
    }
  }

  // 開啟詳情
  const openDetail = (caseData) => {
    setSelectedCase(caseData)
    setShowDetailModal(true)
  }

  // 表格欄位（使用 DataTable 組件期望的格式：accessor/header/cell）
  const columns = [
    {
      accessor: 'id',
      header: '#',
      cell: (row) => (
        <span className="text-gray-500">#{row.id}</span>
      )
    },
    {
      accessor: 'contract_number',
      header: '合約編號',
      cell: (row) => (
        <span className="font-medium text-blue-600">{row.contract_number}</span>
      )
    },
    {
      accessor: 'customer_name',
      header: '客戶',
      cell: (row) => (
        <div>
          <div className="font-medium">{row.customer_name}</div>
          {row.company_name && (
            <div className="text-xs text-gray-500">{row.company_name}</div>
          )}
        </div>
      )
    },
    {
      accessor: 'termination_type',
      header: '類型',
      cell: (row) => {
        const config = TYPE_CONFIG[row.termination_type] || { label: row.termination_type, color: 'gray' }
        return (
          <span className={`px-2 py-1 rounded-full text-xs bg-${config.color}-100 text-${config.color}-700`}>
            {config.label}
          </span>
        )
      }
    },
    {
      accessor: 'status',
      header: '狀態',
      cell: (row) => {
        const config = STATUS_CONFIG[row.status] || { label: row.status, color: 'gray', icon: AlertCircle }
        const Icon = config.icon
        return (
          <span className={`inline-flex items-center gap-1 px-2 py-1 rounded-full text-xs bg-${config.color}-100 text-${config.color}-700`}>
            <Icon className="w-3 h-3" />
            {config.label}
          </span>
        )
      }
    },
    {
      accessor: 'progress',
      header: '進度',
      cell: (row) => {
        const totalSteps = row.total_steps || 8
        return (
          <div className="flex items-center gap-2">
            <div className="w-24 h-2 bg-gray-200 rounded-full overflow-hidden">
              <div
                className="h-full bg-blue-500 transition-all"
                style={{ width: `${(row.progress / totalSteps) * 100}%` }}
              />
            </div>
            <span className="text-xs text-gray-500">{row.progress}/{totalSteps}</span>
          </div>
        )
      }
    },
    {
      accessor: 'contract_end_date',
      header: '合約到期日',
      cell: (row) => row.contract_end_date ? new Date(row.contract_end_date).toLocaleDateString('zh-TW') : '-'
    },
    {
      accessor: 'created_at',
      header: '建立時間',
      cell: (row) => new Date(row.created_at).toLocaleDateString('zh-TW')
    },
    {
      header: '操作',
      sortable: false,
      cell: (row) => (
        <button
          onClick={() => openDetail(row)}
          className="text-blue-600 hover:text-blue-800 flex items-center gap-1"
        >
          查看 <ChevronRight className="w-4 h-4" />
        </button>
      )
    }
  ]

  // 統計卡片
  const stats = {
    notice_received: cases.filter(c => c.status === 'notice_received').length,
    moving_out: cases.filter(c => c.status === 'moving_out').length,
    pending_doc: cases.filter(c => c.status === 'pending_doc').length,
    pending_settlement: cases.filter(c => c.status === 'pending_settlement').length,
    pending_authority: cases.filter(c => c.status === 'pending_authority').length
  }

  if (error) {
    return (
      <div className="p-6">
        <div className="bg-red-50 text-red-600 p-4 rounded-lg">
          載入失敗: {error.message}
        </div>
      </div>
    )
  }

  return (
    <div className="p-6">
      {/* 標題 */}
      <div className="flex justify-between items-center mb-6">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">解約管理</h1>
          <p className="text-gray-500 mt-1">追蹤解約流程：通知 → 搬遷 → 公文 → 押金結算</p>
        </div>
        <button
          onClick={() => setShowCreateModal(true)}
          className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 flex items-center gap-2"
        >
          <FileX className="w-4 h-4" />
          建立解約案件
        </button>
      </div>

      {/* 統計卡片 */}
      <div className="grid grid-cols-5 gap-4 mb-6">
        {Object.entries(STATUS_CONFIG).slice(0, 5).map(([key, config]) => {
          const Icon = config.icon
          const count = stats[key] || 0
          return (
            <button
              key={key}
              onClick={() => setStatusFilter(statusFilter === key ? '' : key)}
              className={`p-4 rounded-lg border-2 transition-all ${
                statusFilter === key
                  ? `border-${config.color}-500 bg-${config.color}-50`
                  : 'border-gray-200 bg-white hover:border-gray-300'
              }`}
            >
              <div className="flex items-center gap-3">
                <div className={`p-2 rounded-full bg-${config.color}-100`}>
                  <Icon className={`w-5 h-5 text-${config.color}-600`} />
                </div>
                <div className="text-left">
                  <div className="text-2xl font-bold">{count}</div>
                  <div className="text-sm text-gray-500">{config.label}</div>
                </div>
              </div>
            </button>
          )
        })}
      </div>

      {/* 篩選器 */}
      <div className="flex gap-4 mb-4">
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
          className="px-3 py-2 border rounded-lg"
        >
          <option value="">進行中的案件</option>
          {Object.entries(STATUS_CONFIG).map(([key, config]) => (
            <option key={key} value={key}>{config.label}</option>
          ))}
        </select>
      </div>

      {/* 表格 */}
      <DataTable
        data={cases}
        columns={columns}
        loading={isLoading}
        emptyMessage="目前沒有解約案件"
      />

      {/* 詳情 Modal */}
      <Modal
        isOpen={showDetailModal}
        onClose={() => setShowDetailModal(false)}
        title={`解約案件 #${selectedCase?.id}`}
        size="xl"
      >
        {selectedCase && (
          <div className="space-y-6">
            {/* 基本資訊 */}
            <div className="grid grid-cols-2 gap-4">
              <div className="bg-gray-50 p-4 rounded-lg">
                <h3 className="font-medium text-gray-700 mb-3 flex items-center gap-2">
                  <Building2 className="w-4 h-4" />
                  合約資訊
                </h3>
                <div className="space-y-2 text-sm">
                  <div className="flex justify-between">
                    <span className="text-gray-500">合約編號</span>
                    <span className="font-medium">{selectedCase.contract_number}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-500">月租金</span>
                    <span className="font-medium">${selectedCase.monthly_rent?.toLocaleString()}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-500">合約到期日</span>
                    <span className="font-medium">{selectedCase.contract_end_date}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-500">押金</span>
                    <span className="font-medium">${(selectedCase.deposit_amount || selectedCase.contract_deposit)?.toLocaleString()}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-gray-500">合約類型</span>
                    <span className="font-medium">
                      {selectedCase.is_physical_office ? '實體辦公室' : '虛擬辦公室/登記'}
                    </span>
                  </div>
                </div>
              </div>

              <div className="bg-gray-50 p-4 rounded-lg">
                <h3 className="font-medium text-gray-700 mb-3 flex items-center gap-2">
                  <User className="w-4 h-4" />
                  客戶資訊
                </h3>
                <div className="space-y-2 text-sm">
                  <div className="flex justify-between">
                    <span className="text-gray-500">客戶名稱</span>
                    <span className="font-medium">{selectedCase.customer_name}</span>
                  </div>
                  {selectedCase.company_name && (
                    <div className="flex justify-between">
                      <span className="text-gray-500">公司名稱</span>
                      <span className="font-medium">{selectedCase.company_name}</span>
                    </div>
                  )}
                  {selectedCase.customer_phone && (
                    <div className="flex justify-between">
                      <span className="text-gray-500">電話</span>
                      <span className="font-medium">{selectedCase.customer_phone}</span>
                    </div>
                  )}
                </div>
              </div>
            </div>

            {/* 狀態與類型 */}
            <div className="flex gap-4">
              <div>
                <span className="text-sm text-gray-500">解約類型：</span>
                <span className={`ml-2 px-2 py-1 rounded-full text-xs bg-${TYPE_CONFIG[selectedCase.termination_type]?.color || 'gray'}-100 text-${TYPE_CONFIG[selectedCase.termination_type]?.color || 'gray'}-700`}>
                  {TYPE_CONFIG[selectedCase.termination_type]?.label || selectedCase.termination_type}
                </span>
              </div>
              <div>
                <span className="text-sm text-gray-500">目前狀態：</span>
                <span className={`ml-2 px-2 py-1 rounded-full text-xs bg-${STATUS_CONFIG[selectedCase.status]?.color || 'gray'}-100 text-${STATUS_CONFIG[selectedCase.status]?.color || 'gray'}-700`}>
                  {STATUS_CONFIG[selectedCase.status]?.label || selectedCase.status}
                </span>
              </div>
            </div>

            {/* 待收款項（從應收帳款轉移至此） */}
            {selectedCase.pending_payment_count > 0 && (
              <div className="bg-amber-50 border border-amber-200 p-4 rounded-lg">
                <h3 className="font-medium text-amber-700 mb-3 flex items-center gap-2">
                  <CreditCard className="w-4 h-4" />
                  待收款項（已從應收帳款移除）
                </h3>
                <div className="flex items-center justify-between">
                  <div>
                    <div className="text-sm text-amber-600">共 {selectedCase.pending_payment_count} 筆未付款</div>
                    <div className="text-xs text-amber-500 mt-1">這些款項將於押金結算時一併處理</div>
                  </div>
                  <div className="text-2xl font-bold text-amber-700">
                    ${selectedCase.pending_payment_amount?.toLocaleString()}
                  </div>
                </div>
              </div>
            )}

            {/* 呆帳警告 */}
            {selectedCase.is_bad_debt && (
              <div className="bg-red-50 border border-red-200 p-4 rounded-lg">
                <h3 className="font-medium text-red-700 mb-3 flex items-center gap-2">
                  <AlertTriangle className="w-4 h-4" />
                  呆帳案件
                </h3>
                <div className="grid grid-cols-2 gap-4 text-sm">
                  <div>
                    <div className="text-red-600">欠款金額</div>
                    <div className="font-medium text-red-700">${selectedCase.arrears_amount?.toLocaleString()}</div>
                  </div>
                  <div>
                    <div className="text-red-600">呆帳金額</div>
                    <div className="font-bold text-red-700 text-lg">${selectedCase.bad_debt_amount?.toLocaleString()}</div>
                  </div>
                  {selectedCase.authority_reported_date && (
                    <div>
                      <div className="text-red-600">通報日期</div>
                      <div className="font-medium">{selectedCase.authority_reported_date}</div>
                    </div>
                  )}
                  {selectedCase.authority_response_date && (
                    <div>
                      <div className="text-red-600">收到函文日期</div>
                      <div className="font-medium">{selectedCase.authority_response_date}</div>
                    </div>
                  )}
                </div>
                <div className="mt-2 text-xs text-red-500">
                  計算公式：欠款 + 扣除費用 - 押金 = 呆帳金額
                </div>
              </div>
            )}

            {/* Checklist */}
            <div className="bg-gray-50 p-4 rounded-lg">
              <h3 className="font-medium text-gray-700 mb-3 flex items-center justify-between">
                <span>解約流程 Checklist</span>
                <span className="text-xs text-gray-500">
                  {selectedCase.is_physical_office ? '實體辦公室 (8 步驟)' : '虛擬辦公室 (5 步驟)'}
                </span>
              </h3>
              <div className="grid grid-cols-2 gap-3">
                {getChecklistItems(selectedCase.is_physical_office !== false).map((item) => {
                  const checked = selectedCase.checklist?.[item.key] || false
                  return (
                    <label
                      key={item.key}
                      className={`flex items-center gap-2 p-2 rounded cursor-pointer transition-colors ${
                        checked ? 'bg-green-100' : 'bg-white hover:bg-gray-100'
                      }`}
                    >
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={() => updateChecklist.mutate({
                          caseId: selectedCase.id,
                          item: item.key,
                          value: !checked
                        })}
                        className="w-4 h-4 text-green-600 rounded"
                        disabled={selectedCase.status === 'completed' || selectedCase.status === 'cancelled'}
                      />
                      <span className={checked ? 'text-green-700' : 'text-gray-700'}>
                        {item.label}
                      </span>
                    </label>
                  )
                })}
              </div>
            </div>

            {/* 押金結算資訊 */}
            {(selectedCase.deduction_amount !== null || selectedCase.refund_amount !== null) && (
              <div className="bg-blue-50 p-4 rounded-lg">
                <h3 className="font-medium text-blue-700 mb-3 flex items-center gap-2">
                  <DollarSign className="w-4 h-4" />
                  押金結算
                </h3>
                <div className="grid grid-cols-2 gap-4 text-sm">
                  <div>
                    <div className="text-gray-600">公文核准日期</div>
                    <div className="font-medium">{selectedCase.doc_approved_date || '-'}</div>
                  </div>
                  <div>
                    <div className="text-gray-600">扣除天數</div>
                    <div className="font-medium">{selectedCase.deduction_days || 0} 天</div>
                  </div>
                  <div>
                    <div className="text-gray-600">日租金</div>
                    <div className="font-medium">${selectedCase.daily_rate?.toLocaleString() || '-'}</div>
                  </div>
                  <div>
                    <div className="text-gray-600">扣除金額</div>
                    <div className="font-medium text-red-600">${selectedCase.deduction_amount?.toLocaleString() || 0}</div>
                  </div>
                  {selectedCase.other_deductions > 0 && (
                    <>
                      <div>
                        <div className="text-gray-600">其他扣款</div>
                        <div className="font-medium text-red-600">${selectedCase.other_deductions?.toLocaleString()}</div>
                      </div>
                      <div>
                        <div className="text-gray-600">扣款說明</div>
                        <div className="font-medium">{selectedCase.other_deduction_notes || '-'}</div>
                      </div>
                    </>
                  )}
                  <div className="col-span-2 pt-2 border-t">
                    <div className="flex justify-between items-center">
                      <span className="text-gray-600">應退還押金</span>
                      <span className="text-xl font-bold text-green-600">
                        ${selectedCase.refund_amount?.toLocaleString() || '-'}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            )}

            {/* 操作按鈕 */}
            {selectedCase.status !== 'completed' && selectedCase.status !== 'cancelled' && (
              <div className="flex justify-between border-t pt-4">
                <button
                  onClick={() => {
                    setCancelReason('')
                    setShowCancelModal(true)
                  }}
                  className="px-4 py-2 text-red-600 hover:bg-red-50 rounded-lg flex items-center gap-2"
                >
                  <XCircle className="w-4 h-4" />
                  取消解約（客戶反悔）
                </button>

                <div className="flex gap-2">
                  {selectedCase.status === 'pending_doc' && !selectedCase.settlement_date && (
                    <button
                      onClick={() => {
                        setSettlementForm({
                          doc_approved_date: new Date().toISOString().split('T')[0],
                          other_deductions: 0,
                          other_deduction_notes: ''
                        })
                        setShowSettlementModal(true)
                      }}
                      className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center gap-2"
                    >
                      <DollarSign className="w-4 h-4" />
                      計算押金結算
                    </button>
                  )}

                  {selectedCase.status === 'pending_settlement' && selectedCase.refund_amount !== null && !selectedCase.is_bad_debt && (
                    <button
                      onClick={() => {
                        setRefundForm({
                          refund_method: 'transfer',
                          refund_account: '',
                          refund_receipt: '',
                          notes: ''
                        })
                        setShowRefundModal(true)
                      }}
                      className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 flex items-center gap-2"
                    >
                      <CheckCircle className="w-4 h-4" />
                      處理退款
                    </button>
                  )}

                  {/* 呆帳：通報主管機關 */}
                  {selectedCase.status === 'pending_settlement' && selectedCase.is_bad_debt && (
                    <button
                      onClick={() => updateStatus.mutate({
                        caseId: selectedCase.id,
                        status: 'pending_authority',
                        notes: `呆帳金額: $${selectedCase.bad_debt_amount}`
                      })}
                      className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 flex items-center gap-2"
                    >
                      <Send className="w-4 h-4" />
                      通報主管機關
                    </button>
                  )}

                  {/* 等待函文 → 完成 */}
                  {selectedCase.status === 'pending_authority' && (
                    <button
                      onClick={() => updateStatus.mutate({
                        caseId: selectedCase.id,
                        status: 'completed',
                        notes: '已收到國稅局函文，案件結案'
                      })}
                      className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 flex items-center gap-2"
                    >
                      <CheckCircle className="w-4 h-4" />
                      已收到函文，結案
                    </button>
                  )}

                  {/* 狀態切換按鈕 */}
                  {selectedCase.status === 'notice_received' && (
                    <button
                      onClick={() => updateStatus.mutate({ caseId: selectedCase.id, status: 'moving_out' })}
                      className="px-4 py-2 bg-orange-600 text-white rounded-lg hover:bg-orange-700"
                    >
                      進入搬遷階段
                    </button>
                  )}
                  {selectedCase.status === 'moving_out' && (
                    <button
                      onClick={() => updateStatus.mutate({ caseId: selectedCase.id, status: 'pending_doc' })}
                      className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700"
                    >
                      進入等待公文階段
                    </button>
                  )}
                </div>
              </div>
            )}
          </div>
        )}
      </Modal>

      {/* 押金結算 Modal */}
      <Modal
        isOpen={showSettlementModal}
        onClose={() => setShowSettlementModal(false)}
        title="計算押金結算"
      >
        <div className="space-y-4">
          <div className="bg-yellow-50 p-3 rounded-lg text-sm text-yellow-700">
            <strong>注意：</strong>押金扣除 = (公文核准日 - 合約到期日) × 日租金
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              公文核准日期 *
            </label>
            <input
              type="date"
              value={settlementForm.doc_approved_date}
              onChange={(e) => setSettlementForm(prev => ({ ...prev, doc_approved_date: e.target.value }))}
              className="w-full px-3 py-2 border rounded-lg"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              其他扣款金額（清潔費、損壞等）
            </label>
            <input
              type="number"
              value={settlementForm.other_deductions}
              onChange={(e) => setSettlementForm(prev => ({ ...prev, other_deductions: parseFloat(e.target.value) || 0 }))}
              className="w-full px-3 py-2 border rounded-lg"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              其他扣款說明
            </label>
            <input
              type="text"
              value={settlementForm.other_deduction_notes}
              onChange={(e) => setSettlementForm(prev => ({ ...prev, other_deduction_notes: e.target.value }))}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="例：清潔費、牆面修補"
            />
          </div>

          <div className="flex justify-end gap-2 pt-4 border-t">
            <button
              onClick={() => setShowSettlementModal(false)}
              className="px-4 py-2 text-gray-600 hover:bg-gray-100 rounded-lg"
            >
              取消
            </button>
            <button
              onClick={() => calculateSettlement.mutate({
                case_id: selectedCase.id,
                ...settlementForm
              })}
              disabled={calculateSettlement.isPending || !settlementForm.doc_approved_date}
              className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 flex items-center gap-2"
            >
              {calculateSettlement.isPending && <Loader2 className="w-4 h-4 animate-spin" />}
              計算結算金額
            </button>
          </div>
        </div>
      </Modal>

      {/* 退款處理 Modal */}
      <Modal
        isOpen={showRefundModal}
        onClose={() => setShowRefundModal(false)}
        title="處理押金退還"
      >
        <div className="space-y-4">
          <div className="bg-green-50 p-4 rounded-lg">
            <div className="text-sm text-green-700">應退還押金</div>
            <div className="text-2xl font-bold text-green-600">
              ${selectedCase?.refund_amount?.toLocaleString()}
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              退款方式 *
            </label>
            <select
              value={refundForm.refund_method}
              onChange={(e) => setRefundForm(prev => ({ ...prev, refund_method: e.target.value }))}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="transfer">匯款</option>
              <option value="cash">現金</option>
              <option value="check">支票</option>
            </select>
          </div>

          {refundForm.refund_method === 'transfer' && (
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                退款帳戶
              </label>
              <input
                type="text"
                value={refundForm.refund_account}
                onChange={(e) => setRefundForm(prev => ({ ...prev, refund_account: e.target.value }))}
                className="w-full px-3 py-2 border rounded-lg"
                placeholder="銀行代碼-帳號"
              />
            </div>
          )}

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              收據編號
            </label>
            <input
              type="text"
              value={refundForm.refund_receipt}
              onChange={(e) => setRefundForm(prev => ({ ...prev, refund_receipt: e.target.value }))}
              className="w-full px-3 py-2 border rounded-lg"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              備註
            </label>
            <textarea
              value={refundForm.notes}
              onChange={(e) => setRefundForm(prev => ({ ...prev, notes: e.target.value }))}
              className="w-full px-3 py-2 border rounded-lg"
              rows={2}
            />
          </div>

          <div className="flex justify-end gap-2 pt-4 border-t">
            <button
              onClick={() => setShowRefundModal(false)}
              className="px-4 py-2 text-gray-600 hover:bg-gray-100 rounded-lg"
            >
              取消
            </button>
            <button
              onClick={() => processRefund.mutate({
                case_id: selectedCase.id,
                ...refundForm
              })}
              disabled={processRefund.isPending}
              className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50 flex items-center gap-2"
            >
              {processRefund.isPending && <Loader2 className="w-4 h-4 animate-spin" />}
              確認退款完成
            </button>
          </div>
        </div>
      </Modal>

      {/* 取消解約 Modal */}
      <Modal
        isOpen={showCancelModal}
        onClose={() => setShowCancelModal(false)}
        title="取消解約案件"
      >
        <div className="space-y-4">
          <div className="bg-yellow-50 p-3 rounded-lg text-sm text-yellow-700">
            取消後，合約狀態將恢復為「生效中」，客戶可繼續使用服務。
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              取消原因 *
            </label>
            <textarea
              value={cancelReason}
              onChange={(e) => setCancelReason(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
              rows={3}
              placeholder="請說明取消解約的原因（例：客戶決定續租）"
            />
          </div>

          <div className="flex justify-end gap-2 pt-4 border-t">
            <button
              onClick={() => setShowCancelModal(false)}
              className="px-4 py-2 text-gray-600 hover:bg-gray-100 rounded-lg"
            >
              返回
            </button>
            <button
              onClick={() => cancelCase.mutate({
                caseId: selectedCase.id,
                reason: cancelReason
              })}
              disabled={cancelCase.isPending || !cancelReason.trim()}
              className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 disabled:opacity-50 flex items-center gap-2"
            >
              {cancelCase.isPending && <Loader2 className="w-4 h-4 animate-spin" />}
              確認取消解約
            </button>
          </div>
        </div>
      </Modal>

      {/* 建立解約案件 Modal */}
      <Modal
        isOpen={showCreateModal}
        onClose={() => {
          setShowCreateModal(false)
          setContractSearch('')
          setContractOptions([])
        }}
        title="建立解約案件"
      >
        <div className="space-y-4">
          <div className="bg-red-50 p-3 rounded-lg text-sm text-red-700">
            建立解約案件後，合約狀態將變更為「解約中」，該合約的待收款項將從應收帳款移除。
          </div>

          {/* 搜尋合約 */}
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              搜尋合約（輸入合約編號或客戶名稱）*
            </label>
            <input
              type="text"
              value={contractSearch}
              onChange={(e) => {
                setContractSearch(e.target.value)
                searchContracts(e.target.value)
              }}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="例：HR-2025-001 或 陳玉美"
            />
            {/* 合約選項 */}
            {contractOptions.length > 0 && (
              <div className="mt-2 border rounded-lg max-h-48 overflow-y-auto">
                {contractOptions.map(contract => (
                  <button
                    key={contract.id}
                    onClick={() => {
                      setCreateForm(prev => ({ ...prev, contract_id: contract.id }))
                      setContractSearch(`${contract.contract_number} - ${contract.customers?.name || ''}`)
                      setContractOptions([])
                    }}
                    className={`w-full px-3 py-2 text-left hover:bg-gray-100 border-b last:border-b-0 ${
                      createForm.contract_id === contract.id ? 'bg-blue-50' : ''
                    }`}
                  >
                    <div className="font-medium">{contract.contract_number}</div>
                    <div className="text-sm text-gray-500">
                      {contract.customers?.name}
                      {contract.customers?.company_name && ` (${contract.customers.company_name})`}
                      {' · '}到期: {contract.end_date}
                    </div>
                  </button>
                ))}
              </div>
            )}
            {createForm.contract_id && (
              <div className="mt-2 text-sm text-green-600">
                ✓ 已選擇合約 ID: {createForm.contract_id}
              </div>
            )}
          </div>

          {/* 解約類型 */}
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              解約類型 *
            </label>
            <select
              value={createForm.termination_type}
              onChange={(e) => setCreateForm(prev => ({ ...prev, termination_type: e.target.value }))}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="not_renewing">到期不續約</option>
              <option value="early">提前解約</option>
              <option value="breach">違約終止</option>
            </select>
          </div>

          {/* 通知日期 */}
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              客戶通知日期
            </label>
            <input
              type="date"
              value={createForm.notice_date}
              onChange={(e) => setCreateForm(prev => ({ ...prev, notice_date: e.target.value }))}
              className="w-full px-3 py-2 border rounded-lg"
            />
          </div>

          {/* 備註 */}
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              備註
            </label>
            <textarea
              value={createForm.notes}
              onChange={(e) => setCreateForm(prev => ({ ...prev, notes: e.target.value }))}
              className="w-full px-3 py-2 border rounded-lg"
              rows={2}
              placeholder="例：客戶口頭告知要搬遷"
            />
          </div>

          <div className="flex justify-end gap-2 pt-4 border-t">
            <button
              onClick={() => {
                setShowCreateModal(false)
                setContractSearch('')
                setContractOptions([])
              }}
              className="px-4 py-2 text-gray-600 hover:bg-gray-100 rounded-lg"
            >
              取消
            </button>
            <button
              onClick={() => createCase.mutate({
                contract_id: createForm.contract_id,
                termination_type: createForm.termination_type,
                notice_date: createForm.notice_date,
                notes: createForm.notes
              })}
              disabled={createCase.isPending || !createForm.contract_id}
              className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 disabled:opacity-50 flex items-center gap-2"
            >
              {createCase.isPending && <Loader2 className="w-4 h-4 animate-spin" />}
              建立解約案件
            </button>
          </div>
        </div>
      </Modal>
    </div>
  )
}
