# SSD: 合約繳費週期視圖

> 2025-12-27 建立

## 問題背景

目前 ContractWorkspace 的「狀態時間線」只覆蓋：
- 續約意願 → 文件回簽 → **首期收款** → **首期發票** → 合約啟用

但實際合約生命週期包含**週期性繳費**：

```
x1/1/1  簽約（首期收款 + 發票）    ← Timeline 有顯示
x1/7/1  第二期收款 + 發票          ← 沒顯示
x2/1/1  第三期收款 + 發票          ← 沒顯示
x2/7/1  第四期收款 + 發票          ← 沒顯示
x2/11/1 續約提醒（到期前一個月）
```

**問題**：用戶在合約視角看不到週期性繳費進度。

---

## 設計原則

1. **Timeline 保持「里程碑」性質** — 不被週期事件淹沒
2. **週期事件獨立呈現** — 新增「繳費週期」摘要區塊
3. **階層式揭露** — 摘要為主、展開為輔、完整明細去 Payments 頁

---

## 實作方案

### 1. 後端：`get_contract_billing_cycles()`

用 `generate_series` 根據 `payment_cycle` 產出期數，再 LEFT JOIN `payments` 補狀態。

```sql
CREATE OR REPLACE FUNCTION get_contract_billing_cycles(
    p_contract_id INT,
    p_past_n INT DEFAULT 2,
    p_future_n INT DEFAULT 2
)
RETURNS TABLE (
    period_index INT,
    payment_period TEXT,
    due_date DATE,
    expected_amount NUMERIC,
    payment_id INT,
    payment_status TEXT,
    invoice_status TEXT,
    invoice_number TEXT,
    is_current BOOLEAN,
    is_overdue BOOLEAN
) AS $$
...
$$;
```

**回傳欄位**：
- `period_index`: 期數（1, 2, 3...）
- `payment_period`: 'YYYY-MM'
- `due_date`: 應收日
- `expected_amount`: 預期金額
- `payment_id`: 若已產生付款記錄
- `payment_status`: 'paid' / 'pending' / 'overdue' / NULL（未建立）
- `invoice_status`: 'issued' / 'pending' / NULL
- `invoice_number`: 發票號碼
- `is_current`: 是否為當期
- `is_overdue`: 是否逾期

### 2. 後端：修改 `get_contract_timeline`

新增兩個欄位：

```json
{
  "timeline": [...],
  "billing_summary": {
    "total_periods": 4,
    "paid_periods": 3,
    "pending_periods": 1,
    "overdue_periods": 0,
    "not_created_periods": 0,
    "next_due_date": "2025-07-01",
    "next_amount": 30000
  },
  "billing_cycles_preview": [
    { "period_index": 2, "payment_period": "2025-01", "payment_status": "paid", ... },
    { "period_index": 3, "payment_period": "2025-07", "payment_status": "pending", ... },
    { "period_index": 4, "payment_period": "2026-01", "payment_status": null, ... }
  ]
}
```

### 3. 前端：ContractWorkspace 新增「繳費週期」區塊

```
┌─────────────────────────────────────────────┐
│ 繳費週期                     3/4 期已繳     │
├─────────────────────────────────────────────┤
│ 下次繳費：2025/7/1    $30,000               │
├─────────────────────────────────────────────┤
│ 期別   應收日      狀態      發票           │
│ ───────────────────────────────────────────│
│ 2期    2025/1/1   ✓ 已付    AB-12345678    │
│ 3期    2025/7/1   ⏳ 待繳    -              │
│ 4期    2026/1/1   ○ 未建立  -              │
├─────────────────────────────────────────────┤
│              [查看全部付款記錄]              │
└─────────────────────────────────────────────┘
```

---

## Timeline 節點調整

| 現有節點 | 調整後 |
|----------|--------|
| 首期收款 | 收款進度（顯示 X/Y 期已繳） |
| 首期發票 | 發票進度（顯示 X/Y 張已開） |

---

## 狀態定義

| 狀態 | 說明 | 顯示 |
|------|------|------|
| `paid` | 已付款 | ✓ 綠色 |
| `pending` | 待繳（已建立記錄） | ⏳ 黃色 |
| `overdue` | 逾期（已過應收日但未付） | ⚠️ 紅色 |
| `null` | 未建立（該期應有但無記錄） | ○ 灰色 |

---

## 異常提醒

- **未建立期數 > 0**：顯示紅點，提醒「有 N 期尚未產生付款記錄」
- **逾期期數 > 0**：顯示紅色 badge

---

## 相關文件

- [051_update_workspace_signing.sql](../backend/sql/migrations/051_update_workspace_signing.sql) - 現有 Timeline 實作
- [ContractWorkspace.jsx](../frontend/src/pages/ContractWorkspace.jsx) - 前端頁面
