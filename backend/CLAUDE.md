# Hour Jungle CRM - MCP Server + PostgreSQL

> V2 後端，部署於 GCP VM 透過 Cloudflare Tunnel (`api-v2.yourspce.org`)

## 專案概述

Hour Jungle CRM 後端系統，採用 PostgreSQL + PostgREST + MCP Server 三層架構，提供 40+ MCP 工具供前端和 AI Agent 調用。

## 技術棧

| 類別 | 技術 |
|------|------|
| 資料庫 | PostgreSQL 15 |
| API 層 | PostgREST (自動生成 RESTful API) |
| 業務層 | FastAPI MCP Server |
| 快取 | Redis (LINE 對話狀態) |
| 外部整合 | LINE Bot、光貿電子發票、Google Cloud |

---

## 專案結構

```
backend/
├── mcp-server/              # FastAPI MCP 伺服器
│   ├── main.py              # 主入口、路由註冊
│   ├── tools/               # MCP 工具模組
│   │   ├── crm_tools.py     # CRM 查詢/操作工具
│   │   ├── line_tools.py    # LINE 通知工具
│   │   ├── report_tools.py  # 報表工具
│   │   ├── renewal_tools.py # 續約流程工具
│   │   ├── quote_tools.py   # 報價單工具
│   │   ├── invoice_tools.py # 電子發票工具
│   │   ├── contract_tools.py # 合約工具
│   │   ├── legal_letter_tools.py # 存證信函工具
│   │   ├── booking_tools.py # 會議室預約工具
│   │   └── settings_tools.py # 系統設定工具
│   └── line_webhook.py      # LINE Webhook 處理
│
├── sql/                     # 資料庫
│   ├── schema.sql           # 主要 schema
│   └── migrations/          # 遷移腳本 (14+)
│
├── services/
│   └── pdf-generator/       # PDF 生成微服務 (Cloud Run)
│
├── nginx/                   # Nginx 配置
├── scripts/                 # 部署腳本
├── docker-compose.yml       # 服務編排
└── .env                     # 環境變數
```

---

## Docker 服務架構

```yaml
services:
  postgres:      # PostgreSQL 15 (port 5432)
  postgrest:     # PostgREST API (port 3000)
  mcp-server:    # FastAPI MCP (port 8080)
  nginx:         # 反向代理 (port 80/443)
  redis:         # Redis 快取 (port 6379)
```

---

## 部署

### GCP VM (透過 Cloudflare Tunnel)

```bash
# 推送程式碼
cd /path/to/v2-hj-crm
git add . && git commit -m "feat: 描述" && git push

# SSH 到 VM 更新（注意：VM 上資料夾名稱為 hourjungle-crm）
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012 \
  --command="cd ~/hourjungle-crm && git pull && docker compose restart mcp-server"

# 如需重建 Docker image
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012 \
  --command="cd ~/hourjungle-crm && git pull && docker compose build mcp-server && docker compose up -d mcp-server"
```

### 域名配置

| 域名 | 說明 |
|------|------|
| `api-v2.yourspce.org` | Cloudflare Tunnel 入口（推薦） |
| `auto.yourspce.org` | 直接暴露 VM IP（可用，同資料庫） |

---

## MCP 工具清單 (40+)

### CRM 工具 (crm_tools.py)
| 工具名稱 | 類型 | 說明 |
|---------|------|------|
| `crm_search_customers` | 查詢 | 模糊搜尋客戶 |
| `crm_get_customer_detail` | 查詢 | 客戶完整資料 |
| `crm_list_payments_due` | 查詢 | 應收款列表 |
| `crm_list_renewals_due` | 查詢 | 到期合約 |
| `crm_create_customer` | 寫入 | 建立客戶 |
| `crm_update_customer` | 寫入 | 更新客戶 |
| `crm_record_payment` | 寫入 | 記錄繳費 |
| `crm_payment_undo` | 寫入 | 撤銷繳費 |
| `crm_create_contract` | 寫入 | 建立合約 |
| `commission_pay` | 寫入 | 佣金付款 |

### LINE 工具 (line_tools.py)
| 工具名稱 | 說明 |
|---------|------|
| `line_send_message` | 發送 LINE 訊息 |
| `line_send_payment_reminder` | 繳費提醒 |
| `line_send_renewal_reminder` | 續約提醒 |

### 報表工具 (report_tools.py)
| 工具名稱 | 說明 |
|---------|------|
| `report_revenue_summary` | 營收摘要 |
| `report_overdue_list` | 逾期報表 |
| `report_commission_due` | 應付佣金 |

### 其他工具
- **quote_***: 報價單相關
- **invoice_***: 電子發票 (光貿 API)
- **contract_***: 合約 PDF 生成
- **legal_letter_***: 存證信函
- **booking_***: 會議室預約
- **renewal_***: 續約流程管理
- **floor_plan_***: 平面圖生成

---

## 新增 MCP 工具標準流程

### 1. 建立工具檔案

在 `mcp-server/tools/` 建立新檔案：

```python
# mcp-server/tools/my_tools.py

from typing import Any
import httpx

POSTGREST_URL = "http://postgrest:3000"

# 工具定義
MY_TOOLS = [
    {
        "name": "my_new_tool",
        "description": "工具說明，讓 LLM 知道何時調用",
        "inputSchema": {
            "type": "object",
            "properties": {
                "param1": {"type": "string", "description": "參數說明"},
                "param2": {"type": "integer", "description": "參數說明"}
            },
            "required": ["param1"]
        }
    }
]

# 工具實作
async def my_new_tool(param1: str, param2: int = 0) -> dict[str, Any]:
    """工具實作邏輯"""
    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{POSTGREST_URL}/my_table",
            params={"column": f"eq.{param1}"}
        )
        return resp.json()

# 工具路由
TOOL_HANDLERS = {
    "my_new_tool": my_new_tool
}
```

### 2. 在 main.py 註冊工具

```python
from tools.my_tools import MY_TOOLS, TOOL_HANDLERS

ALL_TOOLS.extend(MY_TOOLS)
ALL_HANDLERS.update(TOOL_HANDLERS)
```

### 3. 測試工具

```bash
curl -X POST https://api-v2.yourspce.org/tools/call \
  -H "Content-Type: application/json" \
  -d '{"name": "my_new_tool", "arguments": {"param1": "test"}}'
```

---

## PostgREST 使用

### 基本查詢

```bash
# 查詢所有客戶
GET /api/db/customers

# 過濾條件
GET /api/db/customers?status=eq.active
GET /api/db/payments?due_date=lt.2024-12-31

# 排序
GET /api/db/payments?order=due_date.desc

# 選擇欄位
GET /api/db/customers?select=id,name,phone

# 關聯查詢
GET /api/db/contracts?select=*,customer:customers(name,phone)
```

### 寫入操作

```bash
# 新增
POST /api/db/customers
{ "name": "王小明", "phone": "0912345678" }

# 更新
PATCH /api/db/customers?id=eq.123
{ "status": "churned" }

# 刪除
DELETE /api/db/customers?id=eq.123
```

---

## 新增資料表/視圖流程

### 1. 建立 Migration

在 `sql/migrations/` 建立新檔案：

```sql
-- sql/migrations/015_add_new_table.sql

CREATE TABLE IF NOT EXISTS new_table (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE VIEW v_new_summary AS
SELECT id, name, created_at
FROM new_table
WHERE created_at > NOW() - INTERVAL '30 days';
```

### 2. 執行 Migration

```bash
# 本地
docker exec -i hj-postgres psql -U postgres -d crm < sql/migrations/015_add_new_table.sql

# GCP VM
gcloud compute ssh hj-crm-vm --zone=us-west1-a --project=hj-crm-482012 \
  --command="docker exec -i hj-postgres psql -U postgres -d crm < /path/to/migration.sql"
```

### 3. PostgREST 自動生成 API

新表和視圖會自動有對應的 API 端點：
- `GET /api/db/new_table`
- `GET /api/db/v_new_summary`

---

## 資料庫核心表

| 表名 | 說明 |
|------|------|
| `branches` | 場館/分館 |
| `customers` | 客戶資料 |
| `contracts` | 合約 |
| `payments` | 繳費記錄 |
| `commissions` | 佣金 |
| `accounting_firms` | 介紹會計所 |
| `audit_logs` | 審計日誌 |
| `quotes` | 報價單 |
| `invoices` | 電子發票 |
| `floor_plans` | 場館平面圖 |
| `floor_positions` | 平面圖位置 |

---

## 環境變數

```env
# PostgreSQL
POSTGRES_USER=postgres
POSTGRES_PASSWORD=xxx
POSTGRES_DB=crm

# PostgREST
PGRST_DB_URI=postgres://postgres:xxx@postgres:5432/crm
PGRST_DB_ANON_ROLE=web_anon

# LINE
LINE_CHANNEL_ACCESS_TOKEN=xxx
LINE_CHANNEL_SECRET=xxx

# 光貿電子發票
TRADEVAN_API_KEY=xxx
TRADEVAN_COMPANY_BAN=xxx

# OpenRouter (AI)
OPENROUTER_API_KEY=xxx
```

---

## 開發指令

```bash
# 啟動所有服務
docker compose up -d

# 查看日誌
docker compose logs -f mcp-server

# 重建 MCP Server
docker compose build mcp-server && docker compose up -d mcp-server

# 進入 PostgreSQL
docker exec -it hj-postgres psql -U postgres -d crm

# 測試 API
curl http://localhost:8080/health
curl http://localhost:3000/customers?limit=5
```

---

## 注意事項

1. **寫入工具需確認**：AI 調用寫入工具時需要用戶確認
2. **審計日誌**：所有 CRM 操作會記錄到 `audit_logs`
3. **Redis TTL**：LINE 對話狀態 30 分鐘後過期
4. **PostgREST 權限**：確保 `web_anon` 角色有適當權限

---

## LINE Bot 配置

### Webhook 配置

```
Webhook URL: https://api-v2.yourspce.org/line/webhook
```

在 LINE Console 設定：
- ✅ Use webhook
- ❌ Auto-reply messages (由系統處理)
- ❌ Greeting messages (由系統處理)

---

## GCP 資源

| 資源 | 名稱 | 說明 |
|------|------|------|
| Compute Engine | `hj-crm-vm` | 後端 VM (us-west1-a) |
| Cloud Run | `pdf-generator` | PDF 生成服務 |
| Cloud Storage | `hourjungle-pdfs` | PDF 存儲 |
| Cloud Storage | `hourjungle-contracts` | 合約檔案 |
