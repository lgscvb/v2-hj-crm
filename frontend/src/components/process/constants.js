/**
 * 流程引擎常量定義
 *
 * 獨立檔案避免循環依賴
 */

import {
  RefreshCw,
  PenLine,
  LogOut,
  CreditCard,
  FileText,
  Banknote
} from 'lucide-react'

// 流程類型
export const PROCESS_KEYS = {
  RENEWAL: 'renewal',
  SIGNING: 'signing',
  TERMINATION: 'termination',
  PAYMENT: 'payment',
  INVOICE: 'invoice',
  COMMISSION: 'commission'
}

// 優先級
export const PRIORITY_LEVELS = {
  URGENT: 'urgent',
  HIGH: 'high',
  MEDIUM: 'medium',
  LOW: 'low'
}

// 責任人角色
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

// 流程圖示映射
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
