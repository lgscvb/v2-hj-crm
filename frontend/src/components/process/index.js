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

// 組件導出
export { default as DecisionPanel } from './DecisionPanel'
export { default as ProcessCard } from './ProcessCard'
export { default as ProcessTimeline } from './ProcessTimeline'
export { default as ProcessWorkspace } from './ProcessWorkspace'
export { default as ProcessKanban } from './ProcessKanban'

// Action 執行器
export { executeAction, hasAction, getAvailableActions } from './ActionDispatcher'

// 常量定義（從獨立檔案重新導出，避免循環依賴）
export {
  PROCESS_KEYS,
  PRIORITY_LEVELS,
  OWNER_ROLES,
  PRIORITY_COLORS,
  PROCESS_ICONS,
  OWNER_COLORS
} from './constants'
