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
| `hj-v2.pages.dev` | CRM 前端 | Cloudflare Pages |
| `api-v2.yourspce.org` | MCP Server API | Cloudflare Tunnel → GCP VM |

## 快速部署

### 後端 (GCP VM)

```bash
# 推送程式碼
git add . && git commit -m "feat: 描述" && git push

# SSH 到 VM 更新（注意：VM 上資料夾名稱為 hourjungle-crm）
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012 \
  --command="cd ~/hourjungle-crm && git pull && docker compose restart mcp-server"

# 如需重建 Docker image
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012 \
  --command="cd ~/hourjungle-crm && git pull && docker compose build mcp-server && docker compose up -d mcp-server"
```

### 前端 (Cloudflare Pages)

推送到 `main` 分支會**自動觸發**部署，無需手動操作。

```bash
git add . && git commit -m "feat: 描述" && git push
# Cloudflare Pages 會自動建構並部署到 hj-v2.pages.dev
```

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
