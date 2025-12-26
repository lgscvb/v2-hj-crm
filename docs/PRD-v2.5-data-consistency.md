# PRD v2.5 - 資料一致性保護設計

> Version: 2.5
> Date: 2025-12-26
> Purpose: 定義跨表操作的 Transaction 保護機制，避免 Timeout/F5 造成資料不一致

---

## 1. 問題背景

### 1.1 核心問題

當一個業務操作需要更新多個資料表時，如果中途發生：
- 網路 Timeout
- 使用者按 F5 重新整理
- 伺服器錯誤

會導致**部分操作完成、部分操作未完成**，造成資料不一致。

### 1.2 典型後果

| 場景 | 問題 | 業務影響 |
|------|------|---------|
| 續約到一半 Timeout | 舊合約標記 `renewed` 但新合約未建立 | 客戶沒有有效合約，無法產生應收帳款 |
| 續約到一半 Timeout | 新合約建立但舊合約狀態未更新 | 兩份 `active` 合約，產生重複應收帳款 |
| 解約到一半 Timeout | 解約案件建立但合約狀態未更新 | 合約仍顯示 `active`，繼續產生應收帳款 |
| 免收核准到一半 Timeout | 付款標記 `waived` 但申請狀態未更新 | 申請仍顯示 `pending`，可能被重複核准 |

---

## 2. 現有問題清單

### 2.1 Termination Domain（解約流程）

| 函數 | 問題位置 | 風險描述 | 嚴重度 |
|------|---------|---------|--------|
| `create_termination_case()` | Lines 124-139 | 先建立案件、再更新合約狀態 | **高** |
| `update_termination_status()` | Lines 204-216 | 先更新案件、再更新合約狀態 | **高** |
| `process_refund()` | Lines 465-476 | 先更新案件、再更新合約狀態 | **高** |
| `cancel_termination_case()` | Lines 614-629 | 先更新案件、再恢復合約狀態 | **高** |

**具體風險**：
```
Timeout 在案件建立後、合約更新前：
→ termination_case 存在 (status='notice_received')
→ contract 仍為 'active'
→ 再次建立會報錯「已有進行中的解約案件」
→ 但合約狀態不對，無法正常操作
```

### 2.2 Billing Domain（繳費流程）

| 函數 | 問題位置 | 風險描述 | 嚴重度 |
|------|---------|---------|--------|
| `billing_approve_waive()` | Lines 438-458 | 先更新付款狀態、再更新申請狀態 | **中** |

**具體風險**：
```
Timeout 在付款更新後、申請更新前：
→ payment 已標記 'waived'
→ waive_request 仍為 'pending'
→ 主管可能再次點擊核准，但付款已處理
```

### 2.3 Contract Domain（合約流程）

| 函數 | 問題位置 | 風險描述 | 嚴重度 |
|------|---------|---------|--------|
| `contract_terminate()` | Lines 611-656 | 更新合約 → 取消付款 → 取消續約案件 | **中** |

**具體風險**：
```
Timeout 在合約更新後、付款取消前：
→ contract 已標記 'terminated'
→ 部分 payments 仍為 'pending'
→ 這些付款會繼續出現在催繳列表
```

### 2.4 Invoice Domain（發票流程）

| 函數 | 問題位置 | 風險描述 | 嚴重度 |
|------|---------|---------|--------|
| `invoice_create()` | Lines 259-268 | 先呼叫外部 API、再更新本地資料庫 | **高** |
| `invoice_void()` | Lines 362-371 | 先呼叫外部 API、再更新本地資料庫 | **高** |

**具體風險**：
```
Timeout 在 API 成功後、本地更新前：
→ 發票已在光貿系統開立
→ 本地 payment.invoice_number 為空
→ 再次開票會在光貿產生重複發票
```

### 2.5 Renewal Domain（續約流程）- 已修復

| 函數 | 狀態 | 說明 |
|------|------|------|
| `renewal_create_draft()` | ✅ 已修復 | 使用草稿機制 |
| `renewal_activate()` | ✅ 已修復 | 使用 PostgreSQL Function Transaction |

---

## 3. 解決方案架構

### 3.1 核心原則

1. **兩階段提交**：先建立草稿（可 Timeout 恢復），再原子性啟用
2. **PostgreSQL Function**：將多表操作封裝在 Function 內，確保 Transaction
3. **冪等性設計**：重複呼叫不會產生副作用

### 3.2 解決方案模式

```
┌─────────────────────────────────────────────────────────────┐
│                     兩階段提交模式                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Stage 1: 建立草稿（安全區）                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ • 建立 draft 狀態記錄                                │   │
│  │ • 不影響業務邏輯（不產生應收、不更新原記錄）          │   │
│  │ • Timeout 可恢復：重新載入頁面可看到草稿              │   │
│  │ • 可取消：直接刪除草稿                               │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  Stage 2: 原子性啟用（Transaction 保護）                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ • 呼叫 PostgreSQL Function                          │   │
│  │ • Function 內部使用 Transaction                     │   │
│  │ • 所有操作要麼全成功、要麼全失敗                     │   │
│  │ • 執行快速（< 100ms），Timeout 機率極低              │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 各流程解決方案

| 流程 | 方案 | 實作狀態 |
|------|------|---------|
| 續約流程 | 草稿機制 + PostgreSQL Function | ✅ 已實作 (039_renewal_v2.sql) |
| 解約流程 | 草稿機制 + PostgreSQL Function | ⏳ 待實作 |
| 免收核准 | PostgreSQL Function | ⏳ 待實作 |
| 發票開立 | 冪等性 Key + 狀態追蹤 | ⏳ 待實作 |

---

## 4. 續約流程實作（參考範例）

### 4.1 資料庫 Schema

```sql
-- 合約新增狀態
ALTER TABLE contracts ADD CONSTRAINT contracts_status_check
    CHECK (status IN (
        'draft',              -- 草稿（新建合約用）
        'active',             -- 生效中
        'expired',            -- 已到期
        'terminated',         -- 已終止
        'renewed',            -- 已續約（被新合約取代）
        'pending_termination', -- 解約中
        'renewal_draft'       -- 續約草稿（新增）
    ));

-- 追溯續約來源
ALTER TABLE contracts ADD COLUMN renewed_from_id INT REFERENCES contracts(id);

-- 冪等性保護表
CREATE TABLE renewal_operations (
    id                  SERIAL PRIMARY KEY,
    idempotency_key     VARCHAR(64) UNIQUE,
    old_contract_id     INT NOT NULL REFERENCES contracts(id),
    new_contract_id     INT REFERENCES contracts(id),
    status              VARCHAR(20) DEFAULT 'draft',
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    activated_at        TIMESTAMPTZ,
    cancelled_at        TIMESTAMPTZ
);
```

### 4.2 PostgreSQL Function

```sql
CREATE OR REPLACE FUNCTION activate_renewal(
    p_new_contract_id INT,
    p_activated_by TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_new_contract RECORD;
    v_old_contract_id INT;
BEGIN
    -- 取得新合約資訊
    SELECT * INTO v_new_contract
    FROM contracts WHERE id = p_new_contract_id;

    IF v_new_contract.status != 'renewal_draft' THEN
        RETURN jsonb_build_object('success', false, 'error', '合約狀態不是續約草稿');
    END IF;

    v_old_contract_id := v_new_contract.renewed_from_id;

    -- ★ 以下操作在同一 Transaction 內 ★

    -- 1. 啟用新合約
    UPDATE contracts
    SET status = 'active', updated_at = NOW()
    WHERE id = p_new_contract_id AND status = 'renewal_draft';

    -- 2. 更新舊合約狀態
    UPDATE contracts
    SET status = 'renewed', updated_at = NOW()
    WHERE id = v_old_contract_id AND status = 'active';

    -- 3. 更新操作記錄
    UPDATE renewal_operations
    SET status = 'activated', activated_at = NOW(), activated_by = p_activated_by
    WHERE new_contract_id = p_new_contract_id AND status = 'draft';

    RETURN jsonb_build_object('success', true, 'message', '續約啟用成功');

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql;
```

### 4.3 後端 API 流程

```python
# Stage 1: 建立草稿（安全，可 Timeout）
async def renewal_create_draft(old_contract_id: int, new_data: dict) -> dict:
    # 1. 檢查是否已有草稿
    existing = await check_existing_draft(old_contract_id)
    if existing:
        return {"success": True, "draft_id": existing["id"], "already_exists": True}

    # 2. 建立 renewal_draft 狀態的新合約
    draft = await create_renewal_draft_contract(old_contract_id, new_data)

    # 3. 記錄操作（冪等性保護）
    await create_renewal_operation(old_contract_id, draft["id"])

    return {"success": True, "draft_id": draft["id"]}


# Stage 2: 啟用草稿（Transaction 保護）
async def renewal_activate(draft_id: int, activated_by: str) -> dict:
    # 呼叫 PostgreSQL Function
    result = await postgrest_rpc("activate_renewal", {
        "p_new_contract_id": draft_id,
        "p_activated_by": activated_by
    })
    return result
```

### 4.4 前端流程

```javascript
// 1. 點擊「確認續約」按鈕
const handleRenewalConfirm = async (data) => {
  // Stage 1: 建立草稿
  const draft = await api.post('/tools/call', {
    name: 'renewal_create_draft',
    arguments: { old_contract_id: contractId, ...data }
  });

  if (!draft.success) {
    showError(draft.error);
    return;
  }

  // 顯示確認對話框
  showConfirmDialog({
    title: '確認啟用續約？',
    message: `新合約編號: ${draft.contract_number}`,
    onConfirm: async () => {
      // Stage 2: 啟用草稿
      const result = await api.post('/tools/call', {
        name: 'renewal_activate',
        arguments: { draft_id: draft.draft_id }
      });

      if (result.success) {
        showSuccess('續約完成！');
        navigate(`/contracts/${result.new_contract_id}`);
      }
    }
  });
};
```

---

## 5. 解約流程待實作方案

### 5.1 Schema 修改

```sql
-- 解約案件新增草稿狀態
ALTER TABLE termination_cases DROP CONSTRAINT termination_cases_status_check;
ALTER TABLE termination_cases ADD CONSTRAINT termination_cases_status_check
    CHECK (status IN (
        'draft',              -- 草稿（新增）
        'notice_received',
        'moving_out',
        'pending_doc',
        'pending_settlement',
        'completed',
        'cancelled'
    ));
```

### 5.2 PostgreSQL Function

```sql
CREATE OR REPLACE FUNCTION activate_termination_case(
    p_case_id INT
) RETURNS JSONB AS $$
BEGIN
    -- 在同一 Transaction 內：
    -- 1. 更新案件狀態: draft → notice_received
    -- 2. 更新合約狀態: active → pending_termination
    -- ...
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION complete_termination(
    p_case_id INT,
    p_refund_data JSONB
) RETURNS JSONB AS $$
BEGIN
    -- 在同一 Transaction 內：
    -- 1. 更新案件: status → completed
    -- 2. 更新合約: status → terminated
    -- 3. 取消待繳付款: status → cancelled
    -- ...
END;
$$ LANGUAGE plpgsql;
```

---

## 6. 發票流程待實作方案

### 6.1 冪等性設計

```sql
CREATE TABLE invoice_operations (
    id                  SERIAL PRIMARY KEY,
    idempotency_key     VARCHAR(64) UNIQUE,
    payment_id          INT NOT NULL REFERENCES payments(id),
    external_invoice_no VARCHAR(20),      -- 光貿回傳的發票號碼
    status              VARCHAR(20) DEFAULT 'pending',
    api_response        JSONB,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    completed_at        TIMESTAMPTZ
);
```

### 6.2 流程

```
1. 開票前先建立 invoice_operations 記錄（pending）
2. 呼叫光貿 API
3. 成功後更新 invoice_operations（記錄發票號碼）
4. 更新 payments.invoice_number

如果 Timeout：
→ 重試時檢查 invoice_operations
→ 如果已有發票號碼，直接更新本地資料庫
→ 避免重複開票
```

---

## 7. 實作優先順序

| 優先級 | 流程 | 理由 |
|--------|------|------|
| P0 | 續約流程 | 已實作完成 |
| P1 | 解約流程 | 涉及押金退還，金額大、影響嚴重 |
| P1 | 發票開立 | 涉及外部系統，錯誤難以回復 |
| P2 | 免收核准 | 內部操作，影響相對小 |
| P2 | 合約終止 | 低頻操作 |

---

## 8. 測試要點

### 8.1 單元測試

- [ ] 草稿建立成功
- [ ] 重複建立草稿返回已存在的草稿（冪等性）
- [ ] 草稿啟用成功
- [ ] 草稿取消成功
- [ ] 非草稿狀態無法啟用
- [ ] 非草稿狀態無法取消

### 8.2 整合測試

- [ ] 模擬 Timeout：在 Stage 1 後中斷，重新載入應看到草稿
- [ ] 模擬 Timeout：在 Stage 2 中斷，應全部失敗（Transaction rollback）
- [ ] 並發測試：同時兩個請求啟用同一草稿，只有一個成功

### 8.3 手動測試

- [ ] 在草稿建立後按 F5，確認草稿仍在
- [ ] 在草稿建立後關閉瀏覽器，重新進入應看到草稿
- [ ] 草稿存在時，原合約不應從續約提醒消失（除非啟用）

---

## 附錄：相關文件

- [039_renewal_v2.sql](../backend/sql/migrations/039_renewal_v2.sql) - 續約草稿機制 Migration
- [renewal_tools_v3.py](../backend/mcp-server/tools/renewal_tools_v3.py) - 續約草稿 API
- [SSD.md](./SSD.md) - 系統序列圖（待更新 Renewal 部分）
