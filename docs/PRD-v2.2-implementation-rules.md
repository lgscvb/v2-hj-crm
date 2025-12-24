# PRD v2.2 補充：實作規則與邊緣案例

> 基於 v2.1 審閱意見的實作層面補充
> Version: 2.2
> Last Updated: 2024-12-22

---

## 1. 命令識別規則 (Command Identification)

### 1.1 核心原則

```
「Contract 是中心」的正確解讀：
├── Contract 是「查詢與導航」的中心
├── Contract 不是「命令執行」的中心
└── 命令仍以各子域 Aggregate Root 為主鍵
```

### 1.2 各 Context 的命令識別

| Context | Aggregate Root | Command Input |
|---------|----------------|---------------|
| Billing | Payment | `payment_id` (必要) |
| Renewal | RenewalCase | `renewal_case_id` (必要) |
| Invoice | Invoice | `invoice_id` (必要) |
| Booking | Booking | `booking_id` (必要) |

### 1.3 API 設計範例

```
Billing Commands:
  POST /payments/{paymentId}/record     ← 記錄繳費
  POST /payments/{paymentId}/waive      ← 申請免收
  POST /payments/{paymentId}/undo       ← 撤銷繳費
  POST /payments/{paymentId}/remind     ← 發送催繳

Renewal Commands:
  POST /renewal-cases/{caseId}/notify   ← 發送通知
  POST /renewal-cases/{caseId}/confirm  ← 確認意願
  POST /renewal-cases/{caseId}/cancel   ← 取消續約

Invoice Commands:
  POST /invoices/{invoiceId}/issue      ← 開立發票
  POST /invoices/{invoiceId}/void       ← 作廢發票
```

### 1.4 前端 State 修正

```javascript
// ❌ 錯誤：用 contractId
const [currentAction, setCurrentAction] = useState({
  contractId: null,  // 錯誤
  type: null,
  status: 'idle'
})

// ✅ 正確：用對應的 AR ID
const [currentAction, setCurrentAction] = useState<{
  targetId: string      // payment_id, renewal_case_id, etc.
  targetType: 'payment' | 'renewal_case' | 'invoice'
  actionType: 'record' | 'waive' | 'undo' | 'remind' | ...
  status: 'idle' | 'confirming' | 'processing' | 'success' | 'error'
} | null>(null)

// 執行操作
const executeAction = async () => {
  const { targetId, targetType, actionType } = currentAction
  await api[targetType][actionType](targetId)
}
```

---

## 2. Overdue 狀態規則

### 2.1 狀態類型定義

```
Overdue 是 Persisted Transition（持久化轉換）
├── 不是每次查詢時 derived
├── 由排程任務明確標記
└── 可被特定事件回復
```

### 2.2 狀態轉換規則

```
┌─────────────────────────────────────────────────────────────┐
│                    Payment 完整狀態轉換                     │
│                                                             │
│  [pending] ──(due_date passed)──→ [overdue]                │
│      │                                 │                    │
│      │                                 │                    │
│      ├──(RecordPayment)──→ [paid]      │                    │
│      │                        │        │                    │
│      │                        │        ├──(RecordPayment)──→ [paid]
│      │                        │        │                    │
│      │                        │        ├──(WaivePayment)───→ [waived]
│      │                        │        │                    │
│      ├──(WaivePayment)───→ [waived]    │                    │
│      │                                 │                    │
│      ├──(TerminateContract)──→ [cancelled]  ←───────────────┘
│      │                                                      │
│      └──(due_date 修正到未來)─────────→ [pending]          │
│                                                             │
│  [paid] ──(UndoPayment)──→ [pending] 或 [overdue]          │
│                             (依據當前 due_date 判斷)        │
│                                                             │
│  [cancelled] 是終態，不可恢復（保留審計紀錄）              │
└─────────────────────────────────────────────────────────────┘
```

> **v1.1 新增**：`cancelled` 狀態用於合約終止時的待繳款。
> - 不是 DELETE，而是標記狀態
> - 保留 `cancelled_at` 和 `cancel_reason`
> - 可追溯為何取消

### 2.3 排程任務定義

```python
# 每日凌晨 00:05 執行
def mark_overdue_payments():
    """
    將逾期的待繳款標記為 overdue
    """
    UPDATE payments
    SET status = 'overdue',
        overdue_marked_at = NOW()
    WHERE status = 'pending'
      AND due_date < CURRENT_DATE

# 同時：修正 due_date 後的回復
def restore_pending_if_due_date_extended():
    """
    若 due_date 被延後到未來，將 overdue 改回 pending
    """
    UPDATE payments
    SET status = 'pending',
        overdue_marked_at = NULL
    WHERE status = 'overdue'
      AND due_date >= CURRENT_DATE
```

### 2.4 UndoPayment 後的狀態判斷

```python
def undo_payment(payment_id: int):
    payment = get_payment(payment_id)

    # 撤銷繳費
    payment.status = 'pending' if payment.due_date >= today() else 'overdue'
    payment.paid_at = None
    payment.payment_method = None

    # 記錄撤銷原因
    create_audit_log(
        action='undo_payment',
        target_id=payment_id,
        reason=request.reason,
        operator=current_user
    )
```

---

## 3. Invoice 不可變規則與 MVP 約束

### 3.1 Invoice 不可變原則

```
發票一旦 issued：
├── 不可修改任何欄位（金額、抬頭、統編）
├── 若需修正 → 必須作廢後重新開立
└── 作廢紀錄永久保留
```

### 3.2 Invoice 狀態機

```
┌─────────────────────────────────────────────────────────────┐
│                    Invoice 狀態機                           │
│                                                             │
│  [pending] ──(IssueInvoice)──→ [issued]                    │
│                                    │                        │
│                                    ├──(VoidInvoice)──→ [voided]
│                                    │                        │
│                                    └──(自動)──→ [synced_to_tax]
│                                                 (已上傳國稅局)│
│                                                             │
│  [voided] ──(ReissueInvoice)──→ [issued] (新的 Invoice)    │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 MVP 約束

```
MVP 階段限制：
├── 1 Payment ↔ 0..1 Invoice（一對一或無發票）
├── 不支援「先開票後收款」（B2B 請款流程延後實作）
├── 不支援「多筆 Payment 合併一張 Invoice」
└── 作廢後重開視為新 Invoice（有新 invoice_id）

資料結構預留：
├── payment_invoices 關聯表（MVP 時一對一）
└── Invoice 獨立狀態（不依賴 Payment.status）
```

### 3.4 Invoice 與 Payment 的關係

```
關鍵規則：Invoice 狀態與 Payment 狀態「互不硬綁」

場景 1：Payment=paid, Invoice=voided
  → 合法（收到錢但發票作廢重開）

場景 2：Payment=pending, Invoice=issued
  → MVP 不支援，Phase 2 支援（B2B 請款）

場景 3：Payment=waived, Invoice=?
  → 免收通常不開票，但若已開票需作廢
```

---

## 4. WaiveRequest 審批流程

### 4.1 完整狀態機

```
┌─────────────────────────────────────────────────────────────┐
│                  WaiveRequest 狀態機                        │
│                                                             │
│  [pending] ──(ApproveWaive)──→ [approved]                  │
│      │                              │                       │
│      │                              └──→ Payment.waived     │
│      │                                                      │
│      └──(RejectWaive)──→ [rejected]                        │
│                              │                              │
│                              └──→ Payment 狀態不變          │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 一致性規則

```python
def create_waive_request(payment_id: int, reason: str):
    payment = get_payment(payment_id)

    # 前置條件檢查
    if payment.status not in ['pending', 'overdue']:
        raise ValidationError("只有待繳或逾期款項可申請免收")

    # 檢查是否已有 pending 的 request
    existing = get_pending_waive_request(payment_id)
    if existing:
        raise ValidationError("此款項已有待審核的免收申請")

    # 建立申請
    return WaiveRequest.create(
        payment_id=payment_id,
        reason=reason,
        requested_by=current_user,
        status='pending'
    )

def approve_waive_request(request_id: int):
    request = get_waive_request(request_id)
    payment = get_payment(request.payment_id)

    # Idempotency 檢查
    if request.status != 'pending':
        raise ValidationError("此申請已處理")

    # 再次檢查 Payment 狀態（防並發）
    if payment.status not in ['pending', 'overdue']:
        request.status = 'rejected'
        request.reject_reason = "款項狀態已變更"
        raise ValidationError("款項狀態已變更，無法核准")

    # 執行免收
    with transaction():
        payment.status = 'waived'
        payment.waived_at = now()
        payment.waived_by = current_user
        payment.waive_reason = request.reason

        request.status = 'approved'
        request.approved_by = current_user
        request.approved_at = now()
```

### 4.3 Reject 後的處理

```
Reject 規則：
├── WaiveRequest 保留（status=rejected）
├── 記錄 reject_reason 和 rejected_by
├── Payment 狀態不變
└── 櫃台可重新申請（建立新的 WaiveRequest）
```

---

## 5. Resource 占用模型

### 5.1 資源類型與占用模型分離

```sql
-- Resources 表：統一管理
CREATE TABLE resources (
  id SERIAL PRIMARY KEY,
  branch_id INT REFERENCES branches(id),
  resource_type VARCHAR(20) NOT NULL, -- 'seat', 'address', 'meeting_room'
  name VARCHAR(100) NOT NULL,

  -- status 只表示「是否啟用」，不表示「是否被占用」
  status VARCHAR(20) DEFAULT 'active', -- 'active', 'inactive', 'maintenance'

  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 資源預留表：用於續約流程預留座位
CREATE TABLE resource_reservations (
  id SERIAL PRIMARY KEY,
  resource_id INT REFERENCES resources(id),
  renewal_case_id INT REFERENCES renewal_cases(id),
  reserved_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ, -- 預留過期時間
  status VARCHAR(20) DEFAULT 'active', -- 'active', 'released', 'converted'
  UNIQUE(resource_id, renewal_case_id)
);
```

> **重要**：`resources.status` 只表示「啟用/停用」，不代表占用狀態。
> - 座位占用 = 查 contracts 表
> - 預留占用 = 查 resource_reservations 表
> - 會議室占用 = 查 bookings 表時段

### 5.2 座位/地址的占用（Contract 綁定）

```sql
-- 座位/地址的占用 = 有 active contract 關聯
-- 查詢可用座位：
SELECT r.*
FROM resources r
WHERE r.resource_type IN ('seat', 'address')
  AND r.status = 'active'
  AND NOT EXISTS (
    SELECT 1 FROM contracts c
    WHERE c.resource_id = r.id
      AND c.status = 'active'
  );
```

### 5.3 會議室的占用（Booking 時段）

```sql
-- 會議室的占用 = 有 booking 時段重疊
-- 查詢某時段可用會議室：
SELECT r.*
FROM resources r
WHERE r.resource_type = 'meeting_room'
  AND r.status = 'active'
  AND NOT EXISTS (
    SELECT 1 FROM bookings b
    WHERE b.resource_id = r.id
      AND b.status != 'cancelled'
      AND b.date = :target_date
      AND (
        (b.start_time <= :target_start AND b.end_time > :target_start) OR
        (b.start_time < :target_end AND b.end_time >= :target_end) OR
        (b.start_time >= :target_start AND b.end_time <= :target_end)
      )
  );
```

### 5.4 Resource.status 語意

| status | 意義 | seat/address | meeting_room |
|--------|------|--------------|--------------|
| active | 可使用 | 可出租 | 可預約 |
| inactive | 停用 | 不可出租 | 不可預約 |
| maintenance | 維護中 | 暫停出租 | 暫停預約 |

**重要**：`status` 不等於「是否被占用」

---

## 6. 並發控制 (Concurrency)

### 6.1 座位搶占問題

**情境**：兩個櫃台同時幫不同客戶簽約，選了同一個座位 A01

**解法 A：資料庫 Unique Constraint**

```sql
-- 確保同一資源同時只有一份 active contract
CREATE UNIQUE INDEX idx_resource_active_contract
ON contracts (resource_id)
WHERE status = 'active';
```

**解法 B：樂觀鎖 (Optimistic Lock)**

```python
def create_contract_with_resource(customer_id, resource_id, ...):
    with transaction():
        # 檢查資源是否可用
        resource = get_resource_for_update(resource_id)  # SELECT FOR UPDATE

        if has_active_contract(resource_id):
            raise ValidationError("此座位已被租用")

        contract = Contract.create(
            customer_id=customer_id,
            resource_id=resource_id,
            ...
        )
        return contract
```

### 6.2 建議採用

```
MVP：使用 Unique Constraint（簡單有效）
Phase 2：若需要更細緻控制，加上 SELECT FOR UPDATE
```

---

## 7. 續約反悔機制

### 7.1 RenewalCase Cancel 流程

```
┌─────────────────────────────────────────────────────────────┐
│                RenewalCase 含 Cancel 的狀態機               │
│                                                             │
│  [created] ──→ [notified] ──→ [confirmed] ──→ [paid] ──→   │
│      │             │              │            │            │
│      │             │              │            │            │
│      └─────────────┴──────────────┴────────────┘            │
│                         │                                   │
│                         ↓                                   │
│                   [cancelled]                               │
│                         │                                   │
│                         └──→ 釋放預留資源（若有）           │
│                         └──→ 發送 Domain Event             │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 Cancel 時的副作用

```python
def cancel_renewal_case(case_id: int, reason: str):
    case = get_renewal_case(case_id)

    if case.status == 'completed':
        raise ValidationError("已完成的續約無法取消")

    with transaction():
        # 1. 更新狀態
        case.status = 'cancelled'
        case.cancelled_at = now()
        case.cancel_reason = reason

        # 2. 若有預留資源，釋放
        if case.reserved_resource_id:
            release_resource_reservation(case.reserved_resource_id)

        # 3. 若已產生新合約草稿，作廢
        if case.new_contract_id:
            new_contract = get_contract(case.new_contract_id)
            if new_contract.status == 'draft':
                new_contract.status = 'cancelled'

        # 4. 發送 Domain Event
        emit_event(RenewalCaseCancelled(
            case_id=case_id,
            contract_id=case.contract_id,
            reason=reason
        ))
```

---

## 8. 批量操作的 UX

### 8.1 進度追蹤方式

```
MVP：輪詢 (Polling)
├── 建立 BatchTask 後返回 task_id
├── 前端每 2 秒呼叫 GET /batch-tasks/{taskId}
└── 直到 status = completed | partial_success | failed

Phase 2：WebSocket
├── 建立 BatchTask 後訂閱 ws://batch-tasks/{taskId}
└── 即時收到進度更新
```

### 8.2 API 設計

```
# 建立批量任務
POST /batch-tasks
{
  "type": "send_reminder",
  "target_ids": ["payment-1", "payment-2", "payment-3"]
}

Response:
{
  "task_id": "batch-123",
  "status": "processing",
  "total_count": 3,
  "success_count": 0,
  "failed_count": 0
}

# 查詢進度
GET /batch-tasks/batch-123

Response:
{
  "task_id": "batch-123",
  "status": "partial_success",
  "total_count": 3,
  "success_count": 2,
  "failed_count": 1,
  "items": [
    { "target_id": "payment-1", "status": "success" },
    { "target_id": "payment-2", "status": "success" },
    { "target_id": "payment-3", "status": "failed", "error": "LINE 未綁定" }
  ]
}
```

### 8.3 前端實作

```javascript
const useBatchTask = (taskId) => {
  const [task, setTask] = useState(null)

  useEffect(() => {
    if (!taskId) return

    const poll = async () => {
      const result = await api.getBatchTask(taskId)
      setTask(result)

      if (result.status === 'processing') {
        setTimeout(poll, 2000)  // 2 秒後再查
      }
    }

    poll()
  }, [taskId])

  return task
}

// 使用
const BatchReminderModal = ({ paymentIds }) => {
  const [taskId, setTaskId] = useState(null)
  const task = useBatchTask(taskId)

  const handleStart = async () => {
    const { task_id } = await api.createBatchTask('send_reminder', paymentIds)
    setTaskId(task_id)
  }

  return (
    <Modal>
      {!taskId && <Button onClick={handleStart}>開始發送</Button>}
      {task && (
        <div>
          <Progress value={task.success_count + task.failed_count} max={task.total_count} />
          <p>成功 {task.success_count} / 失敗 {task.failed_count}</p>
          {task.status !== 'processing' && (
            <FailedItemsList items={task.items.filter(i => i.status === 'failed')} />
          )}
        </div>
      )}
    </Modal>
  )
}
```

---

## 9. 總結清單

### v2.2 核心補充（6 條規則）

| # | 規則 | 說明 |
|---|------|------|
| 1 | Billing commands 的最小識別 input | `payment_id`（contract_id 作為驗證/查詢上下文） |
| 2 | Overdue 是 persisted | 由排程標記，可被 due_date 修正或 UndoPayment 回復 |
| 3 | Invoice 不可變 | issued 後只能 void；MVP 為 1:0..1 |
| 4 | WaiveRequest 一致性 | approve 前再檢查 payment 狀態；reject 後保留紀錄 |
| 5 | Resource.status 語意 | 只表示啟用/停用；meeting_room 可用性由 booking 計算 |
| 6 | Contract 是中心的意思 | 查詢與導航中心；命令仍以各子域 AR 為主 |

### 邊緣案例處理

| 案例 | 解法 |
|------|------|
| 座位搶占 | Unique Constraint on (resource_id) WHERE status='active' |
| 續約反悔 | RenewalCase.Cancel() + 釋放資源 + Domain Event |
| 批量進度 | MVP 用 Polling，Phase 2 用 WebSocket |
