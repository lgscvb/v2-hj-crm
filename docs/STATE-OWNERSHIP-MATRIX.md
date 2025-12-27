# State Ownership Matrix v1.0

> 狀態真相來源定義（Single Source of Truth）
>
> **核心原則**：一個狀態只能有一個 Authoritative Source，其他地方只能「顯示」，不能「寫入」。

---

## 一、續約流程狀態 SSOT

### 工作單位：Contract（以舊合約為追蹤起點）

| 狀態 | Authoritative Source | 可手動寫入？ | 寫入入口 | 備註 |
|------|---------------------|-------------|---------|------|
| 已通知 | `old_contract.renewal_notified_at` | ✅ | `renewal_set_flag('notified')` | 記在舊合約，表示已聯繫客戶 |
| 已確認 | `old_contract.renewal_confirmed_at` | ✅ | `renewal_set_flag('confirmed')` | 記在舊合約，表示客戶口頭答應 |
| 已建立續約草稿 | `next_contract.status = 'draft'` | ✅ | `renewal_create_draft()` | 新合約以 draft 狀態建立 |
| 已簽約 | `next_contract.signed_at` | ❌ | 簽署流程自動寫入 | 由文件簽署流程產生 |
| 已收款 | `payments.status = 'paid'` (next_contract) | ❌ | 金流模組 `record_payment()` | 由金流模組管理 |
| 已開票 | `invoices` 表 (next_contract) | ❌ | 發票模組 | 由發票模組管理 |
| 已啟用 | `next_contract.status = 'active'` | ⚠️ | `renewal_activate()` 或手動 | 需權限，通常由流程觸發 |

---

## 二、三條線分離原則

```
意願線（Intent）     → old_contract.renewal_*_at     → 業務手動管理
文件線（Document）   → next_contract.status/signed_at → 簽署流程管理
金流線（Finance）    → payments / invoices           → 財務模組管理
```

### 禁止跨線寫入

| 禁止行為 | 原因 |
|----------|------|
| ❌ 勾選 Checklist 時寫入 `payments` | Checklist 只管意願，不管金流 |
| ❌ 收款時寫入 `renewal_paid_at` | 金流由 payments 表管理，不回寫合約 |
| ❌ 簽約時寫入 `renewal_signed_at` | 簽約由 next_contract 管理，不回寫舊合約 |

---

## 三、Read Model 聚合規則

### Workspace / Timeline 的資料來源

| Timeline 節點 | 資料來源 | 聚合方式 |
|--------------|---------|---------|
| 意願 (intent) | `old_contract.renewal_notified_at`, `renewal_confirmed_at` | 直接讀取 |
| 簽署 (signing) | `next_contract.status`, `next_contract.signed_at` | JOIN next_contract |
| 收款 (payment) | `payments WHERE contract_id = next_contract.id` | 彙總計算 |
| 發票 (invoice) | `invoices WHERE contract_id = next_contract.id` | 彙總計算 |
| 啟用 (activation) | `next_contract.status` | 直接讀取 |

### 唯一聚合入口

```sql
-- 所有跨模組狀態查詢必須透過 Workspace View 或 RPC
v_contract_workspace        -- 合約工作台視圖
v_renewal_reminders         -- 續約追蹤列表
get_contract_timeline()     -- Timeline + Decision RPC
```

**禁止**：前端或其他模組自行 JOIN 計算跨模組狀態。

---

## 四、Decision 規則（卡點判斷）

| 條件組合 | blocked_by | next_action | owner |
|----------|------------|-------------|-------|
| 已確認 + 無 next_contract | `need_create_renewal` | 建立續約草稿 | Sales |
| 有 next_contract + 未簽 + 超過 14 天 | `signing_overdue` | 催簽 | Sales |
| 已簽 + 未收款 | `payment_pending` | 追收款項 | Finance |
| 已收款 + 未開票 | `invoice_pending` | 開立發票 | Finance |
| 全部完成 | `null` | 流程完成 | - |

---

## 五、MCP Tools 對照表

### Write Tools（寫入入口）

| Tool | 寫入目標 | SSOT |
|------|---------|------|
| `renewal_set_flag` | `old_contract.renewal_*_at` | 意願 |
| `renewal_create_draft` | `contracts` (status=draft) | 文件 |
| `renewal_activate` | `contracts.status` | 文件 |
| `record_payment` | `payments` | 金流 |

### Read Tools（聚合查詢）

| Tool | 資料來源 | 用途 |
|------|---------|------|
| `contract_get_timeline` | `get_contract_timeline()` RPC | Workspace 頁面 |
| `list_renewal_reminders` | `v_renewal_reminders` | 續約列表 |
| `list_pending_sign` | `v_pending_sign_contracts` | 待簽列表 |

---

## 六、V1/V2 棄用工具

| 工具 | 狀態 | 替代方案 |
|------|------|---------|
| `contract_renew` | [V1 已棄用] | `renewal_create_draft` + `renewal_activate` |
| `renewal_update_status` | [V1 已棄用] | `renewal_set_flag` (意願) 或流程觸發 (簽約/收款) |
| `renewal_set_flag('paid')` | ❌ 已禁止 | 由 `payments` 模組管理 |
| `renewal_set_flag('signed')` | ❌ 已禁止 | 由 `contracts` 簽署流程管理 |

---

## 七、Checklist：新功能開發前必查

開發任何涉及「續約/合約/金流」的功能前，必須確認：

- [ ] 這個狀態的 SSOT 在哪？（查本文件）
- [ ] 寫入入口是哪個 Tool？
- [ ] 是否會造成雙真相？
- [ ] Read 是否透過 Workspace View？

---

## 變更紀錄

| 版本 | 日期 | 變更內容 |
|------|------|---------|
| v1.0 | 2024-12-27 | 初版建立，定義續約流程 SSOT |
