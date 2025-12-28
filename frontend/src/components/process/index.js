/**
 * 流程引擎通用組件
 *
 * 這些組件用於統一所有流程（續約、簽署、解約、付款、發票、佣金）的 UI 呈現。
 *
 * 設計原則：
 * 1. 所有組件接收標準化的 Decision Table 資料
 * 2. 透過 action_key 映射到具體的業務操作
 * 3. 支援 Kanban 看板和 Workspace 兩種視圖
 */

import {
  RefreshCw,
  PenLine,
  LogOut,
  CreditCard,
  FileText,
  Banknote
} from 'lucide-react'

export { default as DecisionPanel } from './DecisionPanel'
export { default as ProcessCard } from './ProcessCard'
export { default as ProcessTimeline } from './ProcessTimeline'
export { default as ProcessWorkspace } from './ProcessWorkspace'

// Action 執行器
export { executeAction, hasAction, getAvailableActions } from './ActionDispatcher'

// 常量定義
export const PROCESS_KEYS = {
  RENEWAL: 'renewal',
  SIGNING: 'signing',
  TERMINATION: 'termination',
  PAYMENT: 'payment',
  INVOICE: 'invoice',
  COMMISSION: 'commission'
}

export const PRIORITY_LEVELS = {
  URGENT: 'urgent',
  HIGH: 'high',
  MEDIUM: 'medium',
  LOW: 'low'
}

export const OWNER_ROLES = {
  SALES: 'Sales',
  FINANCE: 'Finance',
  ADMIN: 'Admin',
  LEGAL: 'Legal'
}

// 優先級顏色映射
export const PRIORITY_COLORS = {
  urgent: {
    bg: 'bg-red-50',
    border: 'border-red-500',
    text: 'text-red-700',
    badge: 'bg-red-100 text-red-800'
  },
  high: {
    bg: 'bg-orange-50',
    border: 'border-orange-400',
    text: 'text-orange-700',
    badge: 'bg-orange-100 text-orange-800'
  },
  medium: {
    bg: 'bg-yellow-50',
    border: 'border-yellow-400',
    text: 'text-yellow-700',
    badge: 'bg-yellow-100 text-yellow-800'
  },
  low: {
    bg: 'bg-gray-50',
    border: 'border-gray-300',
    text: 'text-gray-600',
    badge: 'bg-gray-100 text-gray-800'
  }
}

// 流程圖示映射（使用 Lucide React 組件）
export const PROCESS_ICONS = {
  renewal: RefreshCw,
  signing: PenLine,
  termination: LogOut,
  payment: CreditCard,
  invoice: FileText,
  commission: Banknote
}

// 責任人顏色
export const OWNER_COLORS = {
  Sales: { bg: 'bg-blue-100', text: 'text-blue-800' },
  Finance: { bg: 'bg-green-100', text: 'text-green-800' },
  Admin: { bg: 'bg-purple-100', text: 'text-purple-800' },
  Legal: { bg: 'bg-red-100', text: 'text-red-800' }
}
