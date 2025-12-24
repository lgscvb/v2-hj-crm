# PRD v2.3 補充：Pre-flight 實作規則

> 開始寫 Code 前的最終確認
> Version: 2.3
> Last Updated: 2024-12-22

---

## 1. 日期銜接規則

### 1.1 CompleteRenewal 新舊合約日期

```
規則：新合約 start_date 必須 > 舊合約 end_date

允許空窗：✅ 是（客戶可能休息幾天再續）
允許重疊：❌ 否（會造成雙重收費）
```

**驗證邏輯**：

```python
def complete_renewal(renewal_case_id, new_contract_data):
    old_contract = get_contract(renewal_case.contract_id)

    if new_contract_data.start_date <= old_contract.end_date:
        raise ValidationError(
            "新合約起始日必須晚於舊合約到期日",
            code="DATE_OVERLAP"
        )

    # ... 繼續建立新合約
```

### 1.2 合約期間計算

```
合約期間 = end_date - start_date + 1 天
例如：2024-01-01 ~ 2024-12-31 = 366 天（含頭尾）

繳費期數 = ceil(合約月數)
例如：12 個月合約 = 12 期（月繳）或 1 期（年繳）
```

---

## 2. 金額檢核規則

### 2.1 RecordPayment 金額驗證

```
MVP 規則：嚴格模式（金額必須完全一致）

if request.amount != payment.amount_due:
    raise ValidationError(
        f"金額不符：應繳 {payment.amount_due}，實收 {request.amount}",
        code="AMOUNT_MISMATCH"
    )
```

### 2.2 Phase 2：Partial Payment（未來）

```
Phase 2 才考慮：
- 新增 partially_paid 狀態
- 記錄 amount_paid（累計已繳）
- 記錄 amount_remaining（剩餘應繳）
```

---

## 3. Invoice 資料結構

### 3.1 只用關聯表（避免雙來源）

```sql
-- invoices 表：不存 payment_id
CREATE TABLE invoices (
  id SERIAL PRIMARY KEY,
  contract_id INT REFERENCES contracts(id),  -- 從 payment 推導
  invoice_number VARCHAR(20) UNIQUE,
  amount DECIMAL(10,2),

  -- 快照
  snapshot_company_name VARCHAR(100),
  snapshot_tax_id VARCHAR(20),

  status VARCHAR(20) DEFAULT 'pending',
  issued_at TIMESTAMPTZ,
  voided_at TIMESTAMPTZ,
  void_reason TEXT,

  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 關聯表：MVP 時一對一，未來可多對多
CREATE TABLE payment_invoices (
  payment_id INT REFERENCES payments(id),
  invoice_id INT REFERENCES invoices(id),
  PRIMARY KEY (payment_id, invoice_id)
);
```

### 3.2 IssueInvoice 時的寫入

```python
def issue_invoice(payment_id):
    payment = get_payment(payment_id)
    contract = get_contract(payment.contract_id)
    customer = get_customer(contract.customer_id)

    # 建立發票（含 contract_id）
    invoice = Invoice.create(
        contract_id=contract.id,  # ← 這裡要存
        invoice_number=generate_invoice_number(),
        amount=payment.amount_due,
        snapshot_company_name=customer.company_name,
        snapshot_tax_id=customer.tax_id,
        status='issued',
        issued_at=now()
    )

    # 建立關聯
    PaymentInvoice.create(
        payment_id=payment_id,
        invoice_id=invoice.id
    )

    return invoice
```

### 3.3 QueryContractDetail 的查詢

```sql
-- 透過 payment_invoices 關聯查詢
SELECT i.*
FROM invoices i
WHERE i.contract_id = :contract_id
ORDER BY i.created_at DESC;

-- 或者透過 PostgREST embed
GET /api/db/contracts?id=eq.{id}&select=*,invoices(*)
```

---

## 4. HTTP 狀態碼規則

### 4.1 WaivePayment Approve 失敗

```
場景：主管按核准，但 payment 狀態已變更

舊規則：400 Bad Request
新規則：409 Conflict

Response:
{
  "error": "款項狀態已變更，無法核准",
  "code": "STATUS_CHANGED",
  "request_status": "rejected",  // ← 讓前端直接更新列表
  "current_payment_status": "paid"
}
```

### 4.2 完整狀態碼對照

| 場景 | HTTP Status | Code |
|------|-------------|------|
| 參數缺失/格式錯誤 | 400 | INVALID_PARAMS |
| 狀態不符（無法執行） | 400 | INVALID_STATUS |
| 並發衝突（狀態已變更） | 409 | STATUS_CHANGED |
| 資源已被占用 | 409 | RESOURCE_OCCUPIED |
| 金額不符 | 400 | AMOUNT_MISMATCH |
| LINE 未綁定 | 400 | LINE_NOT_BOUND |
| 資源不存在 | 404 | NOT_FOUND |
| 權限不足 | 403 | PERMISSION_DENIED |

---

## 5. BatchTask 查詢規則

### 5.1 使用 PostgREST Embed

```
GET /api/db/batch_tasks?id=eq.{task_id}&select=*,items:batch_task_items(*)
```

**Response**：

```json
{
  "id": "batch-123",
  "type": "send_reminder",
  "status": "partial_success",
  "total_count": 10,
  "success_count": 8,
  "failed_count": 2,
  "items": [
    { "target_id": "payment-1", "status": "success" },
    { "target_id": "payment-2", "status": "failed", "error": "LINE_NOT_BOUND" }
  ]
}
```

### 5.2 為什麼用 Embed？

```
優點：
- 一次 query 取得全部資料
- 減少 polling 時的 request 數量
- PostgREST 原生支援

缺點：
- items 多的時候 response 較大
- 但 MVP 批量上限 100 筆，可接受
```

---

## 6. Transaction 安全規則

### 6.1 禁止在 Transaction 內呼叫外部 API

```python
# ❌ 錯誤：Transaction 內呼叫 LINE
with transaction():
    update_payment(...)
    send_line_message(...)  # 這會讓 Transaction 卡住
    insert_audit_log(...)

# ✅ 正確：Transaction 外呼叫 LINE
with transaction():
    update_payment(...)
    insert_audit_log(...)

send_line_message(...)  # Transaction 結束後再呼叫
```

### 6.2 Transaction 時間上限

```
建議：Transaction 內操作 < 1 秒
監控：若 Transaction 超過 5 秒，記錄 warning log
```

---

## 7. 總結清單

### Pre-flight Checklist

| # | 項目 | 規則 |
|---|------|------|
| 1 | 新舊合約日期 | start_date > old.end_date，允許空窗不允許重疊 |
| 2 | 金額檢核 | MVP 嚴格模式，必須完全一致 |
| 3 | Invoice 資料結構 | 只用 payment_invoices 關聯表 |
| 4 | Invoice 存 contract_id | 從 payment → contract 推導並存入 |
| 5 | 並發狀態衝突 | 用 409 Conflict，帶 request_status |
| 6 | BatchTask 查詢 | 用 PostgREST embed |
| 7 | Transaction 安全 | 不呼叫外部 API，時間 < 1 秒 |

---

## 文件版本

| 版本 | 變更 |
|------|------|
| v2.0 | 功能清單 |
| v2.1 | 領域模型（Contract 中心） |
| v2.2 | 實作規則（狀態機、資源預留） |
| v2.3 | Pre-flight 規則（日期、金額、Invoice 結構） |
