# Bug 修復計劃

> 日期：2025-12-29
> 來源：Code Review + 用戶回報

---

## P0 - 立即修復（影響功能）

### 1. ActionDispatcher SEND_REMINDER 工具名稱錯誤

**問題**：
- 位置：`frontend/src/components/process/ActionDispatcher.js:111`
- 呼叫 `send_payment_reminder` 但後端沒有這個工具
- 後端只有 `line_send_payment_reminder` 或 `billing_send_reminder`

**修復**：
```javascript
// ActionDispatcher.js line 111
SEND_REMINDER: async (paymentId, payload) => {
  return callTool('billing_send_reminder', {  // 改用 billing_send_reminder
    payment_id: paymentId
  })
}
```

---

### 2. 發票作廢狀態不一致（void vs voided）

**問題**：
- `058_invoice_workspace.sql:125` 判斷 `invoice_status = 'void'`
- `invoice_tools.py:386` 寫入 `"invoice_status": "voided"`
- 導致「待重開」狀態永遠不會出現

**修復方案 A**（改 SQL）：
```sql
-- 058_invoice_workspace.sql line 125
WHEN p.invoice_status = 'voided'  -- 改成 voided
THEN 'need_reissue'
```

**修復方案 B**（改 Python）：
```python
# invoice_tools.py line 386
"invoice_status": "void"  # 改成 void
```

**建議**：採用方案 A，因為 `voided` 更符合英文語法（過去分詞表示已完成的動作）

---

### 3. DZ-112 Checkbox 邏輯錯誤（fallback 問題）

**問題**：
- 位置：`frontend/src/pages/Renewals.jsx:60`
- `is_first_payment_paid` 是 `false`（不是 null），所以不會 fallback 到 `renewal_paid_at`

**現狀**：
```javascript
is_paid: contract.is_first_payment_paid ?? !!contract.renewal_paid_at
```

**修復**：
```javascript
// 使用 || 而非 ??，這樣 false 也會 fallback
is_paid: contract.is_first_payment_paid || !!contract.renewal_paid_at
```

**或者更完整的修復**（改視圖）：
```sql
-- 047_renewal_view_v3.sql
-- 當 next_contract 不存在時返回 NULL 而非 false
CASE
    WHEN nc.next_contract_id IS NULL THEN NULL  -- 新增這行
    WHEN fp.payment_status = 'paid' THEN true
    ELSE false
END AS is_first_payment_paid
```

---

## P1 - 本週修復（影響用戶體驗）

### 4. 發票待辦過濾條件漏資料

**問題**：
- 位置：`064_priority_escalation.sql:252`
- `invoice_status != 'issued'` 會過濾掉 NULL 值

**修復**：
```sql
-- line 252
WHERE iw.decision_blocked_by IS NOT NULL
  AND (iw.invoice_status IS NULL OR iw.invoice_status != 'issued')
```

---

### 5. Kanban 排序邏輯錯誤

**問題**：
- 位置：`frontend/src/components/process/ProcessKanban.jsx:36`
- `decision_priority.asc` 字串排序會讓 urgent 排最後

**修復**：
在視圖中新增數字排序欄位，或在前端轉換：

```javascript
// ProcessKanban.jsx PROCESS_CONFIG
renewal: {
  ...
  order: 'priority_order.asc,days_until_expiry.asc',  // 使用數字欄位
}
```

或在 SQL 視圖中新增：
```sql
CASE decision_priority
    WHEN 'urgent' THEN 1
    WHEN 'high' THEN 2
    WHEN 'medium' THEN 3
    WHEN 'low' THEN 4
    ELSE 5
END AS priority_order
```

---

### 6. UPDATE_CUSTOMER 無 Handler

**問題**：
- `058_invoice_workspace.sql:162` 輸出 `UPDATE_CUSTOMER`
- `ActionDispatcher.js` 沒有對應 handler

**修復**：
```javascript
// ActionDispatcher.js invoice section
UPDATE_CUSTOMER: async (paymentId, payload) => {
  // 導航到客戶編輯頁面，或顯示編輯 Modal
  // 這個不需要呼叫 MCP tool，只需要 UI 導航
  return { success: true, action: 'navigate', url: `/customers/${payload.customerId}/edit` }
}
```

---

## P2 - 功能增強

### 7. Renewals Modal 加入 ProcessTimeline

**需求**：
- 在 Renewals 頁面的「續約進度管理」Modal 中加入 ProcessTimeline 組件
- 目前只有簡單的「處理記錄」，想要有完整的 Timeline 視圖

**修改位置**：`frontend/src/pages/Renewals.jsx` Checklist Modal 區塊

**實作**：
```jsx
// Renewals.jsx ~line 1200
import { ProcessTimeline } from '../components/process'

// 在 Modal 中新增
<ProcessTimeline
  steps={buildTimelineSteps(selectedContract)}
  currentStep={getCurrentStep(selectedContract)}
  renderDetails={renderRenewalTimelineDetails}
/>
```

需要新增 helper function 來建構 timeline steps。

---

### 8. 延後付款記錄功能

**需求**：
- 記錄「客戶承諾付款日期」
- 自動催繳邏輯需要跳過已有承諾日期的付款

**實作**：

1. 新增欄位：
```sql
ALTER TABLE payments ADD COLUMN promised_pay_date DATE;
COMMENT ON COLUMN payments.promised_pay_date IS '客戶承諾付款日期';
```

2. 修改催繳邏輯：
```python
# billing_tools.py
if payment.get('promised_pay_date') and payment['promised_pay_date'] > today:
    return {"skipped": True, "reason": "客戶已承諾於 {} 付款".format(payment['promised_pay_date'])}
```

3. 前端 UI：在付款管理頁面新增「記錄承諾日期」按鈕

---

### 9. Cloudflare R2 文件存儲（合約 PDF / 報價單）

**需求**：
- 系統生成的合約 PDF、報價單等文件存儲到 Cloudflare R2
- 建立文件存取記錄（誰下載、何時下載）
- 替換現有 GCS 存儲（降低成本，R2 無出站費用）

**架構**：
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  MCP Server │────▶│ Cloudflare  │────▶│   R2 Bucket │
│ (PDF Gen)   │     │   Worker    │     │  (Storage)  │
└─────────────┘     └─────────────┘     └─────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │  PostgreSQL │
                    │ (file_logs) │
                    └─────────────┘
```

**實作步驟**：

#### Phase 1：R2 設置
1. 建立 Cloudflare R2 Bucket：`hj-crm-files`
2. 設定 CORS 和存取權限
3. 產生 API Token（S3 相容）

#### Phase 2：後端整合
1. 新增 `file_storage.py` 工具：
```python
import boto3  # S3 相容

r2_client = boto3.client(
    's3',
    endpoint_url='https://<account_id>.r2.cloudflarestorage.com',
    aws_access_key_id=R2_ACCESS_KEY,
    aws_secret_access_key=R2_SECRET_KEY
)

async def upload_file(file_path: str, content: bytes, content_type: str):
    """上傳文件到 R2"""
    r2_client.put_object(
        Bucket='hj-crm-files',
        Key=file_path,
        Body=content,
        ContentType=content_type
    )
    return f"https://files.yourspce.org/{file_path}"

async def get_signed_url(file_path: str, expires_in: int = 3600):
    """產生簽名下載 URL"""
    return r2_client.generate_presigned_url(
        'get_object',
        Params={'Bucket': 'hj-crm-files', 'Key': file_path},
        ExpiresIn=expires_in
    )
```

2. 修改 `contract_generate_pdf` 工具：
```python
# 生成 PDF 後上傳到 R2
pdf_url = await upload_file(
    f"contracts/{contract_id}/{filename}",
    pdf_content,
    "application/pdf"
)
```

#### Phase 3：存取記錄
1. 新增資料表：
```sql
CREATE TABLE file_access_logs (
    id SERIAL PRIMARY KEY,
    file_path VARCHAR(500) NOT NULL,
    file_type VARCHAR(50),  -- contract_pdf, quote, invoice
    entity_type VARCHAR(50),  -- contract, quote
    entity_id INT,
    action VARCHAR(20),  -- upload, download, delete
    user_id INT,
    user_name VARCHAR(100),
    ip_address VARCHAR(45),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_file_logs_entity ON file_access_logs(entity_type, entity_id);
CREATE INDEX idx_file_logs_created ON file_access_logs(created_at);
```

2. 下載時記錄：
```python
async def download_file(file_path: str, user_id: int, user_name: str):
    # 記錄存取
    await db.insert('file_access_logs', {
        'file_path': file_path,
        'action': 'download',
        'user_id': user_id,
        'user_name': user_name
    })
    # 返回簽名 URL
    return await get_signed_url(file_path)
```

#### Phase 4：前端整合
1. 下載按鈕改為呼叫 API 取得簽名 URL
2. 新增「文件歷史」頁面顯示存取記錄

**環境變數**：
```bash
R2_ACCOUNT_ID=xxx
R2_ACCESS_KEY_ID=xxx
R2_SECRET_ACCESS_KEY=xxx
R2_BUCKET_NAME=hj-crm-files
R2_PUBLIC_URL=https://files.yourspce.org
```

**估計時間**：4-6 小時

**優先級**：P3（功能增強，非緊急）

---

### 10. escalated_priority 整合到前端

**問題**：
- `064_priority_escalation.sql` 新增了 `escalated_priority` 欄位
- 但前端 ProcessKanban 仍使用 `decision_priority`

**修復**：
```javascript
// ProcessKanban.jsx line 179
decision_priority: item.escalated_priority || item.decision_priority,
```

---

### 11. useProcess Hook ID 欄位對齊

**問題**：
- `useProcess.js:48` 定義 `invoice: 'invoice_id'`
- 但 `v_invoice_workspace` 用的是 `payment_id`

**修復**：
```javascript
// useProcess.js line 48
invoice: 'payment_id',  // 改成 payment_id
```

---

## 修復優先順序

| 優先級 | 問題 | 估計時間 | 風險 |
|--------|------|----------|------|
| P0-1 | SEND_REMINDER 工具名稱 | 5 min | 低 |
| P0-2 | void vs voided | 10 min | 低 |
| P0-3 | Checkbox fallback | 5 min | 低 |
| P1-4 | 發票過濾條件 | 10 min | 低 |
| P1-5 | Kanban 排序 | 20 min | 中 |
| P1-6 | UPDATE_CUSTOMER | 15 min | 低 |
| P2-7 | Renewals Timeline | 30 min | 低 |
| P2-8 | 延後付款功能 | 1 hr | 中 |
| **P3-9** | **Cloudflare R2 文件存儲** | **4-6 hr** | **中** |
| P2-10 | escalated_priority | 5 min | 低 |
| P2-11 | useProcess ID | 5 min | 低 |

---

## 測試清單

- [ ] 付款流程 SEND_REMINDER 按鈕可正常發送催繳
- [ ] 作廢發票後，v_invoice_queue 能正確顯示「待重開」
- [ ] DZ-112 的「已收款」checkbox 正確顯示打勾
- [ ] v_invoice_queue 不會漏掉 invoice_status = NULL 的資料
- [ ] Kanban 看板 urgent 排在最前面
- [ ] 發票流程「缺統編」卡點點擊不會報錯
- [ ] Renewals Modal 顯示完整 Timeline
