import { useState, useRef, useEffect, useMemo } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useContractDetail, useBillingRecordPayment, useSendPaymentReminder, useUpdateCustomer } from '../hooks/useApi'
import api, { crm } from '../services/api'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { pdf } from '@react-pdf/renderer'
import Modal from '../components/Modal'
import Badge, { StatusBadge } from '../components/Badge'
import ContractPDF from '../components/pdf/ContractPDF'
import OfficePDF from '../components/pdf/OfficePDF'
import FlexSeatPDF from '../components/pdf/FlexSeatPDF'
import {
  ArrowLeft,
  Edit2,
  Pencil,
  User,
  Phone,
  Mail,
  MapPin,
  MessageSquare,
  FileText,
  CreditCard,
  Calendar,
  Building,
  DollarSign,
  Clock,
  CheckCircle,
  AlertTriangle,
  Send,
  Loader2,
  Save,
  X,
  RefreshCw,
  Bell,
  Receipt,
  ChevronDown,
  FileDown,
  RotateCcw,
  Plus,
  Trash2
} from 'lucide-react'

// 分館資料（含法人資訊）
const BRANCHES = {
  1: {
    name: '大忠館',
    company_name: '你的空間有限公司',
    tax_id: '83772050',
    representative: '戴豪廷',
    address: '台中市西區大忠南街55號7F-5',
    court: '台南地方法院'
  },
  2: {
    name: '環瑞館',
    company_name: '樞紐前沿股份有限公司',
    tax_id: '60710368',
    representative: '戴豪廷',
    address: '臺中市西區台灣大道二段181號4樓之1',
    court: '台中地方法院'
  }
}

// ============================================================================
// Checklist 相關：Computed Flags 和 Display Status
// ============================================================================

// 從時間戳計算 flags
function computeFlags(contract) {
  return {
    is_notified: !!contract.renewal_notified_at,
    is_confirmed: !!contract.renewal_confirmed_at,
    is_paid: !!contract.renewal_paid_at,
    is_signed: !!contract.renewal_signed_at,
    is_invoiced: contract.invoice_status && contract.invoice_status !== 'pending_tax_id'
  }
}

// 根據 flags 計算顯示狀態
function getDisplayStatus(contract) {
  const flags = computeFlags(contract)

  // 檢查是否全部完成
  const allDone = flags.is_notified && flags.is_confirmed &&
    flags.is_paid && flags.is_invoiced && flags.is_signed
  if (allDone) return { label: '完成', stage: 'completed', progress: 5, issues: [] }

  // 檢查是否尚未開始
  const noneStarted = !flags.is_notified && !flags.is_confirmed &&
    !flags.is_paid && !flags.is_invoiced && !flags.is_signed
  if (noneStarted) return { label: '待處理', stage: 'pending', progress: 0, issues: ['全部待處理'] }

  // 收集缺漏項目
  const issues = []
  if (!flags.is_notified) issues.push('未通知')
  if (!flags.is_confirmed) issues.push('未確認')
  if (!flags.is_paid) issues.push('未收款')
  if (!flags.is_invoiced) issues.push('未開票')
  if (!flags.is_signed) issues.push('未簽約')

  return {
    label: '進行中',
    stage: 'in_progress',
    issues,
    progress: 5 - issues.length
  }
}

// ============================================================================
// Checklist Popover 元件
// ============================================================================

function ChecklistPopover({ contract, onUpdate, onSaveNotes, isUpdating, onClose }) {
  const flags = computeFlags(contract)
  const popoverRef = useRef(null)
  const [notes, setNotes] = useState(contract.renewal_notes || '')
  const [notesChanged, setNotesChanged] = useState(false)

  // 點擊外部關閉
  useEffect(() => {
    const handleClickOutside = (e) => {
      if (popoverRef.current && !popoverRef.current.contains(e.target)) {
        onClose()
      }
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [onClose])

  // 同步外部 notes 變更
  useEffect(() => {
    setNotes(contract.renewal_notes || '')
    setNotesChanged(false)
  }, [contract.renewal_notes])

  // V3 設計：可手動更新的意願管理項目（只有 notified 和 confirmed）
  const editableItems = [
    { key: 'notified', label: '已通知', icon: Bell, checked: flags.is_notified, timestamp: contract.renewal_notified_at },
    { key: 'confirmed', label: '已確認', icon: CheckCircle, checked: flags.is_confirmed, timestamp: contract.renewal_confirmed_at },
  ]

  // V3 設計：唯讀顯示的財務狀態（SSOT，從 payment 計算）
  const readonlyItems = [
    { key: 'paid', label: '已收款', icon: Receipt, checked: flags.is_paid, hint: flags.is_paid ? '（付款管理）' : '→ 付款管理' },
  ]

  const formatTime = (ts) => {
    if (!ts) return null
    return new Date(ts).toLocaleString('zh-TW', {
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit'
    })
  }

  const handleNotesChange = (e) => {
    setNotes(e.target.value)
    setNotesChanged(e.target.value !== (contract.renewal_notes || ''))
  }

  const handleSaveNotes = () => {
    if (notesChanged) {
      onSaveNotes(notes)
      setNotesChanged(false)
    }
  }

  return (
    <div ref={popoverRef} className="absolute top-full left-0 mt-2 bg-white border rounded-lg shadow-lg z-50 p-3 min-w-[320px]">
      <h4 className="font-medium text-gray-900 mb-3 pb-2 border-b">續約進度 Checklist</h4>

      {/* 意願管理（可勾選） */}
      <div className="space-y-2 mb-3">
        <div className="text-xs text-gray-400 mb-1">意願管理</div>
        {editableItems.map(({ key, label, icon: Icon, checked, timestamp }) => (
          <div key={key} className="flex items-center justify-between">
            <label className="flex items-center gap-2 cursor-pointer flex-1">
              <input
                type="checkbox"
                checked={checked}
                onChange={() => {
                  console.log('[Checkbox] clicked:', key, '→', !checked)
                  onUpdate(key, !checked)
                }}
                disabled={isUpdating}
                className="rounded border-gray-300 text-primary-600 focus:ring-primary-500"
              />
              <Icon className={`w-4 h-4 ${checked ? 'text-green-500' : 'text-gray-400'}`} />
              <span className={`text-sm ${checked ? 'text-gray-900' : 'text-gray-500'}`}>
                {label}
              </span>
            </label>
            {timestamp && (
              <span className="text-xs text-gray-400">{formatTime(timestamp)}</span>
            )}
          </div>
        ))}
      </div>

      {/* 財務狀態（唯讀顯示，SSOT） */}
      <div className="pt-2 mt-2 border-t space-y-2">
        <div className="text-xs text-gray-400 mb-1">財務狀態（唯讀）</div>
        {readonlyItems.map(({ key, label, icon: Icon, checked, hint }) => (
          <div key={key} className="flex items-center justify-between opacity-70">
            <div className="flex items-center gap-2 flex-1">
              <div className={`w-4 h-4 rounded border ${checked ? 'bg-green-500 border-green-500' : 'border-gray-300'} flex items-center justify-center`}>
                {checked && <CheckCircle className="w-3 h-3 text-white" />}
              </div>
              <Icon className={`w-4 h-4 ${checked ? 'text-green-500' : 'text-gray-400'}`} />
              <span className={`text-sm ${checked ? 'text-gray-900' : 'text-gray-500'}`}>
                {label}
              </span>
              {hint && (
                <span className="text-xs text-gray-400 ml-1">{hint}</span>
              )}
            </div>
          </div>
        ))}
      </div>

      {/* 備註欄位 */}
      <div className="pt-2 mt-2 border-t">
        <label className="block text-sm text-gray-600 mb-1">
          備註
        </label>
        <textarea
          value={notes}
          onChange={handleNotesChange}
          placeholder="續約相關備註..."
          className="w-full text-sm border rounded p-2 h-16 resize-none focus:ring-1 focus:ring-primary-500 focus:border-primary-500"
        />
        {notesChanged && (
          <button
            onClick={handleSaveNotes}
            disabled={isUpdating}
            className="mt-1 w-full text-xs px-2 py-1.5 bg-primary-500 text-white rounded hover:bg-primary-600 disabled:opacity-50"
          >
            儲存備註
          </button>
        )}
      </div>

      {isUpdating && (
        <div className="flex items-center justify-center gap-2 mt-3 pt-2 border-t text-sm text-gray-500">
          <Loader2 className="w-4 h-4 animate-spin" />
          更新中...
        </div>
      )}
    </div>
  )
}

// ============================================================================
// 進度條元件
// ============================================================================

function ProgressBar({ progress, stage }) {
  const colors = {
    pending: 'bg-gray-200',
    in_progress: 'bg-blue-500',
    completed: 'bg-green-500'
  }

  return (
    <div className="flex items-center gap-2">
      <div className="flex gap-0.5">
        {[...Array(5)].map((_, i) => (
          <div
            key={i}
            className={`w-2.5 h-5 rounded-sm transition-colors ${
              i < progress ? colors[stage] : 'bg-gray-200'
            }`}
          />
        ))}
      </div>
      <span className="text-sm text-gray-600">{progress}/5</span>
    </div>
  )
}

// 合約類型對照
const CONTRACT_TYPES = {
  virtual_office: '營業登記',
  shared_space: '共享空間',
  coworking_fixed: '固定座位',
  coworking_flexible: '自由座位',
  meeting_room: '會議室',
  mailbox: '郵件代收'
}

// 繳費週期對照
const PAYMENT_CYCLES = {
  monthly: '月繳',
  quarterly: '季繳',
  semi_annual: '半年繳',
  annual: '年繳'
}

// 繳費週期乘數
const CYCLE_MULTIPLIER = {
  monthly: 1,
  quarterly: 3,
  semi_annual: 6,
  annual: 12
}

export default function ContractDetail() {
  const { id } = useParams()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { data: result, isLoading, refetch } = useContractDetail(id)
  const recordPayment = useBillingRecordPayment()
  const sendReminder = useSendPaymentReminder()
  const updateCustomer = useUpdateCustomer()

  const [showPayModal, setShowPayModal] = useState(false)
  const [showReminderModal, setShowReminderModal] = useState(false)
  const [showEditCustomerModal, setShowEditCustomerModal] = useState(false)
  const [showEditContractModal, setShowEditContractModal] = useState(false)
  const [showChecklistPopover, setShowChecklistPopover] = useState(false)
  const [showRenewalModal, setShowRenewalModal] = useState(false)
  const [selectedPayment, setSelectedPayment] = useState(null)
  const [generatingPdf, setGeneratingPdf] = useState(false)
  const [renewalDraft, setRenewalDraft] = useState(null)
  const [renewalLoading, setRenewalLoading] = useState(false)
  const [renewalForm, setRenewalForm] = useState({
    plan_name: '',
    monthly_rent: '',
    start_date: '',
    end_date: '',
    payment_cycle: 'monthly',
    position_number: '',
    notes: ''
  })
  const [paymentForm, setPaymentForm] = useState({
    payment_method: 'transfer',
    reference: ''
  })
  const [customerForm, setCustomerForm] = useState({})
  const [contractForm, setContractForm] = useState({
    company_name: '',
    representative_name: '',
    representative_address: '',
    id_number: '',
    company_tax_id: '',
    phone: '',
    email: '',
    branch_id: 1,
    contract_type: 'virtual_office',
    start_date: '',
    end_date: '',
    original_price: '',
    monthly_rent: '',
    deposit_amount: '',
    payment_cycle: 'monthly',
    payment_day: 8,
    position_number: ''
  })

  // 設定 renewal flag (Checklist)
  const setRenewalFlag = useMutation({
    mutationFn: async ({ contractId, flag, value }) => {
      console.log('[setRenewalFlag] mutationFn called:', { contractId, flag, value })
      if (flag === 'invoice') {
        // 發票狀態使用獨立 API
        return crm.updateInvoiceStatus(contractId, value)
      }
      return crm.setRenewalFlag(contractId, flag, value)
    },
    onSuccess: (data) => {
      console.log('[setRenewalFlag] onSuccess:', data)
      // 強制 refetch 而不只是 invalidate
      queryClient.refetchQueries({ queryKey: ['contract', id] })
      queryClient.refetchQueries({ queryKey: ['renewals'] })
    },
    onError: (error) => {
      console.error('[setRenewalFlag] onError:', error)
    }
  })

  // 處理 Checklist 更新
  const handleChecklistUpdate = (flag, value) => {
    if (!contract) return
    setRenewalFlag.mutate({
      contractId: contract.id,
      flag,
      value
    })
  }

  // 儲存續約備註
  const saveNotes = useMutation({
    mutationFn: async ({ contractId, notes }) => {
      return crm.updateRenewalNotes(contractId, notes)
    },
    onSuccess: () => {
      queryClient.refetchQueries({ queryKey: ['contract', id] })
    }
  })

  const handleSaveNotes = (notes) => {
    if (!contract) return
    saveNotes.mutate({ contractId: contract.id, notes })
  }

  // ============================================================================
  // 續約相關函數
  // ============================================================================

  // 開啟續約 Modal
  const openRenewalModal = async () => {
    if (!contract) return
    setRenewalLoading(true)

    try {
      // 1. 先檢查是否已有草稿
      const checkResult = await crm.callTool('renewal_check_draft', {
        old_contract_id: contract.id
      })

      if (checkResult?.has_draft) {
        // 有草稿，載入草稿資料
        setRenewalDraft(checkResult.draft)
        setRenewalForm({
          plan_name: checkResult.draft.plan_name || contract.plan_name || '',
          monthly_rent: checkResult.draft.monthly_rent || contract.monthly_rent || '',
          start_date: checkResult.draft.start_date || '',
          end_date: checkResult.draft.end_date || '',
          payment_cycle: checkResult.draft.payment_cycle || contract.payment_cycle || 'monthly',
          position_number: checkResult.draft.position_number || contract.position_number || '',
          notes: checkResult.draft.notes || ''
        })
      } else {
        // 無草稿，使用原合約預設值
        const nextStartDate = contract.end_date
          ? new Date(new Date(contract.end_date).getTime() + 86400000).toISOString().split('T')[0]
          : new Date().toISOString().split('T')[0]
        const nextEndDate = contract.end_date
          ? new Date(new Date(nextStartDate).setFullYear(new Date(nextStartDate).getFullYear() + 1)).toISOString().split('T')[0]
          : ''

        setRenewalDraft(null)
        setRenewalForm({
          plan_name: contract.plan_name || '',
          monthly_rent: contract.monthly_rent || '',
          start_date: nextStartDate,
          end_date: nextEndDate,
          payment_cycle: contract.payment_cycle || 'monthly',
          position_number: contract.position_number || '',
          notes: ''
        })
      }

      setShowRenewalModal(true)
    } catch (error) {
      console.error('檢查續約草稿失敗:', error)
      alert('檢查續約草稿失敗: ' + (error.message || '未知錯誤'))
    } finally {
      setRenewalLoading(false)
    }
  }

  // 建立或更新續約草稿
  const handleSaveRenewalDraft = async () => {
    if (!contract) return
    setRenewalLoading(true)

    try {
      if (renewalDraft) {
        // 更新現有草稿
        await crm.callTool('renewal_update_draft', {
          draft_id: renewalDraft.id,
          updates: renewalForm
        })
      } else {
        // 建立新草稿
        const result = await crm.callTool('renewal_create_draft', {
          old_contract_id: contract.id,
          new_data: renewalForm
        })
        if (result?.draft_id) {
          setRenewalDraft({ id: result.draft_id, contract_number: result.contract_number })
        }
      }
      alert('草稿已儲存')
      refetch()
    } catch (error) {
      console.error('儲存續約草稿失敗:', error)
      alert('儲存失敗: ' + (error.message || '未知錯誤'))
    } finally {
      setRenewalLoading(false)
    }
  }

  // 啟用續約（確認）
  const handleActivateRenewal = async () => {
    if (!renewalDraft) {
      alert('請先儲存草稿')
      return
    }

    if (!window.confirm(`確定要啟用續約嗎？\n\n新合約編號：${renewalDraft.contract_number}\n原合約將標記為「已續約」`)) {
      return
    }

    setRenewalLoading(true)
    try {
      const result = await crm.callTool('renewal_activate', {
        draft_id: renewalDraft.id
      })

      if (result?.success) {
        alert('續約成功！')
        setShowRenewalModal(false)
        setRenewalDraft(null)
        // 跳轉到新合約
        navigate(`/contracts/${result.new_contract_id}`)
      } else {
        alert('續約失敗: ' + (result?.error || '未知錯誤'))
      }
    } catch (error) {
      console.error('啟用續約失敗:', error)
      alert('啟用失敗: ' + (error.message || '未知錯誤'))
    } finally {
      setRenewalLoading(false)
    }
  }

  // 取消續約草稿
  const handleCancelRenewalDraft = async () => {
    if (!renewalDraft) return

    if (!window.confirm('確定要取消此續約草稿嗎？')) {
      return
    }

    setRenewalLoading(true)
    try {
      await crm.callTool('renewal_cancel_draft', {
        draft_id: renewalDraft.id
      })
      alert('草稿已取消')
      setShowRenewalModal(false)
      setRenewalDraft(null)
      refetch()
    } catch (error) {
      console.error('取消續約草稿失敗:', error)
      alert('取消失敗: ' + (error.message || '未知錯誤'))
    } finally {
      setRenewalLoading(false)
    }
  }

  // 更新合約 mutation
  const updateContract = useMutation({
    mutationFn: async ({ contractId, data }) => {
      await api.patch(`/api/db/contracts?id=eq.${contractId}`, data)
      return { success: true }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['contract', id] })
      setShowEditContractModal(false)
      refetch()
    }
  })

  // 開啟編輯合約 Modal
  const startEditContract = () => {
    if (!contract) return
    setContractForm({
      company_name: contract.company_name || customer?.company_name || '',
      representative_name: contract.representative_name || customer?.name || '',
      representative_address: contract.representative_address || '',
      id_number: contract.id_number || '',
      company_tax_id: contract.company_tax_id || '',
      phone: contract.phone || customer?.phone || '',
      email: contract.email || customer?.email || '',
      branch_id: contract.branch_id || 1,
      contract_type: contract.contract_type || 'virtual_office',
      start_date: contract.start_date || '',
      end_date: contract.end_date || '',
      original_price: contract.original_price || 3000,
      monthly_rent: contract.monthly_rent || '',
      deposit_amount: contract.deposit || '',
      payment_cycle: contract.payment_cycle || 'monthly',
      payment_day: contract.payment_day || 8,
      position_number: contract.position_number || ''
    })
    setShowEditContractModal(true)
  }

  // 儲存合約編輯
  const handleSaveContract = (e) => {
    e.preventDefault()
    if (!contract) return

    updateContract.mutate({
      contractId: contract.id,
      data: {
        company_name: contractForm.company_name || null,
        representative_name: contractForm.representative_name || null,
        representative_address: contractForm.representative_address || null,
        id_number: contractForm.id_number || null,
        company_tax_id: contractForm.company_tax_id || null,
        phone: contractForm.phone || null,
        email: contractForm.email || null,
        branch_id: parseInt(contractForm.branch_id) || 1,
        contract_type: contractForm.contract_type,
        start_date: contractForm.start_date,
        end_date: contractForm.end_date,
        original_price: parseFloat(contractForm.original_price) || null,
        monthly_rent: parseFloat(contractForm.monthly_rent) || null,
        deposit: parseFloat(contractForm.deposit_amount) || null,
        payment_cycle: contractForm.payment_cycle,
        payment_day: parseInt(contractForm.payment_day) || 8,
        position_number: contractForm.position_number || null
      }
    })
  }

  const contract = result?.data?.contract
  const customer = result?.data?.customer
  const branch = result?.data?.branch
  const payments = result?.data?.payments || []

  // 計算繳費統計
  const paymentStats = {
    total: payments.length,
    paid: payments.filter(p => p.payment_status === 'paid').length,
    pending: payments.filter(p => p.payment_status === 'pending').length,
    overdue: payments.filter(p => p.payment_status === 'overdue').length,
    totalPaid: payments.filter(p => p.payment_status === 'paid').reduce((sum, p) => sum + (p.amount || 0), 0),
    totalPending: payments.filter(p => p.payment_status === 'pending' || p.payment_status === 'overdue').reduce((sum, p) => sum + (p.amount || 0), 0)
  }

  // 記錄繳費
  const handleRecordPayment = async () => {
    try {
      const result = await recordPayment.mutateAsync({
        paymentId: selectedPayment.id,
        paymentMethod: paymentForm.payment_method,
        amount: selectedPayment.amount,  // 必填：應付金額
        notes: paymentForm.reference || null,  // 備註（如轉帳後五碼）
        paymentDate: new Date().toISOString().split('T')[0]
      })

      if (result?.success) {
        setShowPayModal(false)
        setSelectedPayment(null)
        setPaymentForm({ payment_method: 'transfer', reference: '' })
        refetch()
      }
    } catch (error) {
      console.error('付費記錄失敗:', error)
    }
  }

  // 發送催繳
  const handleSendReminder = async () => {
    await sendReminder.mutateAsync({
      customerId: customer.id,
      amount: selectedPayment.amount,
      dueDate: selectedPayment.due_date
    })
    setShowReminderModal(false)
    setSelectedPayment(null)
  }

  // 編輯客戶資料
  const startEditCustomer = () => {
    setCustomerForm({
      name: customer?.name || '',
      company_name: customer?.company_name || '',
      phone: customer?.phone || '',
      email: customer?.email || '',
      address: customer?.address || '',
      risk_level: customer?.risk_level || 'low'
    })
    setShowEditCustomerModal(true)
  }

  const handleSaveCustomer = async () => {
    await updateCustomer.mutateAsync({
      customerId: customer.id,
      data: customerForm
    })
    setShowEditCustomerModal(false)
    refetch()
  }

  // 計算合約月數
  const calculateMonths = (startDate, endDate) => {
    if (!startDate || !endDate) return 12
    const start = new Date(startDate)
    const end = new Date(endDate)
    const months = (end.getFullYear() - start.getFullYear()) * 12 + (end.getMonth() - start.getMonth())
    return months > 0 ? months : 12
  }

  // 準備 PDF 資料
  const pdfData = useMemo(() => {
    if (!contract || !branch) return null
    const branchInfo = BRANCHES[contract.branch_id] || BRANCHES[1]
    return {
      // 合約類型
      contract_type: contract.contract_type,
      // 甲方資訊（從分館帶入）
      branch_company_name: branchInfo.company_name,
      branch_tax_id: branchInfo.tax_id,
      branch_representative: branchInfo.representative,
      branch_address: branchInfo.address,
      branch_court: branchInfo.court,
      branch_id: contract.branch_id,
      room_number: contract.room_number || '',
      // 乙方資訊（優先使用合約儲存的，fallback 到客戶資料）
      company_name: contract.company_name || customer?.company_name || '',
      representative_name: contract.representative_name || customer?.name || '',
      representative_address: contract.representative_address || customer?.address || '',
      id_number: contract.id_number || customer?.id_number || '',
      company_tax_id: contract.company_tax_id || customer?.company_tax_id || '',
      phone: contract.phone || customer?.phone || '',
      email: contract.email || customer?.email || '',
      // 租賃條件
      start_date: contract.start_date,
      end_date: contract.end_date,
      periods: calculateMonths(contract.start_date, contract.end_date),
      original_price: parseFloat(contract.original_price) || 0,
      monthly_rent: parseFloat(contract.monthly_rent) || 0,
      deposit_amount: parseFloat(contract.deposit) || 0,
      payment_day: parseInt(contract.payment_day) || 8,
      // 電子用印
      show_stamp: true
    }
  }, [contract, branch, customer])

  // 生成合約 PDF（前端生成）
  const handleGeneratePdf = async () => {
    if (!contract || !pdfData) return
    setGeneratingPdf(true)
    try {
      // 根據合約類型選擇 PDF 組件
      let PdfComponent
      if (contract.contract_type === 'office') {
        PdfComponent = OfficePDF
      } else if (contract.contract_type === 'flex_seat') {
        PdfComponent = FlexSeatPDF
      } else {
        PdfComponent = ContractPDF
      }

      // 生成 PDF blob
      const blob = await pdf(<PdfComponent data={pdfData} />).toBlob()

      // 建立下載連結
      const url = URL.createObjectURL(blob)
      const link = document.createElement('a')
      link.href = url
      link.download = `合約_${contract.contract_number}.pdf`
      document.body.appendChild(link)
      link.click()
      document.body.removeChild(link)
      URL.revokeObjectURL(url)
    } catch (error) {
      console.error('生成合約 PDF 失敗:', error)
      alert('生成合約 PDF 失敗: ' + (error.message || '未知錯誤'))
    } finally {
      setGeneratingPdf(false)
    }
  }

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-96">
        <div className="animate-spin w-8 h-8 border-2 border-primary-500 border-t-transparent rounded-full" />
      </div>
    )
  }

  if (!contract) {
    return (
      <div className="text-center py-12">
        <p className="text-gray-500">找不到合約資料</p>
        <button onClick={() => navigate('/contracts')} className="btn-primary mt-4">
          返回合約列表
        </button>
      </div>
    )
  }

  // 計算每期金額
  const periodAmount = (contract.monthly_rent || 0) * (CYCLE_MULTIPLIER[contract.payment_cycle] || 1)

  return (
    <div className="space-y-6">
      {/* 頂部導覽 */}
      <div className="flex items-center gap-4">
        <button
          onClick={() => navigate('/contracts')}
          className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
        >
          <ArrowLeft className="w-5 h-5 text-gray-600" />
        </button>
        <div className="flex-1">
          <div className="flex items-center gap-3">
            <h1 className="text-2xl font-bold text-gray-900">{contract.contract_number}</h1>
            <StatusBadge status={contract.status} />
          </div>
          <p className="text-gray-500">
            {CONTRACT_TYPES[contract.contract_type] || contract.contract_type}
            {contract.plan_name && ` - ${contract.plan_name}`}
          </p>
        </div>
        <button onClick={refetch} className="btn-secondary" title="重新整理">
          <RefreshCw className="w-4 h-4" />
        </button>
        {/* 續約按鈕 - 只有 active 狀態的合約才能續約 */}
        {contract.status === 'active' && (
          <button
            onClick={openRenewalModal}
            disabled={renewalLoading}
            className="btn-secondary bg-orange-50 text-orange-700 border-orange-200 hover:bg-orange-100"
            title="辦理續約"
          >
            {renewalLoading ? (
              <Loader2 className="w-4 h-4 animate-spin mr-2" />
            ) : (
              <RotateCcw className="w-4 h-4 mr-2" />
            )}
            續約
          </button>
        )}
        <button
          onClick={handleGeneratePdf}
          disabled={generatingPdf || !pdfData}
          className="btn-primary"
          title="下載合約 PDF"
        >
          {generatingPdf ? (
            <Loader2 className="w-4 h-4 animate-spin mr-2" />
          ) : (
            <FileDown className="w-4 h-4 mr-2" />
          )}
          {generatingPdf ? '生成中...' : '下載 PDF'}
        </button>
      </div>

      {/* 主要內容 */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* 左側：客戶資訊卡片 */}
        <div className="space-y-6">
          {/* 客戶資料卡 */}
          <div className="card">
            <div className="flex items-center justify-between mb-4">
              <h3 className="card-title flex items-center gap-2">
                <User className="w-5 h-5 text-primary-500" />
                客戶資訊
              </h3>
              <button onClick={startEditCustomer} className="text-gray-400 hover:text-gray-600">
                <Edit2 className="w-4 h-4" />
              </button>
            </div>

            <div className="flex items-center gap-4 mb-4">
              <div className="w-14 h-14 bg-gradient-to-br from-primary-400 to-primary-600 rounded-xl flex items-center justify-center">
                <span className="text-xl font-bold text-white">
                  {customer?.name?.charAt(0) || '?'}
                </span>
              </div>
              <div>
                <p className="font-semibold text-lg">{customer?.name || '-'}</p>
                {customer?.company_name && (
                  <p className="text-sm text-gray-500">{customer.company_name}</p>
                )}
              </div>
            </div>

            <div className="space-y-3">
              {customer?.phone && (
                <div className="flex items-center gap-3 text-sm">
                  <Phone className="w-4 h-4 text-gray-400" />
                  <a href={`tel:${customer.phone}`} className="text-primary-600 hover:underline">
                    {customer.phone}
                  </a>
                </div>
              )}
              {customer?.email && (
                <div className="flex items-center gap-3 text-sm">
                  <Mail className="w-4 h-4 text-gray-400" />
                  <a href={`mailto:${customer.email}`} className="text-primary-600 hover:underline">
                    {customer.email}
                  </a>
                </div>
              )}
              {customer?.address && (
                <div className="flex items-center gap-3 text-sm">
                  <MapPin className="w-4 h-4 text-gray-400" />
                  <span className="text-gray-600">{customer.address}</span>
                </div>
              )}
              <div className="flex items-center gap-3 text-sm">
                <MessageSquare className="w-4 h-4 text-gray-400" />
                {customer?.line_user_id ? (
                  <Badge variant="success" dot>LINE 已綁定</Badge>
                ) : (
                  <Badge variant="gray">LINE 未綁定</Badge>
                )}
              </div>
              <div className="flex items-center gap-3 text-sm">
                <AlertTriangle className="w-4 h-4 text-gray-400" />
                <span className="text-gray-600">風險等級：</span>
                <StatusBadge status={customer?.risk_level || 'low'} />
              </div>
            </div>
          </div>

          {/* 分館資訊 */}
          <div className="card">
            <h3 className="card-title flex items-center gap-2 mb-4">
              <Building className="w-5 h-5 text-blue-500" />
              分館
            </h3>
            <p className="font-medium">{branch?.name || '-'}</p>
            {contract.rental_address && (
              <p className="text-sm text-gray-500 mt-1">{contract.rental_address}</p>
            )}
          </div>

          {/* 繳費統計 */}
          <div className="card">
            <h3 className="card-title flex items-center gap-2 mb-4">
              <DollarSign className="w-5 h-5 text-green-500" />
              繳費統計
            </h3>
            <div className="space-y-3">
              <div className="flex justify-between">
                <span className="text-gray-500">已付總額</span>
                <span className="font-semibold text-green-600">
                  ${paymentStats.totalPaid.toLocaleString()}
                </span>
              </div>
              <div className="flex justify-between">
                <span className="text-gray-500">待繳金額</span>
                <span className="font-semibold text-blue-600">
                  ${paymentStats.totalPending.toLocaleString()}
                </span>
              </div>
              {paymentStats.overdue > 0 && (
                <div className="flex justify-between text-red-600">
                  <span>逾期 ({paymentStats.overdue} 筆)</span>
                  <span className="font-semibold">
                    ${payments.filter(p => p.payment_status === 'overdue').reduce((sum, p) => sum + (p.amount || 0), 0).toLocaleString()}
                  </span>
                </div>
              )}
            </div>
          </div>
        </div>

        {/* 右側：合約資訊和繳費記錄 */}
        <div className="lg:col-span-2 space-y-6">
          {/* 合約資訊 */}
          <div className="card">
            <div className="flex items-center justify-between mb-4">
              <h3 className="card-title flex items-center gap-2">
                <FileText className="w-5 h-5 text-primary-500" />
                合約資訊
              </h3>
              {contract.status !== 'terminated' && contract.status !== 'cancelled' && (
                <button
                  onClick={startEditContract}
                  className="text-gray-400 hover:text-blue-600 transition-colors"
                  title="編輯合約"
                >
                  <Pencil className="w-4 h-4" />
                </button>
              )}
            </div>
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
              <div>
                <p className="text-xs text-gray-500 mb-1">合約期間</p>
                <p className="font-medium">{contract.start_date}</p>
                <p className="text-sm text-gray-500">至 {contract.end_date}</p>
              </div>
              <div>
                <p className="text-xs text-gray-500 mb-1">月租金額</p>
                <p className="font-semibold text-lg text-green-600">
                  ${(contract.monthly_rent || 0).toLocaleString()}
                </p>
              </div>
              <div>
                <p className="text-xs text-gray-500 mb-1">繳費週期</p>
                <p className="font-medium">
                  {PAYMENT_CYCLES[contract.payment_cycle] || contract.payment_cycle}
                </p>
                <p className="text-sm text-gray-500">
                  ${periodAmount.toLocaleString()}/期
                </p>
              </div>
              <div>
                <p className="text-xs text-gray-500 mb-1">押金</p>
                <p className="font-medium">
                  ${(contract.deposit || 0).toLocaleString()}
                </p>
                <p className="text-xs text-gray-500">
                  {contract.deposit_status === 'held' ? '持有中' :
                   contract.deposit_status === 'refunded' ? '已退還' : '已沒收'}
                </p>
              </div>
            </div>

            {/* 續約進度 Checklist */}
            <div className="mt-4 pt-4 border-t">
              <div className="flex items-center justify-between mb-3">
                <div className="flex items-center gap-2">
                  <Clock className="w-4 h-4 text-orange-500" />
                  <span className="text-sm font-medium">續約進度</span>
                </div>
                {(() => {
                  const status = getDisplayStatus(contract)
                  const stageColors = {
                    pending: 'bg-gray-100 text-gray-600',
                    in_progress: 'bg-blue-100 text-blue-700',
                    completed: 'bg-green-100 text-green-700'
                  }
                  return (
                    <span className={`text-xs px-2 py-0.5 rounded-full ${stageColors[status.stage]}`}>
                      {status.label}
                    </span>
                  )
                })()}
              </div>

              {/* 進度條 + 展開按鈕 */}
              <div className="relative">
                <button
                  onClick={() => setShowChecklistPopover(!showChecklistPopover)}
                  className="flex items-center gap-3 w-full p-2 -mx-2 rounded-lg hover:bg-gray-50 transition-colors"
                >
                  <ProgressBar
                    progress={getDisplayStatus(contract).progress}
                    stage={getDisplayStatus(contract).stage}
                  />
                  <ChevronDown className={`w-4 h-4 text-gray-400 transition-transform ${showChecklistPopover ? 'rotate-180' : ''}`} />
                </button>

                {/* Checklist Popover */}
                {showChecklistPopover && (
                  <ChecklistPopover
                    contract={contract}
                    onUpdate={handleChecklistUpdate}
                    onSaveNotes={handleSaveNotes}
                    isUpdating={setRenewalFlag.isPending || saveNotes.isPending}
                    onClose={() => setShowChecklistPopover(false)}
                  />
                )}
              </div>

              {/* 備註 */}
              {contract.renewal_notes && (
                <p className="text-xs text-gray-500 mt-2">{contract.renewal_notes}</p>
              )}
            </div>
          </div>

          {/* 繳費記錄 */}
          <div className="card">
            <div className="card-header">
              <h3 className="card-title flex items-center gap-2">
                <CreditCard className="w-5 h-5 text-green-500" />
                繳費記錄
              </h3>
              <div className="flex items-center gap-2">
                <Badge variant="success">{paymentStats.paid} 已付</Badge>
                <Badge variant="info">{paymentStats.pending} 待繳</Badge>
                {paymentStats.overdue > 0 && (
                  <Badge variant="danger">{paymentStats.overdue} 逾期</Badge>
                )}
              </div>
            </div>

            {payments.length === 0 ? (
              <p className="text-center py-8 text-gray-500">尚無繳費記錄</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="data-table">
                  <thead>
                    <tr>
                      <th>期別</th>
                      <th>金額</th>
                      <th>到期日</th>
                      <th>狀態</th>
                      <th>付款日</th>
                      <th>操作</th>
                    </tr>
                  </thead>
                  <tbody>
                    {payments.map((payment) => (
                      <tr key={payment.id}>
                        <td className="font-medium">{payment.payment_period}</td>
                        <td>${(payment.amount || 0).toLocaleString()}</td>
                        <td>{payment.due_date}</td>
                        <td><StatusBadge status={payment.payment_status} /></td>
                        <td>{payment.paid_at || '-'}</td>
                        <td>
                          {payment.payment_status === 'pending' && (
                            <div className="flex items-center gap-1">
                              <button
                                onClick={() => {
                                  setSelectedPayment(payment)
                                  setShowPayModal(true)
                                }}
                                className="text-xs px-2 py-1 bg-green-100 text-green-700 rounded hover:bg-green-200"
                              >
                                記錄繳費
                              </button>
                            </div>
                          )}
                          {payment.payment_status === 'overdue' && (
                            <div className="flex items-center gap-1">
                              <button
                                onClick={() => {
                                  setSelectedPayment(payment)
                                  setShowPayModal(true)
                                }}
                                className="text-xs px-2 py-1 bg-green-100 text-green-700 rounded hover:bg-green-200"
                              >
                                記錄繳費
                              </button>
                              {customer?.line_user_id && (
                                <button
                                  onClick={() => {
                                    setSelectedPayment(payment)
                                    setShowReminderModal(true)
                                  }}
                                  className="text-xs px-2 py-1 bg-orange-100 text-orange-700 rounded hover:bg-orange-200"
                                >
                                  催繳
                                </button>
                              )}
                            </div>
                          )}
                          {payment.payment_status === 'paid' && (
                            <span className="text-xs text-gray-400">
                              {payment.payment_method === 'transfer' ? '轉帳' :
                               payment.payment_method === 'cash' ? '現金' :
                               payment.payment_method === 'card' ? '刷卡' : payment.payment_method}
                            </span>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* 記錄繳費 Modal */}
      <Modal
        open={showPayModal}
        onClose={() => {
          setShowPayModal(false)
          setSelectedPayment(null)
        }}
        title="記錄繳費"
      >
        {selectedPayment && (
          <div className="space-y-4">
            <div className="bg-gray-50 p-4 rounded-lg">
              <p className="text-sm text-gray-500">期別</p>
              <p className="font-medium">{selectedPayment.payment_period}</p>
              <p className="text-sm text-gray-500 mt-2">金額</p>
              <p className="font-semibold text-lg text-green-600">
                ${(selectedPayment.amount || 0).toLocaleString()}
              </p>
            </div>

            <div>
              <label htmlFor="payment-method" className="label">付款方式</label>
              <select
                id="payment-method"
                value={paymentForm.payment_method}
                onChange={(e) => setPaymentForm({ ...paymentForm, payment_method: e.target.value })}
                className="input"
              >
                <option value="transfer">銀行轉帳</option>
                <option value="cash">現金</option>
                <option value="card">信用卡</option>
              </select>
            </div>

            <div>
              <label htmlFor="payment-reference" className="label">參考編號（選填）</label>
              <input
                id="payment-reference"
                type="text"
                value={paymentForm.reference}
                onChange={(e) => setPaymentForm({ ...paymentForm, reference: e.target.value })}
                className="input"
                placeholder="轉帳帳號後五碼..."
              />
            </div>

            <div className="flex justify-end gap-2 pt-4">
              <button onClick={() => setShowPayModal(false)} className="btn-secondary">
                取消
              </button>
              <button
                onClick={handleRecordPayment}
                disabled={recordPayment.isPending}
                className="btn-primary"
              >
                <CheckCircle className="w-4 h-4 mr-2" />
                {recordPayment.isPending ? '處理中...' : '確認繳費'}
              </button>
            </div>
          </div>
        )}
      </Modal>

      {/* 發送催繳 Modal */}
      <Modal
        open={showReminderModal}
        onClose={() => {
          setShowReminderModal(false)
          setSelectedPayment(null)
        }}
        title="發送 LINE 催繳通知"
      >
        {selectedPayment && (
          <div className="space-y-4">
            <div className="bg-orange-50 p-4 rounded-lg">
              <p className="text-sm text-orange-600">
                將發送催繳通知給 {customer?.name}
              </p>
              <p className="font-medium mt-2">
                {selectedPayment.payment_period} - ${(selectedPayment.amount || 0).toLocaleString()}
              </p>
              <p className="text-sm text-gray-500">
                到期日：{selectedPayment.due_date}
              </p>
            </div>

            <div className="flex justify-end gap-2 pt-4">
              <button onClick={() => setShowReminderModal(false)} className="btn-secondary">
                取消
              </button>
              <button
                onClick={handleSendReminder}
                disabled={sendReminder.isPending}
                className="btn-primary bg-orange-500 hover:bg-orange-600"
              >
                <Send className="w-4 h-4 mr-2" />
                {sendReminder.isPending ? '發送中...' : '發送催繳'}
              </button>
            </div>
          </div>
        )}
      </Modal>

      {/* 編輯客戶資料 Modal */}
      <Modal
        open={showEditCustomerModal}
        onClose={() => setShowEditCustomerModal(false)}
        title="編輯客戶資料"
        size="lg"
      >
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label htmlFor="customer-name" className="label">姓名</label>
              <input
                id="customer-name"
                type="text"
                value={customerForm.name}
                onChange={(e) => setCustomerForm({ ...customerForm, name: e.target.value })}
                className="input"
              />
            </div>
            <div>
              <label htmlFor="customer-company" className="label">公司名稱</label>
              <input
                id="customer-company"
                type="text"
                value={customerForm.company_name}
                onChange={(e) => setCustomerForm({ ...customerForm, company_name: e.target.value })}
                className="input"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label htmlFor="customer-phone" className="label">電話</label>
              <input
                id="customer-phone"
                type="tel"
                value={customerForm.phone}
                onChange={(e) => setCustomerForm({ ...customerForm, phone: e.target.value })}
                className="input"
              />
            </div>
            <div>
              <label htmlFor="customer-email" className="label">Email</label>
              <input
                id="customer-email"
                type="email"
                value={customerForm.email}
                onChange={(e) => setCustomerForm({ ...customerForm, email: e.target.value })}
                className="input"
              />
            </div>
          </div>

          <div>
            <label htmlFor="customer-address" className="label">地址</label>
            <input
              id="customer-address"
              type="text"
              value={customerForm.address}
              onChange={(e) => setCustomerForm({ ...customerForm, address: e.target.value })}
              className="input"
            />
          </div>

          <div>
            <label htmlFor="customer-risk" className="label">風險等級</label>
            <select
              id="customer-risk"
              value={customerForm.risk_level}
              onChange={(e) => setCustomerForm({ ...customerForm, risk_level: e.target.value })}
              className="input"
            >
              <option value="low">低風險</option>
              <option value="normal">正常</option>
              <option value="medium">中風險</option>
              <option value="high">高風險</option>
            </select>
          </div>

          <div className="flex justify-end gap-2 pt-4">
            <button onClick={() => setShowEditCustomerModal(false)} className="btn-secondary">
              <X className="w-4 h-4 mr-2" />
              取消
            </button>
            <button
              onClick={handleSaveCustomer}
              disabled={updateCustomer.isPending}
              className="btn-primary"
            >
              <Save className="w-4 h-4 mr-2" />
              {updateCustomer.isPending ? '儲存中...' : '儲存'}
            </button>
          </div>
        </div>
      </Modal>

      {/* 編輯合約 Modal */}
      <Modal
        open={showEditContractModal}
        onClose={() => setShowEditContractModal(false)}
        title={`編輯合約 ${contract?.contract_number || ''}`}
        size="lg"
      >
        <form onSubmit={handleSaveContract} className="space-y-6">
          {/* 承租人資訊（乙方） */}
          <div className="p-4 bg-blue-50 rounded-lg border border-blue-200">
            <h3 className="font-medium text-blue-900 mb-4">承租人資訊（乙方）</h3>
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">公司名稱</label>
                <input
                  type="text"
                  value={contractForm.company_name}
                  onChange={(e) => setContractForm(prev => ({ ...prev, company_name: e.target.value }))}
                  className="input w-full"
                  placeholder="公司名稱"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">負責人姓名</label>
                <input
                  type="text"
                  value={contractForm.representative_name}
                  onChange={(e) => setContractForm(prev => ({ ...prev, representative_name: e.target.value }))}
                  className="input w-full"
                  placeholder="負責人姓名"
                />
              </div>
              <div className="col-span-2">
                <label className="block text-sm font-medium text-gray-700 mb-1">負責人地址</label>
                <input
                  type="text"
                  value={contractForm.representative_address}
                  onChange={(e) => setContractForm(prev => ({ ...prev, representative_address: e.target.value }))}
                  className="input w-full"
                  placeholder="戶籍地址"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">身分證號碼</label>
                <input
                  type="text"
                  value={contractForm.id_number}
                  onChange={(e) => setContractForm(prev => ({ ...prev, id_number: e.target.value }))}
                  className="input w-full"
                  placeholder="身分證/居留證號碼"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">公司統編</label>
                <input
                  type="text"
                  value={contractForm.company_tax_id}
                  onChange={(e) => setContractForm(prev => ({ ...prev, company_tax_id: e.target.value }))}
                  className="input w-full"
                  placeholder="8碼統編"
                  maxLength={8}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">聯絡電話</label>
                <input
                  type="text"
                  value={contractForm.phone}
                  onChange={(e) => setContractForm(prev => ({ ...prev, phone: e.target.value }))}
                  className="input w-full"
                  placeholder="聯絡電話"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">E-mail</label>
                <input
                  type="email"
                  value={contractForm.email}
                  onChange={(e) => setContractForm(prev => ({ ...prev, email: e.target.value }))}
                  className="input w-full"
                  placeholder="電子郵件"
                />
              </div>
            </div>
          </div>

          {/* 租賃條件 */}
          <div className="p-4 bg-green-50 rounded-lg border border-green-200">
            <h3 className="font-medium text-green-900 mb-4">租賃條件</h3>

            {/* 合約類型 */}
            <div className="grid grid-cols-2 gap-4 mb-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">合約類型</label>
                <select
                  value={contractForm.contract_type}
                  onChange={(e) => setContractForm(prev => ({ ...prev, contract_type: e.target.value }))}
                  className="input w-full"
                >
                  <option value="virtual_office">營業登記</option>
                  <option value="coworking_fixed">固定座位</option>
                  <option value="coworking_flexible">彈性座位</option>
                  <option value="meeting_room">會議室</option>
                </select>
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">分館</label>
                <select
                  value={contractForm.branch_id}
                  onChange={(e) => setContractForm(prev => ({ ...prev, branch_id: e.target.value }))}
                  className="input w-full"
                >
                  <option value="1">大忠館</option>
                  <option value="2">環瑞館</option>
                </select>
              </div>
            </div>

            {/* 合約期間 */}
            <div className="grid grid-cols-2 gap-4 mb-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">起始日期</label>
                <input
                  type="date"
                  value={contractForm.start_date}
                  onChange={(e) => setContractForm(prev => ({ ...prev, start_date: e.target.value }))}
                  className="input w-full"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">結束日期</label>
                <input
                  type="date"
                  value={contractForm.end_date}
                  onChange={(e) => setContractForm(prev => ({ ...prev, end_date: e.target.value }))}
                  className="input w-full"
                />
              </div>
            </div>

            {/* 金額 */}
            <div className="grid grid-cols-3 gap-4 mb-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">定價（原價）</label>
                <input
                  type="number"
                  value={contractForm.original_price}
                  onChange={(e) => setContractForm(prev => ({ ...prev, original_price: e.target.value }))}
                  className="input w-full"
                  placeholder="用於違約金計算"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">月租金額</label>
                <input
                  type="number"
                  value={contractForm.monthly_rent}
                  onChange={(e) => setContractForm(prev => ({ ...prev, monthly_rent: e.target.value }))}
                  className="input w-full"
                  placeholder="實際月租"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">押金</label>
                <input
                  type="number"
                  value={contractForm.deposit_amount}
                  onChange={(e) => setContractForm(prev => ({ ...prev, deposit_amount: e.target.value }))}
                  className="input w-full"
                  placeholder="押金金額"
                />
              </div>
            </div>

            {/* 繳費週期 */}
            <div className="grid grid-cols-3 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">繳費週期</label>
                <select
                  value={contractForm.payment_cycle}
                  onChange={(e) => setContractForm(prev => ({ ...prev, payment_cycle: e.target.value }))}
                  className="input w-full"
                >
                  <option value="monthly">月繳</option>
                  <option value="quarterly">季繳</option>
                  <option value="semi_annual">半年繳</option>
                  <option value="annual">年繳</option>
                  <option value="biennial">兩年繳</option>
                </select>
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">繳費日</label>
                <input
                  type="number"
                  min="1"
                  max="31"
                  value={contractForm.payment_day}
                  onChange={(e) => setContractForm(prev => ({ ...prev, payment_day: e.target.value }))}
                  className="input w-full"
                  placeholder="每月幾號"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">座位編號</label>
                <input
                  type="text"
                  value={contractForm.position_number}
                  onChange={(e) => setContractForm(prev => ({ ...prev, position_number: e.target.value }))}
                  className="input w-full"
                  placeholder="如：A1, 15"
                />
              </div>
            </div>
          </div>

          {/* 按鈕 */}
          <div className="flex justify-end gap-3 pt-4 border-t">
            <button
              type="button"
              onClick={() => setShowEditContractModal(false)}
              className="btn-secondary"
            >
              取消
            </button>
            <button
              type="submit"
              disabled={updateContract.isPending}
              className="btn-primary"
            >
              {updateContract.isPending ? (
                <>
                  <Loader2 className="w-4 h-4 mr-2 animate-spin" />
                  更新中...
                </>
              ) : (
                <>
                  <Save className="w-4 h-4 mr-2" />
                  儲存變更
                </>
              )}
            </button>
          </div>
        </form>
      </Modal>

      {/* 續約 Modal */}
      <Modal
        open={showRenewalModal}
        onClose={() => {
          setShowRenewalModal(false)
          // 不清空 renewalDraft，下次開啟時會重新檢查
        }}
        title={renewalDraft ? `續約草稿 - ${renewalDraft.contract_number}` : '辦理續約'}
        size="lg"
      >
        <div className="space-y-6">
          {/* 草稿狀態提示 */}
          {renewalDraft && (
            <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
              <div className="flex items-center gap-2">
                <AlertTriangle className="w-5 h-5 text-yellow-600" />
                <span className="text-yellow-800 font-medium">續約草稿</span>
              </div>
              <p className="text-sm text-yellow-700 mt-1">
                此續約尚未啟用。編輯完成後請點擊「確認續約」完成續約流程。
              </p>
            </div>
          )}

          {/* 原合約資訊 */}
          <div className="bg-gray-50 rounded-lg p-4">
            <h4 className="text-sm font-medium text-gray-700 mb-3">原合約資訊</h4>
            <div className="grid grid-cols-3 gap-4 text-sm">
              <div>
                <span className="text-gray-500">合約編號：</span>
                <span className="font-medium">{contract?.contract_number}</span>
              </div>
              <div>
                <span className="text-gray-500">到期日：</span>
                <span className="font-medium">{contract?.end_date}</span>
              </div>
              <div>
                <span className="text-gray-500">月租金：</span>
                <span className="font-medium">${contract?.monthly_rent?.toLocaleString()}</span>
              </div>
            </div>
          </div>

          {/* 新合約設定 */}
          <div className="p-4 bg-orange-50 rounded-lg border border-orange-200">
            <h3 className="font-medium text-orange-900 mb-4">新合約設定</h3>

            <div className="grid grid-cols-2 gap-4 mb-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">方案名稱</label>
                <input
                  type="text"
                  value={renewalForm.plan_name}
                  onChange={(e) => setRenewalForm(prev => ({ ...prev, plan_name: e.target.value }))}
                  className="input w-full"
                  placeholder="如：營業登記基本方案"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">月租金額</label>
                <input
                  type="number"
                  value={renewalForm.monthly_rent}
                  onChange={(e) => setRenewalForm(prev => ({ ...prev, monthly_rent: e.target.value }))}
                  className="input w-full"
                  placeholder="新合約月租"
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4 mb-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">起始日期</label>
                <input
                  type="date"
                  value={renewalForm.start_date}
                  onChange={(e) => setRenewalForm(prev => ({ ...prev, start_date: e.target.value }))}
                  className="input w-full"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">結束日期</label>
                <input
                  type="date"
                  value={renewalForm.end_date}
                  onChange={(e) => setRenewalForm(prev => ({ ...prev, end_date: e.target.value }))}
                  className="input w-full"
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4 mb-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">繳費週期</label>
                <select
                  value={renewalForm.payment_cycle}
                  onChange={(e) => setRenewalForm(prev => ({ ...prev, payment_cycle: e.target.value }))}
                  className="input w-full"
                >
                  <option value="monthly">月繳</option>
                  <option value="quarterly">季繳</option>
                  <option value="semi_annual">半年繳</option>
                  <option value="annual">年繳</option>
                </select>
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">座位編號</label>
                <input
                  type="text"
                  value={renewalForm.position_number}
                  onChange={(e) => setRenewalForm(prev => ({ ...prev, position_number: e.target.value }))}
                  className="input w-full"
                  placeholder="如：A1"
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">備註</label>
              <textarea
                value={renewalForm.notes}
                onChange={(e) => setRenewalForm(prev => ({ ...prev, notes: e.target.value }))}
                className="input w-full h-20 resize-none"
                placeholder="續約相關備註..."
              />
            </div>
          </div>

          {/* 按鈕區 */}
          <div className="flex justify-between pt-4 border-t">
            <div>
              {renewalDraft && (
                <button
                  onClick={handleCancelRenewalDraft}
                  disabled={renewalLoading}
                  className="btn-secondary text-red-600 hover:bg-red-50"
                >
                  <Trash2 className="w-4 h-4 mr-2" />
                  刪除草稿
                </button>
              )}
            </div>
            <div className="flex gap-3">
              <button
                onClick={() => setShowRenewalModal(false)}
                className="btn-secondary"
              >
                取消
              </button>
              <button
                onClick={handleSaveRenewalDraft}
                disabled={renewalLoading}
                className="btn-secondary"
              >
                {renewalLoading ? (
                  <Loader2 className="w-4 h-4 animate-spin mr-2" />
                ) : (
                  <Save className="w-4 h-4 mr-2" />
                )}
                {renewalDraft ? '更新草稿' : '儲存草稿'}
              </button>
              <button
                onClick={handleActivateRenewal}
                disabled={renewalLoading || !renewalDraft}
                className="btn-primary bg-orange-500 hover:bg-orange-600"
                title={!renewalDraft ? '請先儲存草稿' : '確認續約'}
              >
                {renewalLoading ? (
                  <Loader2 className="w-4 h-4 animate-spin mr-2" />
                ) : (
                  <CheckCircle className="w-4 h-4 mr-2" />
                )}
                確認續約
              </button>
            </div>
          </div>
        </div>
      </Modal>
    </div>
  )
}
