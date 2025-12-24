# PRD v2.1 補充：領域模型修訂

> 基於 PRD v2.0 審閱意見的修訂補充
> Version: 2.1
> Last Updated: 2024-12-22

---

## 1. 核心洞察：Contract 是系統中心

### 1.1 原有假設（錯誤）

```
Customer 是中心
├── Customer 有多份合約
├── Customer 要繳費
└── Customer 要續約
```

### 1.2 修正後的模型

```
Contract 是中心（生命週期驅動一切）
├── Contract 屬於 Customer（身分容器）
├── Contract 產生 Payment（應收款）
├── Contract 觸發 Renewal（續約流程）
└── Contract 關聯 Invoice（帳務結果）
```

**關鍵差異**：
- 不是「客戶要繳錢」，是「合約產生了一期應收款」
- 不是「客戶要續約」，是「合約進入續約流程」

---

## 2. Bounded Context 定義

### 2.1 Context Map

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
│                       └─────────────────────────────────────┘  │
│                                    │                            │
│                                    ▼                            │
│                       ┌─────────────────────────────────────┐  │
│                       │        Invoice Context              │  │
│                       │        (帳務結果)                   │  │
│                       └─────────────────────────────────────┘  │
│                                                                 │
│  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐     │
│  │  Resource   │      │  Booking    │      │  Analytics  │     │
│  │  Context    │      │  Context    │      │  Context    │     │
│  │  (座位/地址)│      │  (會議室)   │      │  (報表)     │     │
│  └─────────────┘      └─────────────┘      └─────────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 各 Context 職責

| Context | 職責 | Aggregate Root |
|---------|------|----------------|
| Customer | 客戶身分、聯絡方式 | Customer |
| Contract | 服務關係生命週期 | Contract |
| Billing | 收款流程管理 | Payment |
| Renewal | 續約流程管理 | RenewalCase |
| Invoice | 發票開立與管理 | Invoice |
| Resource | 座位/地址管理 | Resource |
| Booking | 會議室預約 | Booking |
| Analytics | 報表（唯讀） | - |

---

## 3. 流程型需求重新定義

### 3.1 Billing Flow（收款流程）

**這是一個流程，不是 CRUD！**

```
┌──────────────────────────────────────────────────────────────┐
│                    Billing Flow State Machine                │
│                                                              │
│   [pending] ──RecordPayment──→ [paid]                       │
│       │                           │                          │
│       │                           └──UndoPayment──→ [pending]│
│       │                                                      │
│       └──────WaivePayment──────→ [waived]                   │
│       │                                                      │
│       └──(due_date passed)──→ [overdue]                     │
│                                    │                         │
│                                    └──RecordPayment──→ [paid]│
└──────────────────────────────────────────────────────────────┘
```

**Commands（行為）**：

| Command | 觸發者 | 前置條件 | 結果 |
|---------|--------|----------|------|
| RecordPayment | 櫃台 | status=pending/overdue | status=paid, paid_at 記錄 |
| WaivePayment | Manager | status=pending/overdue, 有原因 | status=waived |
| UndoPayment | Manager | status=paid, 有原因 | status=pending |
| SendReminder | 櫃台 | status=pending/overdue | 發送 LINE，記錄 log |

**Source of Truth**：
- `status` 由 Command 結果決定，不可手動修改
- `paid_at` 是 RecordPayment 的副產物
- `overdue` 由排程任務根據 `due_date` 自動標記

### 3.2 Renewal Flow（續約流程）

**這是一個 Process Manager（Saga）**

```
┌──────────────────────────────────────────────────────────────┐
│                  RenewalCase State Machine                   │
│                                                              │
│   [created] ──SendNotification──→ [notified]                │
│                                        │                     │
│                         ──ConfirmIntent──→ [confirmed]      │
│                                                │              │
│                                    ──RecordPayment──→ [paid] │
│                                                      │       │
│                                          ──IssueInvoice──→   │
│                                                    [invoiced]│
│                                                         │    │
│                                              ──SignContract──│
│                                                    [completed]│
└──────────────────────────────────────────────────────────────┘
```

**RenewalCase 實體**：

```typescript
interface RenewalCase {
  id: string
  contract_id: string           // 依附的合約
  status: 'created' | 'notified' | 'confirmed' | 'paid' | 'invoiced' | 'completed' | 'cancelled'

  // 時間戳記錄（不是 boolean！）
  notified_at: DateTime | null
  confirmed_at: DateTime | null
  paid_at: DateTime | null
  invoiced_at: DateTime | null
  signed_at: DateTime | null

  // 結果關聯
  new_contract_id: string | null  // 續約產生的新合約
}
```

**為什麼是獨立實體**：
- 不屬於舊合約（舊合約是不可變的法律文件）
- 不屬於新合約（新合約還沒簽）
- 是一個「跨越多個步驟的流程追蹤器」

---

## 4. 資料模型修訂

### 4.1 Resource 表（P0 必須）

```sql
-- 座位/地址/會議室的統一管理
CREATE TABLE resources (
  id SERIAL PRIMARY KEY,
  branch_id INT REFERENCES branches(id),
  resource_type VARCHAR(20) NOT NULL, -- 'seat', 'address', 'meeting_room'
  name VARCHAR(100) NOT NULL,         -- 'A01', '台北市信義區...'
  status VARCHAR(20) DEFAULT 'available', -- 'available', 'occupied'
  metadata JSONB,                      -- 額外屬性
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 合約關聯資源
ALTER TABLE contracts ADD COLUMN resource_id INT REFERENCES resources(id);
```

**P1 的平面圖只是 UI**，資料結構 P0 就要有。

### 4.2 快照欄位

```sql
-- Contracts 快照（簽約當下的客戶資料）
ALTER TABLE contracts ADD COLUMN snapshot_customer_name VARCHAR(100);
ALTER TABLE contracts ADD COLUMN snapshot_company_name VARCHAR(100);
ALTER TABLE contracts ADD COLUMN snapshot_tax_id VARCHAR(20);
ALTER TABLE contracts ADD COLUMN snapshot_address TEXT;

-- Invoices 快照（開票當下的客戶資料）
ALTER TABLE invoices ADD COLUMN snapshot_company_name VARCHAR(100);
ALTER TABLE invoices ADD COLUMN snapshot_tax_id VARCHAR(20);
```

**規則**：簽約/開票時，從 Customer 複製一份，之後客戶改名不影響歷史記錄。

### 4.3 RenewalCase 表

```sql
CREATE TABLE renewal_cases (
  id SERIAL PRIMARY KEY,
  contract_id INT REFERENCES contracts(id),
  status VARCHAR(20) DEFAULT 'created',

  notified_at TIMESTAMPTZ,
  confirmed_at TIMESTAMPTZ,
  paid_at TIMESTAMPTZ,
  invoiced_at TIMESTAMPTZ,
  signed_at TIMESTAMPTZ,

  new_contract_id INT REFERENCES contracts(id), -- 續約產生的新合約

  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 索引：快速找出「進行中」的續約
CREATE INDEX idx_renewal_cases_status ON renewal_cases(status) WHERE status != 'completed';
```

---

## 5. 權限與稽核修訂

### 5.1 高風險操作權限

| 操作 | 櫃台 (Service) | 經理 (Manager) | 管理員 (Admin) |
|------|----------------|----------------|----------------|
| RecordPayment | ✅ | ✅ | ✅ |
| WaivePayment | ❌ 申請 | ✅ 核准 | ✅ 核准 |
| UndoPayment | ❌ | ✅ | ✅ |
| 終止合約 | ❌ | ✅ | ✅ |
| 修改價格方案 | ❌ | ❌ | ✅ |

### 5.2 免收流程（新增）

```gherkin
US-NEW: 免收需要主管核准

Flow:
1. 櫃台點擊「申請免收」
2. 填寫原因（必填）
3. 系統建立 WaiveRequest (status=pending)
4. Manager 在「待審核」列表看到
5. Manager 核准/駁回
6. 核准後 Payment.status = waived

Audit Log:
- 誰申請
- 誰核准
- 什麼時間
- 原因
```

---

## 6. 批量操作的失敗模型

### 6.1 設計原則

```
批量操作 ≠ 多筆單筆操作的 for loop
批量操作 = 一個「批次任務」，有獨立狀態
```

### 6.2 BatchTask 實體

```typescript
interface BatchTask {
  id: string
  type: 'send_reminder' | 'send_renewal_notice'
  status: 'pending' | 'processing' | 'completed' | 'partial_success' | 'failed'

  total_count: number
  success_count: number
  failed_count: number

  items: BatchTaskItem[]

  created_by: string
  created_at: DateTime
  completed_at: DateTime | null
}

interface BatchTaskItem {
  target_id: string  // payment_id 或 contract_id
  status: 'pending' | 'success' | 'failed'
  error_message: string | null
}
```

### 6.3 UI 呈現

```
批量催繳結果：
┌────────────────────────────────────────┐
│  ✅ 成功 8 筆                          │
│  ❌ 失敗 2 筆                          │
│                                        │
│  失敗清單：                            │
│  • 王小明 - LINE 未綁定                │
│  • 李大華 - 訊息發送超時               │
│                                        │
│  [重試失敗項目]  [關閉]                │
└────────────────────────────────────────┘
```

---

## 7. Invoice 與 Payment 的關係

### 7.1 修訂後的模型

```
Invoice 不強依賴 Payment

Payment (應收款)
├── 可以沒有 Invoice（現金不需開票）
└── 可以對應多張 Invoice（分期開票）

Invoice (發票)
├── 可以先開票後收款（B2B 請款）
└── 可以對應多筆 Payment（多筆合併一張票）
```

### 7.2 MVP 簡化版

```sql
-- MVP: 一對一關係，但用關聯表預留彈性
CREATE TABLE payment_invoices (
  payment_id INT REFERENCES payments(id),
  invoice_id INT REFERENCES invoices(id),
  PRIMARY KEY (payment_id, invoice_id)
);
```

---

## 8. 前端 State 設計原則

### 8.1 錯誤模式（現狀）

```javascript
// ❌ 7 個獨立的 Modal 狀態
const [showPayModal, setShowPayModal] = useState(false)
const [showReminderModal, setShowReminderModal] = useState(false)
const [showUndoModal, setShowUndoModal] = useState(false)
// ... 4 more
```

### 8.2 正確模式

```javascript
// ✅ 以 Contract 為中心的狀態
const [currentAction, setCurrentAction] = useState<{
  contractId: string
  type: 'pay' | 'remind' | 'undo' | 'waive' | null
  status: 'idle' | 'confirming' | 'processing' | 'success' | 'error'
}>({ contractId: null, type: null, status: 'idle' })

// 開啟 Modal
const openAction = (contractId, type) =>
  setCurrentAction({ contractId, type, status: 'confirming' })

// 執行操作
const executeAction = async () => {
  setCurrentAction(prev => ({ ...prev, status: 'processing' }))
  try {
    await api.billing[currentAction.type](currentAction.contractId)
    setCurrentAction(prev => ({ ...prev, status: 'success' }))
  } catch (e) {
    setCurrentAction(prev => ({ ...prev, status: 'error' }))
  }
}
```

### 8.3 Derived State 規則

```
❌ 禁止：同時存在 payment.status 和 payment.isPaid
✅ 正確：只有 payment.status，UI 用 status === 'paid' 判斷
```

---

## 9. 待補充的 User Flow

### 9.1 LINE ID 綁定流程（隱藏需求）

```
1. 客戶收到 LINE 訊息
2. 訊息包含「綁定帳號」按鈕
3. 客戶點擊 → 開啟 LIFF 頁面
4. 輸入手機或 Email 驗證
5. 系統關聯 LINE User ID 與 Customer ID
6. 之後的通知可以直接發送
```

### 9.2 繳費週期產生邏輯

```
選項 A：固定日期（每月 1 號）
選項 B：依合約起始日（15 號簽約，每月 15 號繳）

建議：選項 B，更符合實際業務
```

---

## 10. 修訂總結

| 項目 | 原 PRD | 修訂後 |
|------|--------|--------|
| 核心概念 | Customer 中心 | Contract 中心 |
| 續約追蹤 | Contract 欄位 | RenewalCase 獨立實體 |
| 座位管理 | P1 | P0 資料結構 + P1 UI |
| 免收權限 | 無限制 | 需 Manager 核准 |
| 批量操作 | 未定義 | BatchTask 模型 |
| Invoice/Payment | 強依賴 | 多對多關係 |
| 狀態來源 | 多重 | 單一 Source of Truth |

---

## 下一步

1. **更新主 PRD** - 將以上修訂合併
2. **畫 SSD** - 以 Contract 為主角，定義 API
3. **實作 DDD** - 按 Bounded Context 重構程式碼
4. **清理技術債** - 修復 7 Modal 問題
