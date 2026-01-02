# 逾期判斷邏輯說明

> 本文檔說明 HJ CRM 系統中逾期判斷的分層設計

## 設計概述

系統採用**三層判斷**策略，每層有不同職責：

```
┌─────────────────────────────────────────────────────────┐
│ 1. SQL Trigger 層（自動狀態轉換）                        │
│    pending + due_date < TODAY → overdue                 │
├─────────────────────────────────────────────────────────┤
│ 2. SQL View 層（動態計算，考慮 promised_pay_date）       │
│    effective_due_date = COALESCE(promised_pay_date, due_date) │
├─────────────────────────────────────────────────────────┤
│ 3. 應用層（顯示邏輯）                                    │
│    根據 days_overdue 和 urgency 顯示警告                 │
└─────────────────────────────────────────────────────────┘
```

## 1. SQL Trigger 層

**位置**：`backend/sql/init/03_functions.sql`

**函數**：`calculate_overdue_days()`

```sql
-- 只處理 pending 狀態的付款
IF NEW.payment_status = 'pending' AND NEW.due_date < CURRENT_DATE THEN
    NEW.payment_status := 'overdue';
    NEW.overdue_days := CURRENT_DATE - NEW.due_date;
END IF;
```

**職責**：
- 自動將 `pending` 狀態轉為 `overdue`
- 計算 `overdue_days` 欄位
- 在 INSERT/UPDATE 時觸發

## 2. SQL View 層

**位置**：`backend/sql/migrations/074_align_overdue_with_promised_date.sql`

### 2.1 v_overdue_details 視圖

```sql
-- 有效到期日（優先使用承諾日期）
COALESCE(p.promised_pay_date, p.due_date) AS effective_due_date,

-- 逾期天數（基於有效到期日）
CASE
    WHEN COALESCE(p.promised_pay_date, p.due_date) < CURRENT_DATE
    THEN CURRENT_DATE - COALESCE(p.promised_pay_date, p.due_date)
    ELSE 0
END AS days_overdue,

-- 緊急度
CASE
    WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
    THEN 'waiting_promise'  -- 有承諾日期且未過期
    WHEN days <= 7 THEN 'warning'
    WHEN days <= 30 THEN 'danger'
    ELSE 'critical'
END AS urgency_level
```

### 2.2 v_payments_due 視圖

```sql
-- 緊急度（含等待承諾狀態）
CASE
    WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
    THEN 'waiting_promise'  -- 不催繳
    WHEN p.payment_status = 'overdue' AND p.overdue_days > 30 THEN 'critical'
    WHEN p.payment_status = 'overdue' AND p.overdue_days > 14 THEN 'high'
    WHEN p.payment_status = 'overdue' THEN 'medium'
    WHEN p.due_date <= CURRENT_DATE + 3 THEN 'upcoming'
    ELSE 'normal'
END AS urgency
```

**職責**：
- 考慮 `promised_pay_date`（客戶承諾付款日期）
- 動態計算 `days_overdue` 和 `urgency`
- 過濾條件：`amount > 0` 且 `is_billable = true`

## 3. 應用層

### 3.1 Python 後端

**位置**：`backend/mcp-server/tools/billing_tools.py`

```python
# 只有 pending 或 overdue 可記錄繳費
if current_status not in ["pending", "overdue"]:
    return {"error": "只有待繳或逾期款項可記錄繳費"}
```

### 3.2 前端顯示

**位置**：`frontend/src/pages/Payments.jsx`

```jsx
// 逾期天數顯示
<Badge variant={row.days_overdue > 30 ? 'danger' : 'warning'}>
    {row.days_overdue} 天
</Badge>
```

## 欄位定義

| 欄位 | 類型 | 說明 |
|------|------|------|
| `payment_status` | enum | pending, paid, overdue, waived, cancelled |
| `due_date` | DATE | 原始應繳日期 |
| `promised_pay_date` | DATE | 客戶承諾付款日期（可為空） |
| `overdue_days` | INTEGER | 逾期天數（Trigger 自動計算） |
| `paid_at` | TIMESTAMP | 實際付款時間 |

## 重要規則

1. **promised_pay_date 優先**：如果客戶有承諾付款日期，逾期計算以此為準
2. **waiting_promise 狀態**：有承諾日期且未過期時，不列入逾期催繳
3. **$0 付款排除**：`amount = 0` 的付款不列入逾期清單
4. **非計費合約排除**：`is_billable = false` 的合約不列入逾期

## 相關 Migration

| Migration | 內容 |
|-----------|------|
| 006 | 動態逾期判斷邏輯 |
| 053 | 排除 $0 付款 |
| 065 | 新增 promised_pay_date 欄位 |
| 074 | 整合 promised_pay_date 到視圖 |

---

*文檔日期：2026-01-02*
