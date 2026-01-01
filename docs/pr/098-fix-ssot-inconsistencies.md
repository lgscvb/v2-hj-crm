# PR: 修復 SSOT 不一致問題

## 問題摘要

Code review 發現多處邏輯衝突，會導致功能失效或資料錯誤。

## 修復項目

### 高優先級

| # | 問題 | 檔案 | 修復方式 |
|---|------|------|----------|
| 1 | completion_score 7 vs 5 顯示 | Dashboard.jsx, ContractDetail.jsx | 改為 /7 顯示 |
| 2 | renewal_update_invoice_status 已停用 | Renewals.jsx, ContractDetail.jsx, api.js | 移除呼叫，改用 invoice 流程 |
| 3 | signing_overdue → SEND_FOR_SIGN 錯誤 | v_renewal_queue | 改為 SEND_SIGN_REMINDER |

### 中優先級

| # | 問題 | 檔案 | 修復方式 |
|---|------|------|----------|
| 4 | customer 欄位映射不完整 | v_contract_workspace, api.js | 補齊 address, risk_level |

## 變更檔案

### 前端
- `frontend/src/pages/Dashboard.jsx` - completion_score 改 7 步驟
- `frontend/src/pages/ContractDetail.jsx` - completion_score 改 7 步驟 + 移除 invoice flag
- `frontend/src/pages/Renewals.jsx` - 移除 invoice flag 操作
- `frontend/src/services/api.js` - 移除 updateInvoiceStatus + 補齊 customer 欄位

### 後端
- `backend/sql/migrations/098_fix_ssot_inconsistencies.sql` - 修復 View

## 測試計劃

- [ ] Dashboard 進度顯示 X/7
- [ ] ContractDetail 進度顯示 X/7
- [ ] 續約頁面無發票狀態按鈕（或改用正確流程）
- [ ] signing_overdue 案件點擊按鈕可正常催簽
- [ ] ContractDetail 編輯客戶時 address/risk_level 正確保存
- [ ] 新建合約完整流程
- [ ] 平面圖顯示正常

## 相關 Issue

- Migration 097 修復 deprecated fields trigger
- SSOT 重構（前端改用 View 計算欄位）

---
Date: 2026-01-01
