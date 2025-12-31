# 寫入入口對照表

> 最後更新：2025-12-31

## 設計原則

**每張表只有一個官方寫入模組**，前端不直接寫入資料庫。

```
前端 → Tool/RPC → 資料庫
       ↑
    唯一入口
```

## 核心表寫入入口

### contracts

| 操作 | 唯一入口 | 模組 |
|------|---------|------|
| 建立草稿 | `renewal_create_draft` | `renewal_tools_v3.py` |
| 更新草稿 | `renewal_update_draft` | `renewal_tools_v3.py` |
| 啟用合約 | `renewal_activate` | `renewal_tools_v3.py` |
| 發送簽約 | `renewal_send_for_sign` | `renewal_tools_v3.py` |
| 標記已簽 | `renewal_mark_signed` | `renewal_tools_v3.py` |
| 設定意願 | `set_renewal_intent` | `intent_tools.py` |
| 解約流程 | `complete_termination_atomic` | PostgreSQL RPC |
| 取消解約 | `cancel_termination_atomic` | PostgreSQL RPC |

### payments

| 操作 | 唯一入口 | 模組 |
|------|---------|------|
| 記錄繳費 | `billing_record_payment` | `billing_tools.py` |
| 撤銷繳費 | `billing_undo_payment` | `billing_tools.py` |
| 申請減免 | `billing_request_waive` | `billing_tools.py` |
| 核准減免 | `billing_approve_waive_v2` | `billing_tools_v2.py` |
| 駁回減免 | `billing_reject_waive_v2` | `billing_tools_v2.py` |
| 設定承諾 | `billing_set_promise` | `billing_tools.py` |

### invoices

| 操作 | 唯一入口 | 模組 |
|------|---------|------|
| 開立發票 | `invoice_create_v2` | `invoice_tools_v2.py` |
| 作廢發票 | `invoice_void` | `invoice_tools.py` |
| 開立折讓 | `invoice_allowance` | `invoice_tools.py` |

### commissions

| 操作 | 唯一入口 | 模組 |
|------|---------|------|
| 標記已付 | `commission_pay` | `crm_tools.py` |
| 取消佣金 | `commission_cancel` | `crm_tools.py` |

### termination_cases

| 操作 | 唯一入口 | 模組 |
|------|---------|------|
| 建立案件 | `complete_termination_atomic` | PostgreSQL RPC |
| 更新案件 | `complete_termination_atomic` | PostgreSQL RPC |
| 取消案件 | `cancel_termination_atomic` | PostgreSQL RPC |

### waive_requests

| 操作 | 唯一入口 | 模組 |
|------|---------|------|
| 建立申請 | `billing_request_waive` | `billing_tools.py` |
| 核准申請 | `billing_approve_waive_v2` | `billing_tools_v2.py` |
| 駁回申請 | `billing_reject_waive_v2` | `billing_tools_v2.py` |

## 歷史/唯讀表

| 表 | 狀態 | 說明 |
|----|------|------|
| `renewal_cases` | 唯讀 | V2 續約案件，已降級為歷史表 |

## 已棄用工具

| 工具 | 狀態 | 替代方案 |
|------|------|---------|
| `renewal_update_status` | 已棄用 | `set_renewal_intent` (意願) / V3 工具 (交易) |
| `renewal_batch_update` | 已棄用 | `batch_set_renewal_intent` |
| `update_invoice_status` | 已棄用 | `invoice_create_v2` |
| `get_renewal_status_summary` | 已棄用 | `v_renewal_dashboard_stats` View |
| `renewal_start` | 已移除 | `renewal_create_draft` |
| `renewal_complete` | 已移除 | `renewal_activate` |
| `renewal_cancel` | 已移除 | `renewal_cancel_draft` |

## 待補完（暫用 V1）

| 工具 | 現狀 | 待辦 |
|------|------|------|
| `invoice_void` | V1 | 需補 V2 版本 |
| `invoice_allowance` | V1 | 需補 V2 版本 |
| `billing_record_payment` | V1 | 需補 V2 版本 |
| `billing_undo_payment` | V1 | 需補 V2 版本 |

## 讀取入口（View 層）

| 用途 | View | 前端 Hook |
|------|------|----------|
| 續約意願 | `v_renewal_intent` | `useQuery(['renewal-intent', id])` |
| 合約工作區 | `v_contract_workspace` | `useContractWorkspace(id)` |
| 付款工作區 | `v_payment_workspace` | `usePaymentWorkspace(id)` |
| 續約提醒 | `v_renewal_reminders` | `useRenewalReminders()` |
| 資料完整性 | `v_integrity_alerts_summary` | (IntegrityAlerts 頁面) |
