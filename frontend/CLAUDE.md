# Hour Jungle CRM - 叢林小管家前端

> V2 前端，部署於 Cloudflare Pages (`hj-v2.pages.dev`)

## 專案概述

Hour Jungle CRM 管理後台前端，專為聯合辦公空間（虛擬辦公室）設計的客戶關係管理系統。

## 技術棧

| 類別 | 技術 |
|------|------|
| 框架 | React 18.2.0 + React Router 6 |
| 建構 | Vite 5.0.0 |
| 樣式 | Tailwind CSS 3.3.5 + Headless UI |
| 狀態 | Zustand 4.4.7 |
| 資料 | TanStack Query 5.8.0 + Axios |
| 圖表 | Recharts 2.10.3 |
| PDF | @react-pdf/renderer 4.3.1 |

---

## 專案結構

```
src/
├── components/           # 通用 UI 元件
│   ├── Layout.jsx       # 主框架（側邊欄+頂部導航）
│   ├── DataTable.jsx    # 高階資料表格
│   ├── Modal.jsx        # 模態框
│   ├── Badge.jsx        # 狀態徽章
│   └── pdf/             # PDF 元件
│       ├── QuotePDF.jsx      # 報價單 PDF
│       ├── ContractPDF.jsx   # 合約 PDF
│       └── FloorPlanPDF.jsx  # 平面圖 + 租戶名冊 PDF
│
├── pages/               # 頁面元件 (20個)
│   ├── Dashboard.jsx    # 儀表板
│   ├── Customers.jsx    # 客戶列表
│   ├── CustomerDetail.jsx
│   ├── Contracts.jsx    # 合約管理
│   ├── Payments.jsx     # 收款管理
│   ├── Renewals.jsx     # 續約提醒
│   ├── Commissions.jsx  # 佣金管理
│   ├── Reports.jsx      # 報表中心
│   ├── Quotes.jsx       # 報價單
│   ├── Invoices.jsx     # 發票管理
│   ├── Prospects.jsx    # 潛客管理
│   ├── LegalLetters.jsx # 存證信函
│   ├── Bookings.jsx     # 會議室預約
│   ├── FloorPlan.jsx    # 平面圖管理
│   ├── AIAssistant.jsx  # AI 助手
│   └── Settings.jsx     # 系統設定
│
├── hooks/
│   ├── useApi.js        # React Query hooks
│   └── useModal.js      # Modal 狀態管理
│
├── services/
│   └── api.js           # API 客戶端
│
├── store/
│   └── useStore.js      # Zustand 狀態管理
│
├── App.jsx              # 路由配置
└── main.jsx             # 應用入口
```

---

## API 架構

### 混合 API 模式

本專案採用三種 API 模式：

#### 1. MCP Tools API（業務操作）
```javascript
POST /tools/call
{
  "name": "crm_record_payment",
  "arguments": { "payment_id": 123, "payment_method": "transfer" }
}
```

#### 2. PostgREST API（直接查詢）
```javascript
GET /api/db/customers?status=eq.active
GET /api/db/v_payments_due?order=due_date

PATCH /api/db/customers?id=eq.123
{ "phone": "0912345678" }
```

#### 3. AI Chat API
```javascript
POST /ai/chat
{ "message": "今天有哪些待收款？" }
```

### 常用視圖

| 視圖 | 用途 |
|------|------|
| `v_customer_summary` | 客戶概覽 |
| `v_payments_due` | 應收款列表 |
| `v_overdue_details` | 逾期詳情 |
| `v_renewal_reminders` | 續約提醒 |
| `v_commission_tracker` | 佣金追蹤 |

---

## 開發指令

```bash
# 安裝依賴
npm install

# 開發伺服器 (port 5173)
npm run dev

# 建構生產版本
npm run build

# 預覽建構結果
npm run preview
```

---

## 部署

### Cloudflare Pages (V2 正式環境)

推送到 `main` 分支會**自動觸發**部署：

```bash
git add . && git commit -m "feat: 描述" && git push
# 自動部署到 hj-v2.pages.dev
```

**Cloudflare Pages 設定**：
- Build command: `npm run build`
- Build output directory: `dist`
- Root directory: `frontend`

### 環境變數

```env
# Cloudflare Pages 環境變數
VITE_API_BASE_URL=https://api-v2.yourspce.org
```

開發時 Vite 會將 API 請求代理到後端。

---

## 新增頁面流程

1. 在 `src/pages/` 建立新頁面元件
2. 在 `src/App.jsx` 新增路由：
   ```jsx
   <Route path="/new-page" element={<NewPage />} />
   ```
3. 在 `src/components/Layout.jsx` 新增側邊欄連結
4. 使用 `useApi` hooks 調用 API

---

## 調用 MCP 工具

```javascript
import { callTool } from '../services/api';

// 記錄繳費
const result = await callTool('crm_record_payment', {
  payment_id: 123,
  payment_method: 'transfer',
  payment_date: '2024-12-15'
});

// 發送 LINE 訊息
await callTool('line_send_payment_reminder', {
  customer_id: 456,
  reminder_type: 'overdue'
});
```

---

## 樣式規範

- 主色系：Primary Blue (#3b82f6) + Jungle Green (#22c55e)
- 狀態色：綠=成功、黃=警告、紅=危險
- 使用 Tailwind CSS 原子類

---

## 權限角色

| 角色 | 可訪問頁面 |
|------|-----------|
| admin | 全部 |
| manager | 儀表板、報表、客戶、合約、繳費 |
| finance | 繳費、報表、佣金 |
| sales | 客戶、合約、佣金 |
| service | 客戶、繳費 |

---

## PDF 生成功能

### 架構說明

本專案使用**前端 PDF 生成**（@react-pdf/renderer），而非後端生成，原因：
- 後端生成（Cloud Run + WeasyPrint）速度慢（15-20秒超時）
- 前端生成速度快，無需網路請求

### PDF 元件

| 元件 | 用途 | 字體 |
|------|------|------|
| `QuotePDF.jsx` | 報價單 | NotoSansTC（子集，214KB） |
| `ContractPDF.jsx` | 合約 | NotoSansTC（子集） |
| `FloorPlanPDF.jsx` | 平面圖 + 租戶名冊 | NotoSansTCFull（完整，14MB） |

### 字體配置

```
public/fonts/
├── NotoSansTC-Regular.ttf      # 完整字體 (6.8MB)
├── NotoSansTC-Bold.ttf         # 完整字體 (6.8MB)
├── NotoSansTC-Regular-Subset.ttf  # 子集字體 (110KB)
├── NotoSansTC-Bold-Subset.ttf     # 子集字體 (110KB)
└── charset.txt                    # 子集包含的字符
```

**重要**：
- `FloorPlanPDF` 使用完整字體（`NotoSansTCFull`），因為需要顯示所有租戶公司名稱
- `QuotePDF` 使用子集字體（`NotoSansTC`），內容較固定
- 兩者使用**不同字體家族名稱**避免衝突

### 更新子集字體

當需要新增字符到子集字體時：

```bash
cd public/fonts
pyftsubset NotoSansTC-Regular.ttf --text-file=charset.txt --output-file=NotoSansTC-Regular-Subset.ttf
pyftsubset NotoSansTC-Bold.ttf --text-file=charset.txt --output-file=NotoSansTC-Bold-Subset.ttf
```

### html2canvas 截圖

`FloorPlan.jsx` 使用 html2canvas 截取平面圖 DOM：

```javascript
import html2canvas from 'html2canvas'

// 圖片需要 crossOrigin 屬性
<img src={url} crossOrigin="anonymous" />

// 截圖
const canvas = await html2canvas(ref.current, {
  scale: 1,
  useCORS: true,
  allowTaint: true
})
```

---

## GCS CORS 設定

平面圖儲存在 GCS，需要 CORS 設定讓 html2canvas 可以載入：

```bash
echo '[{"origin": ["*"], "method": ["GET", "HEAD"], "responseHeader": ["Content-Type", "Access-Control-Allow-Origin"], "maxAgeSeconds": 3600}]' > /tmp/cors.json
gcloud storage buckets update gs://hourjungle-contracts --cors-file=/tmp/cors.json
```

---

## Vite Dev Proxy（本地開發代理）

```javascript
// vite.config.js
export default defineConfig({
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'https://api-v2.yourspce.org',
        changeOrigin: true,
        secure: true,
      },
      '/tools': {
        target: 'https://api-v2.yourspce.org',
        changeOrigin: true,
        secure: true,
      }
    }
  }
})
```

---

## 踩坑紀錄

### PDF 中文亂碼
- **問題**：@react-pdf/renderer 中文字顯示為方塊
- **原因**：子集字體缺少字符，或多個 PDF 元件註冊同名字體衝突
- **解決**：使用完整字體 + 不同字體家族名稱

### html2canvas CORS 錯誤
- **問題**：`Access to image blocked by CORS policy`
- **解決**：
  1. GCS bucket 設定 CORS
  2. img 標籤加上 `crossOrigin="anonymous"`

### API 端點注意
- ❌ `/api/tools/call` - 錯誤！會回傳 404
- ✅ `/tools/call` - 正確的 MCP 工具端點

### 環境變數策略
**程式碼裡永遠不要寫死 (Hardcode) 網址**

```javascript
// src/services/api.js
const api = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL || '',
  timeout: 30000
})
```
