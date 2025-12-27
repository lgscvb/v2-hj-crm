# 設計審查 Checklist

> 每個新功能開發前，必須回答以下問題

---

## 1. 業務事件識別 (Domain Event Check)

### 這是 CRUD 還是業務事件？

| 類型 | 特徵 | 處理方式 |
|------|------|---------|
| **簡單 CRUD** | 只改一個欄位、無連鎖反應 | 前端直接呼叫 PostgREST |
| **業務事件** | 涉及多表、有連鎖反應、狀態流轉 | 封裝為 MCP Tool |

### 問自己：

- [ ] 這個操作會影響幾張表？（> 1 張 = 業務事件）
- [ ] 這個操作會觸發其他動作嗎？（產生帳款、發通知 = 業務事件）
- [ ] 這個操作涉及狀態變化嗎？（draft → active = 業務事件）

**範例**：
- ❌ 「更新客戶電話」→ 簡單 CRUD
- ✅ 「續約」→ 業務事件（涉及：舊合約、新合約、應收帳款）

---

## 2. 交易完整性 (Transaction Integrity)

### 如果中間斷網會怎樣？

對於每個業務事件，畫出步驟並標記危險點：

```
步驟 1: 建立新合約
        ↓
   ⚠️ 斷網點 ⚠️  ← 這裡斷了會怎樣？
        ↓
步驟 2: 更新舊合約
```

### 問自己：

- [ ] 中間失敗會產生「半成品」資料嗎？
- [ ] 使用者 F5 重整會產生重複資料嗎？
- [ ] 這些操作需要「全有或全無」嗎？

**解法選擇**：

| 場景 | 解法 |
|------|------|
| 多表操作需同步 | PostgreSQL Transaction / Function |
| 操作可能 Timeout | 兩階段提交（Draft → Activate） |
| 可能重複提交 | Idempotency Key |

---

## 3. 責任邊界 (Responsibility Boundary)

### 前端該做什麼？後端該做什麼？

| 層級 | 職責 | 不該做的事 |
|------|------|-----------|
| **前端** | 收集輸入、顯示結果、發送意圖 | 計算業務邏輯、決定狀態流轉 |
| **後端** | 驗證、計算、狀態管理、資料一致性 | 只當 CRUD proxy |

### 問自己：

- [ ] 前端有沒有在「決定」業務邏輯？
- [ ] 如果前端壞掉，後端能獨立完成操作嗎？
- [ ] 前端對後端的呼叫是「一個意圖一個 API」嗎？

**危險信號**：
- 前端需要呼叫 2+ 個 API 才能完成一個操作 ⚠️
- 前端在 if/else 判斷業務規則 ⚠️
- 前端知道資料表結構細節 ⚠️

---

## 4. 狀態流轉圖 (State Machine)

### 為什麼不用判斷式流程圖？

> **如果狀態可能跳躍，就不要畫判斷式流程圖。用 State + Decision + Queue 取代。**

傳統流程圖隱含三個假設，但我們的業務剛好全部相反：

| 假設 | 我們的實務 |
|------|-----------|
| 只有一個現在狀態 | 已付但未簽（狀態交錯） |
| 每一步只能往前走 | 簽了又改方案（回頭） |
| 決策只發生一次 | 人可以在任何時候介入（手動） |

**本專案使用的替代方案**：

| 替代工具 | 用途 | 範例 |
|----------|------|------|
| **狀態轉移圖** | 只畫合法轉移 | `draft → pending_sign → signed → active` |
| **Decision Table** | 定義「卡在哪、下一步」 | `v_contract_workspace.decision_blocked_by` |
| **工作隊列** | Dashboard 待辦清單 | 簽署流程隊列、解約流程隊列 |

### 狀態圖怎麼畫

對於有狀態的實體（合約、案件），必須畫出狀態圖：

```
           建立
             ↓
        ┌─────────┐
        │  draft  │
        └────┬────┘
             │ activate()
             ↓
        ┌─────────┐
        │ active  │←────────┐
        └────┬────┘         │
             │              │ 續約
    ┌────────┼────────┐     │
    ↓        ↓        ↓     │
┌───────┐ ┌───────┐ ┌───────┴──┐
│expired│ │renewed│ │terminated│
└───────┘ └───────┘ └──────────┘
```

### 問自己：

- [ ] 每個狀態轉換都有明確的「觸發條件」嗎？
- [ ] 有沒有非法的轉換路徑？
- [ ] 狀態檢查是在後端還是前端？（必須在後端）

---

## 5. 技術債管理 (Tech Debt)

### 新舊系統並存時

- [ ] 新功能是否需要讀取舊欄位？
- [ ] 舊欄位何時可以廢棄？
- [ ] 有沒有 Migration 計畫？

**規則**：
1. 新功能只用新結構
2. 舊視圖/API 加上 `@deprecated` 標記
3. 設定廢棄時間點並寫入文件

---

## 6. 事前驗屍 (Pre-mortem)

在開發前，假設這個功能「三個月後爛掉了」，問：

> 「它是怎麼死的？」

常見死法：
- [ ] 網路斷了，資料只存一半
- [ ] 使用者重複點擊，產生重複資料
- [ ] 並發操作，資料互相覆蓋
- [ ] 狀態不一致，業務流程卡住

---

## 設計文件模板

每個中大型功能必須包含：

```markdown
## 功能名稱

### 1. 業務事件
- 涉及實體：[列出]
- 連鎖反應：[列出]

### 2. 狀態流轉圖
[Mermaid 圖]

### 3. 交易邊界
- Transaction 範圍：[描述]
- 失敗回滾策略：[描述]

### 4. API 設計
- 前端發送：一個請求
- 後端處理：封裝全部邏輯

### 5. 邊界情況
- Timeout 處理：[描述]
- 重複提交處理：[描述]
```

---

## 審查紅旗 (Red Flags)

遇到以下情況，必須停下來重新設計：

| 紅旗 | 問題 |
|------|------|
| 前端需要連續呼叫 2+ API | 缺少後端封裝 |
| 業務邏輯在 useEffect 裡 | 邏輯洩漏到前端 |
| 沒有 Transaction 的多表操作 | 資料一致性風險 |
| 新舊欄位都在用 | 技術債累積 |
| 狀態轉換沒有後端驗證 | 狀態可被繞過 |

---

## 7. 單一路徑與寫入治理 (Write Governance)

### 核心原則

> **分模組開發不是問題，沒有跨模組的業務流程邊界才是問題。**

### 每個業務流程必須定義：

| 項目 | 說明 | 範例（續約） |
|------|------|-------------|
| **唯一入口** | 只有一個 API 可以觸發狀態變更 | `renewal_activate` |
| **寫入權限** | 哪些角色可以寫哪些欄位 | 前端不可改 `status` |
| **完成判定** | 什麼條件下算「完成」 | 新合約 active + 舊合約 renewed |

### 寫入治理表（本專案）

| 欄位 | 誰可以寫 | 強制層級 |
|------|---------|---------|
| `contracts.status` | PostgreSQL Function only | DB Trigger |
| `contracts.renewed_from_id` | PostgreSQL Function only | DB Trigger |
| `contracts.renewal_*_at` | 前端可寫（顯示用） | 無限制 |
| `payments.payment_status` | MCP Tool only | 後端驗證 |

---

## 8. 跨模組不變量 (Cross-Module Invariants)

### 必須列出並指定強制層級

| 不變量 | 強制層級 | 實作方式 |
|--------|---------|---------|
| 同期間不得兩張 active 合約重疊 | DB | Exclusion Constraint（待實作） |
| 舊約標 renewed 必須存在新約關聯 | DB | Trigger 檢查 |
| 有 draft/active 新約就不出現在提醒 | View | WHERE NOT EXISTS |
| 解約完成必須所有待繳取消 | DB | Function Transaction |

### 問自己：

- [ ] 這個規則誰負責保證？（不能是「大家以為別人會處理」）
- [ ] 如果有人繞過這個規則，系統會怎樣？
- [ ] 這個規則寫在 DB/Domain/UI 哪一層？

---

## 9. 模組介面設計 (Module Interface)

### 反模式：共享表格當介面

```
❌ 模組 A 直接寫 contracts 表
❌ 模組 B 也直接寫 contracts 表
→ 誰都可以改，誰都不知道對方改了什麼
```

### 正確做法：Command/RPC 當介面

```
✅ 模組 A 呼叫 renewal_activate()
✅ 模組 B 呼叫 termination_complete()
→ 只有定義好的入口，有驗證、有 Transaction
```

---

## 本專案已踩過的坑

| 功能 | 問題 | 解法 | 狀態 |
|------|------|------|------|
| 續約流程 | Checklist 只改欄位，沒建新合約 | 兩階段提交 + Transaction | ✅ 已修復 |
| 解約流程 | 多表操作無 Transaction | PostgreSQL Function | ✅ 已修復 |
| 發票開立 | 外部 API 成功但本地更新失敗 | 冪等性操作追蹤 | ✅ 已修復 |
| 免收核准 | 付款和申請狀態不同步 | PostgreSQL Function | ✅ 已修復 |
| 直接 PATCH status | 繞過業務邏輯 | DB Trigger 保護 | ✅ 已修復 |

---

## 10. 各模組 Decision 模式現況

> 2025-12-27 更新

| 模組 | 狀態機 | Decision | 工作隊列 | 評估 |
|------|--------|----------|----------|------|
| **續約流程** | ✅ `active → confirmed → renewal_draft → pending_sign → signed → active` | ✅ `v_contract_workspace` | ✅ Dashboard 續約追蹤 | 已完成 |
| **簽署流程** | ✅ `draft → pending_sign → signed → active` | ✅ Timeline `signing_status` | ✅ Dashboard 簽署隊列 | 已完成 |
| **解約流程** | ✅ 7 狀態 + 8 步驟 Checklist | ✅ `v_termination_workspace` | ✅ Dashboard 解約隊列 | 已完成 |
| **付款流程** | ⚠️ 線性但有分支（免收申請） | ❌ 缺少 | ⚠️ 只有逾期列表 | 觀察中 |
| **發票流程** | ⚠️ 有冪等性保護 | ❌ 缺少 | ❌ 缺少 | 觀察中 |
| **會議室預約** | ✅ 簡單但完整 | ❌ 不需要 | ❌ 不需要 | OK |

### 已實作的 Workspace 視圖

| 視圖 | 用途 | Decision 欄位 |
|------|------|---------------|
| `v_contract_workspace` | 合約續約 + 簽署流程 | `decision_blocked_by`, `decision_next_action`, `decision_owner` |
| `v_termination_workspace` | 解約流程 | `decision_blocked_by`, `decision_next_action`, `decision_owner` |
| `v_pending_sign_contracts` | 簽署流程待辦 | `is_overdue`, `days_pending` |

---

## 相關文件

- [STD-contract-status.md](STD-contract-status.md) - 合約狀態轉換圖
- [PRD-v2.5-data-consistency.md](PRD-v2.5-data-consistency.md) - 資料一致性問題清單
- [SSD-v1.5-renewal-draft.md](SSD-v1.5-renewal-draft.md) - 續約草稿 API 規格
