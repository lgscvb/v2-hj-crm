# Hour Jungle CRM v2

## 專案架構

```
v2-hj-crm/
├── backend/           # MCP Server + PostgreSQL + PostgREST
│   ├── mcp-server/    # FastAPI 後端
│   ├── services/      # PDF Generator (Cloud Run)
│   ├── sql/           # Database migrations
│   ├── nginx/         # Nginx 配置
│   └── docker-compose.yml
│
└── frontend/          # React 前端 (Cloudflare Pages)
    ├── src/
    ├── public/
    └── package.json
```

## 部署配置

| 項目 | 值 |
|------|-----|
| GCP 專案 | hj-crm (hj-crm-482012) |
| 區域 | us-west1 |
| 後端 VM | e2-medium (2 vCPU, 4GB) |
| 前端 | Cloudflare Pages |

## 域名

| 域名 | 用途 |
|------|------|
| `hj-v2.yourspce.org` | CRM 前端 (Cloudflare Pages) |
| `api-v2.yourspce.org` | MCP Server API |

## 快速部署

### 後端 (GCP VM)

```bash
# SSH 到 VM
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012

# 拉取最新程式碼並重啟
cd ~/v2-hj-crm/backend
git pull
docker compose up -d --build
```

### 前端 (Cloudflare Pages)

推送到 `main` 分支會自動觸發 Cloudflare Pages 部署。

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
- 正式環境：`VITE_API_BASE_URL=https://api-v2.yourspce.org`

## 核心語言規定

**所有輸出內容必須使用繁體中文**，包含程式碼註解、commit message、文件等。

---

## 前端重構策略

### 核心原則

1. **優先選擇可 debug、可回退的局部重構**
2. **Modal 除非完全不依賴頁面上下文，否則一律在 page 內渲染**
3. **狀態可以抽 hook，但不做 App-level ActionManager**（避免 DevTools 與上下文斷裂）
4. **若重構引入耦合且難解，允許回退並以新分頁重做**（舊頁進入 maintenance mode）

### 不採用的方案

| 方案 | 不採用原因 |
|------|-----------|
| Feature-Based 目錄結構 | 專案規模不大，全面遷移 ROI 不高 |
| Global ActionManager | Modal 和觸發頁面解耦太遠，debug 不直觀 |
| Zustand 管 Modal | 太重，useModal hook 更輕量 |

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
| P1 | Payments.jsx: 刪除舊的 useState(showXxxModal) | ⏳ 待執行 |
| P2 | Contracts.jsx: 套用相同模式 | ⏳ 待執行 |

### 回退指令

```bash
# 單一檔案回退
git checkout frontend/src/pages/Payments.jsx

# 整個 commit 回退
git revert HEAD
```
