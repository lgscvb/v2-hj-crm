# Hour Jungle CRM v2

> 詳細架構請參考 `../CLAUDE.md`（工作區層級文件）

## 專案架構

```
v2-hj-crm/                    ← Monorepo (GitHub: lgscvb/v2-hj-crm)
├── backend/                  # MCP Server + PostgreSQL + PostgREST
│   ├── mcp-server/           # FastAPI 後端
│   ├── services/             # PDF Generator (Cloud Run)
│   ├── sql/                  # Database migrations
│   ├── nginx/                # Nginx 配置
│   └── docker-compose.yml
│
└── frontend/                 # React 前端 (Cloudflare Pages)
    ├── src/
    ├── public/
    └── package.json
```

## 部署配置

| 項目 | 值 |
|------|-----|
| GCP 專案 | hj-crm (hj-crm-482012) |
| 區域 | us-west1 |
| 後端 VM | hj-crm-vm (e2-medium) |
| 前端 | Cloudflare Pages (自動部署) |

## 域名

| 域名 | 用途 | 部署方式 |
|------|------|----------|
| `hj-v2.yourspce.org` | **CRM v2 前端（主要）** | CNAME → hj-v2.pages.dev |
| `hj-v2.pages.dev` | Cloudflare Pages 預設域名 | Cloudflare Pages 自動部署 |
| `api-v2.yourspce.org` | MCP Server v2 API | Cloudflare Tunnel → GCP VM |

> ⚠️ **注意**：請使用 `hj-v2.yourspce.org`，不要使用 `hj-v2.pages.dev`（預設域名可能會有舊版快取）

### v1 vs v2 系統對照

| 系統 | 前端域名 | API 域名 | 部署位置 |
|------|----------|----------|----------|
| **v1（舊）** | `hj.yourspce.org` | `auto.yourspce.org` | GCP VM |
| **v2（新）** | `hj-v2.yourspce.org` | `api-v2.yourspce.org` | Cloudflare Pages + Tunnel |

## 快速部署

### 後端 (GCP VM)

```bash
# 推送程式碼
git add . && git commit -m "feat: 描述" && git push

# SSH 到 VM 更新
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012 \
  --command="cd ~/v2-hj-crm && git pull && cd backend && docker-compose down && docker-compose up -d"

# 只重啟 mcp-server（不重建 image）
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012 \
  --command="cd ~/v2-hj-crm/backend && docker-compose restart mcp-server"

# 如需重建 Docker image（程式碼有大改動時）
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012 \
  --command="cd ~/v2-hj-crm/backend && docker-compose build mcp-server && docker-compose down && docker-compose up -d"
```

### 前端 (Cloudflare Pages)

推送到 `main` 分支會**自動觸發**部署，無需手動操作。

```bash
git add . && git commit -m "feat: 描述" && git push
# Cloudflare Pages 會自動建構並部署
# 主要域名：https://hj-v2.yourspce.org
```

> 💡 Cloudflare Pages 設定：專案名稱 `hj-v2`，自訂域名已設定 `hj-v2.yourspce.org`

## 環境變數

### 後端 (.env)

```bash
POSTGRES_PASSWORD=xxx
LINE_CHANNEL_ACCESS_TOKEN=xxx
LINE_CHANNEL_SECRET=xxx
OPENAI_API_KEY=xxx
ANTHROPIC_API_KEY=xxx
GCS_BUCKET=hourjungle-contracts
```

### 前端

- 開發環境：使用 vite proxy 代理到 `api-v2.yourspce.org`
- 正式環境：Cloudflare Pages 設定 `VITE_API_BASE_URL`

## 核心語言規定

**所有輸出內容必須使用繁體中文**，包含程式碼註解、commit message、文件等。

---

## 設計審查規範

> 詳見 [DESIGN-CHECKLIST.md](docs/DESIGN-CHECKLIST.md)

### 新功能開發前必答問題

1. **這是 CRUD 還是業務事件？**
   - 涉及多表 / 有連鎖反應 / 狀態流轉 = 必須封裝為 MCP Tool

2. **如果中間斷網會怎樣？**
   - 多表操作 → 使用 PostgreSQL Transaction
   - 可能 Timeout → 使用兩階段提交（Draft → Activate）
   - 可能重複提交 → 使用 Idempotency Key

3. **前端該做什麼？後端該做什麼？**
   - 前端：收集輸入、顯示結果、發送意圖
   - 後端：驗證、計算、狀態管理、資料一致性
   - 規則：一個業務操作 = 一個 API 呼叫

4. **狀態流轉是否明確？**
   - 畫出狀態圖，標註每個轉換的觸發條件
   - 狀態檢查必須在後端

5. **不要畫判斷式流程圖**
   - 如果狀態可能跳躍，用「狀態機 + Decision Table + 工作隊列」取代
   - Decision Table 定義「卡在哪、下一步」
   - Dashboard 工作隊列顯示待辦事項

### 設計模式總結

> **不是「不畫圖」，而是換對的圖。**

| 用什麼 | 不用什麼 | 原因 |
|--------|----------|------|
| 狀態轉移圖 | 判斷式流程圖 | 狀態可跳躍、並存、回頭 |
| Decision Table | if/else 長串 | 每加一列 ≠ 重畫整個世界 |
| Dashboard 隊列 | 「完整流程追蹤」 | 只顯示當下要做什麼 |

### 審查紅旗 (Red Flags)

| 危險信號 | 問題 |
|----------|------|
| 前端連續呼叫 2+ API 完成一個操作 | 缺少後端封裝 |
| 業務邏輯在 useEffect 裡 | 邏輯洩漏到前端 |
| 沒有 Transaction 的多表操作 | 資料一致性風險 |
| 新舊欄位都在用 | 技術債累積 |

---

## 前端重構策略

### 核心原則

1. **優先選擇可 debug、可回退的局部重構**
2. **Modal 除非完全不依賴頁面上下文，否則一律在 page 內渲染**
3. **狀態可以抽 hook，但不做 App-level ActionManager**（避免 DevTools 與上下文斷裂）
4. **若重構引入耦合且難解，允許回退並以新分頁重做**（舊頁進入 maintenance mode）

### 已引入的工具

#### useModal Hook

位置：`frontend/src/hooks/useModal.js`

```javascript
// 基礎用法
const modal = useModal()
modal.open('pay', { paymentId: 123 })
modal.isOpen('pay')  // true
modal.getData()      // { paymentId: 123 }
modal.close()

// 付款頁面專用
const modal = usePaymentModals()
modal.openPay(payment)
modal.openWaive(payment)
modal.isPayOpen  // true/false
```

### 重構待辦（有空再做）

| 優先級 | 任務 | 狀態 |
|--------|------|------|
| P1 | Payments.jsx: 試改 Pay Modal 使用 usePaymentModals | ⏳ 待執行 |
| P1 | Payments.jsx: 改其他 Modal (Waive/Undo/Reminder/Delete/Generate) | ⏳ 待執行 |
| P2 | Contracts.jsx: 套用相同模式 | ⏳ 待執行 |
