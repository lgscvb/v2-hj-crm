# PRD v2.4 補充：解約流程（Termination Flow）

> 解約流程領域模型定義
> Version: 2.4
> Last Updated: 2024-12-25

---

## 1. 業務背景

### 1.1 解約類型

| 類型 | 說明 | 觸發時機 |
|------|------|----------|
| `not_renewing` | 到期不續約 | 合約到期前客戶通知不續 |
| `early` | 提前解約 | 合約期間提前終止 |
| `breach` | 違約終止 | 違反合約條款 |

### 1.2 核心業務邏輯：押金結算

**問題**：合約到期日不等於客戶實際搬離日

```
時間軸範例：

合約到期日          公文核准日
    │                  │
    ▼                  ▼
────┼─────────────────┼────────
12/1                12/20

扣除天數 = 12/20 - 12/1 = 19 天
日租金 = 月租 / 30
扣除金額 = 19 × 日租金
實際退還 = 押金 - 扣除金額 - 其他扣款
```

**為什麼需要等公文**：
- 客戶的稅籍登記地址在本場館
- 需要遷出稅籍才能正式終止
- 公文核准日 = 法律上的終止日

---

## 2. TerminationCase 領域模型

### 2.1 為什麼是獨立實體

```
TerminationCase 是 Process Manager（類似 RenewalCase）

Contract
├── 是不可變的法律文件
├── 不應存放流程追蹤欄位
└── 只記錄 status='pending_termination' 表示正在解約

TerminationCase
├── 追蹤解約流程狀態
├── 記錄各階段時間戳
├── 管理 Checklist 進度
└── 計算押金結算
```

### 2.2 狀態機

```
┌──────────────────────────────────────────────────────────────────┐
│                 TerminationCase State Machine                     │
│                                                                  │
│   [notice_received]                                              │
│         │                                                        │
│         └──UpdateStatus──→ [moving_out]                         │
│                                  │                               │
│                                  └──SubmitDoc──→ [pending_doc]  │
│                                                       │          │
│                                        ──ApproveDoc──→           │
│                                           [pending_settlement]   │
│                                                    │             │
│                                      ──ProcessRefund──→          │
│                                               [completed]        │
│                                                                  │
│   任何狀態 ──CancelCase──→ [cancelled]                          │
│                     (客戶反悔續租)                                │
└──────────────────────────────────────────────────────────────────┘
```

### 2.3 實體定義

```typescript
interface TerminationCase {
  id: string
  contract_id: string           // 依附的合約
  termination_type: 'early' | 'not_renewing' | 'breach'
  status: 'notice_received' | 'moving_out' | 'pending_doc' | 'pending_settlement' | 'completed' | 'cancelled'

  // 時間戳記錄
  notice_date: Date | null           // 客戶通知日
  expected_end_date: Date | null     // 預計搬離日
  actual_move_out: Date | null       // 實際搬離日
  doc_submitted_date: Date | null    // 公文送件日
  doc_approved_date: Date | null     // 公文核准日
  settlement_date: Date | null       // 結算日
  refund_date: Date | null           // 退款日
  cancelled_at: DateTime | null      // 取消時間

  // 押金結算
  deposit_amount: number             // 原始押金
  deduction_days: number             // 扣除天數
  daily_rate: number                 // 日租金
  deduction_amount: number           // 扣除金額
  other_deductions: number           // 其他扣款（清潔費等）
  other_deduction_notes: string      // 其他扣款說明
  refund_amount: number              // 實際退還

  // 退款資訊
  refund_method: 'cash' | 'transfer' | 'check' | null
  refund_account: string | null
  refund_receipt: string | null

  // Checklist
  checklist: {
    notice_confirmed: boolean        // 確認收到通知
    belongings_removed: boolean      // 物品搬離
    keys_returned: boolean           // 鑰匙歸還
    room_inspected: boolean          // 場地檢查
    doc_submitted: boolean           // 公文送件
    doc_approved: boolean            // 公文核准
    settlement_calculated: boolean   // 結算計算
    refund_processed: boolean        // 押金退還
  }

  // 取消
  cancel_reason: string | null

  // 系統欄位
  created_at: DateTime
  updated_at: DateTime
  created_by: string
}
```

### 2.4 Checklist 設計原則

```
8 個項目，分為 4 個階段：

階段 1: 通知收到
├── [1] notice_confirmed - 確認收到通知

階段 2: 搬遷作業
├── [2] belongings_removed - 物品搬離
├── [3] keys_returned - 鑰匙歸還
└── [4] room_inspected - 場地檢查

階段 3: 公文處理
├── [5] doc_submitted - 公文送件
└── [6] doc_approved - 公文核准

階段 4: 押金結算
├── [7] settlement_calculated - 結算計算
└── [8] refund_processed - 押金退還
```

---

## 3. 與 Contract 的關係

### 3.1 Contract 狀態更新

```
contracts.status 新增值：

| 狀態 | 說明 |
|------|------|
| pending_termination | 解約流程進行中 |

建立 TerminationCase 時：
- Contract.status → 'pending_termination'

完成 TerminationCase 時：
- Contract.status → 'terminated'
```

### 3.2 與 Payments 的關係

```
解約時的 Payments 處理：

已繳的 payments：保持 paid 狀態
未繳的 payments：標記為 cancelled（不是刪除）

cancelled_at = NOW()
cancel_reason = '合約解約'
```

---

## 4. 押金結算公式

### 4.1 標準公式

```sql
-- 計算扣除天數
deduction_days = GREATEST(0, doc_approved_date - contract_end_date)

-- 日租金
daily_rate = ROUND(monthly_rent / 30, 2)

-- 扣除金額
deduction_amount = deduction_days × daily_rate

-- 實際退還
refund_amount = deposit_amount - deduction_amount - other_deductions
```

### 4.2 範例計算

```
合約資訊：
- 押金：30,000
- 月租：15,000
- 到期日：2024-12-01
- 公文核准日：2024-12-20

計算：
- 扣除天數 = 20 - 1 = 19 天
- 日租金 = 15,000 / 30 = 500 元
- 扣除金額 = 19 × 500 = 9,500 元
- 實際退還 = 30,000 - 9,500 = 20,500 元
```

---

## 5. Commands（行為）

| Command | 觸發者 | 前置條件 | 結果 |
|---------|--------|----------|------|
| CreateTerminationCase | 櫃台 | Contract.status='active' | 建立案件，Contract.status='pending_termination' |
| UpdateTerminationStatus | 櫃台 | Case 存在且非完成 | 更新狀態 |
| UpdateChecklist | 櫃台 | Case 存在且非完成 | 更新 Checklist 項目 |
| CalculateSettlement | 櫃台 | status='pending_settlement' | 計算押金結算 |
| ProcessRefund | Manager | 結算已完成 | 記錄退款，status='completed' |
| CancelTermination | Manager | 非 completed 狀態 | status='cancelled'，Contract.status='active' |

---

## 6. UI 設計原則

### 6.1 解約管理頁面

```
┌─────────────────────────────────────────────────────────────────┐
│  解約管理                                                        │
├─────────────────────────────────────────────────────────────────┤
│  狀態篩選：[全部] [已通知] [搬遷中] [等待公文] [結算中] [已完成]   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 張三  |  V05  |  到期不續約  |  等待公文  |  ████████░░  │   │
│  │ 通知日: 12/01  預計搬離: 12/15           進度: 6/8      │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ 李四  |  A03  |  提前解約    |  結算中    |  ██████████  │   │
│  │ 通知日: 11/20  押金: $30,000  退還: $20,500            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 詳情 Modal

```
┌───────────────────────────────────────────────────────────────┐
│  解約詳情 - 張三 (V05)                              [X]       │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  基本資訊                                                     │
│  ├── 合約編號: HJ-2024-0156                                   │
│  ├── 解約類型: 到期不續約                                      │
│  ├── 通知日期: 2024-12-01                                     │
│  └── 預計搬離: 2024-12-15                                     │
│                                                               │
│  Checklist                                                    │
│  ├── ☑ 確認收到通知                                          │
│  ├── ☑ 物品搬離                                               │
│  ├── ☑ 鑰匙歸還                                               │
│  ├── ☑ 場地檢查                                               │
│  ├── ☑ 公文送件                                               │
│  ├── ☐ 公文核准        ← 待完成                               │
│  ├── ☐ 結算計算                                               │
│  └── ☐ 押金退還                                               │
│                                                               │
│  [更新狀態]  [計算結算]  [取消解約]                            │
└───────────────────────────────────────────────────────────────┘
```

---

## 7. 與其他領域的關係

```
┌─────────────────────────────────────────────────────────────────┐
│                        Hour Jungle CRM                          │
│                                                                 │
│  ┌─────────────┐      ┌─────────────────────────────────────┐  │
│  │  Customer   │      │          Contract Context           │  │
│  │  Context    │ ───→ │  (核心：生命週期管理)                │  │
│  │  (身分容器) │      │                                     │  │
│  └─────────────┘      │  ┌───────────┐  ┌───────────────┐   │  │
│                       │  │  Billing  │  │   Renewal     │   │  │
│                       │  │  子域     │  │   子域        │   │  │
│                       │  └───────────┘  └───────────────┘   │  │
│                       │                                     │  │
│                       │  ┌───────────────────────────────┐  │  │
│                       │  │        Termination 子域        │  │  │
│                       │  │      （解約流程管理）          │  │  │
│                       │  └───────────────────────────────┘  │  │
│                       └─────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 8. 資料庫 Schema

```sql
-- 已實作於 036_termination_cases.sql

CREATE TABLE termination_cases (
    id              SERIAL PRIMARY KEY,
    contract_id     INTEGER NOT NULL REFERENCES contracts(id),
    termination_type VARCHAR(20) DEFAULT 'not_renewing',
    status          VARCHAR(20) DEFAULT 'notice_received',

    -- 時間戳
    notice_date         DATE,
    expected_end_date   DATE,
    actual_move_out     DATE,
    doc_submitted_date  DATE,
    doc_approved_date   DATE,
    settlement_date     DATE,
    refund_date         DATE,
    cancelled_at        TIMESTAMPTZ,

    -- 押金結算
    deposit_amount      NUMERIC(10,2),
    deduction_days      INTEGER DEFAULT 0,
    daily_rate          NUMERIC(10,2),
    deduction_amount    NUMERIC(10,2),
    other_deductions    NUMERIC(10,2) DEFAULT 0,
    other_deduction_notes TEXT,
    refund_amount       NUMERIC(10,2),

    -- 退款資訊
    refund_method       VARCHAR(20),
    refund_account      TEXT,
    refund_receipt      TEXT,

    -- Checklist
    checklist           JSONB DEFAULT '{...}'::jsonb,

    -- 備註
    notes               TEXT,
    cancel_reason       TEXT,

    -- 系統欄位
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    created_by      TEXT,

    -- 約束
    CONSTRAINT unique_active_termination
        EXCLUDE (contract_id WITH =)
        WHERE (status NOT IN ('completed', 'cancelled'))
);
```

---

## 9. 與 RenewalCase 的對比

| 項目 | RenewalCase | TerminationCase |
|------|-------------|-----------------|
| 目的 | 追蹤續約流程 | 追蹤解約流程 |
| 觸發 | 合約到期前 45 天 | 客戶通知不續約 |
| Checklist | 5 項（通知、確認、繳費、開票、簽約） | 8 項（通知、搬遷、公文、結算） |
| 結果 | 產生新合約 | 合約終止 + 押金退還 |
| 關鍵欄位 | new_contract_id | refund_amount |

---

## 下一步

1. **更新 SSD** - 新增 Termination Domain 序列圖
2. **實作測試** - 驗證完整流程
3. **整合 AI** - 讓 AI 助手可查詢/操作解約案件
