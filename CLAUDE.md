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
