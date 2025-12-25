# Schema Design Document (SDD)

> 資料庫結構設計文件
> Version: 1.0
> Last Updated: 2024-12-25

---

## 目錄

1. [核心業務表](#1-核心業務表)
2. [流程管理表](#2-流程管理表)
3. [輔助功能表](#3-輔助功能表)
4. [系統表](#4-系統表)
5. [視圖](#5-視圖)
6. [變更歷史](#6-變更歷史)

---

## 1. 核心業務表

### 1.1 branches（場館）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| code | VARCHAR(20) | 場館代碼（唯一） |
| name | VARCHAR(100) | 場館名稱 |
| rental_address | VARCHAR(200) | 租賃地址 |
| city | VARCHAR(50) | 城市（預設: 台中市） |
| district | VARCHAR(50) | 區域 |
| contact_phone | VARCHAR(20) | 聯絡電話 |
| manager_name | VARCHAR(50) | 負責人 |
| status | VARCHAR(20) | 狀態: active/preparing/closed |
| allow_small_scale | BOOLEAN | 是否允許小規模 |
| has_good_relationship | BOOLEAN | 是否有良好關係 |
| tax_office_district | VARCHAR(100) | 稅務局轄區 |
| config | JSONB | 設定 |
| notes | TEXT | 備註 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |

---

### 1.2 customers（客戶）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| legacy_id | VARCHAR(20) | 舊系統 ID（唯一） |
| branch_id | INTEGER | 場館 ID (FK → branches) |
| customer_type | VARCHAR(30) | 類型: individual/sole_proprietorship/company |
| name | VARCHAR(100) | 姓名 |
| company_name | VARCHAR(200) | 公司名稱 |
| company_tax_id | VARCHAR(8) | 統一編號 |
| id_number | VARCHAR(10) | 身分證字號 |
| birthday | DATE | 生日 |
| phone | VARCHAR(20) | 電話 |
| email | VARCHAR(100) | Email |
| address | TEXT | 地址 |
| line_user_id | VARCHAR(100) | LINE User ID |
| line_display_name | VARCHAR(100) | LINE 顯示名稱 |
| invoice_title | VARCHAR(200) | 發票抬頭 |
| invoice_tax_id | VARCHAR(8) | 發票統編 |
| invoice_delivery | VARCHAR(20) | 發票寄送: email/carrier/personal |
| invoice_carrier | VARCHAR(20) | 載具號碼 |
| source_channel | VARCHAR(50) | 來源管道 |
| source_detail | VARCHAR(200) | 來源詳情 |
| referrer_id | INTEGER | 推薦人 ID (FK → customers) |
| accounting_firm_id | INTEGER | 會計事務所 ID (FK → accounting_firms) |
| status | VARCHAR(20) | 狀態: prospect/active/suspended/churned |
| risk_level | VARCHAR(10) | 風險等級: low/medium/high |
| risk_notes | TEXT | 風險備註 |
| metadata | JSONB | 擴展欄位 |
| industry_notes | TEXT | 行業備註 |
| notes | TEXT | 備註 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |
| created_by | INTEGER | 建立者 |

**索引**：
- `idx_customers_branch_id`
- `idx_customers_status`
- `idx_customers_line_user_id`
- `idx_customers_phone`
- `idx_customers_company_tax_id`

---

### 1.3 contracts（合約）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| contract_number | VARCHAR(50) | 合約編號（唯一） |
| customer_id | INTEGER | 客戶 ID (FK → customers) |
| branch_id | INTEGER | 場館 ID (FK → branches) |
| contract_type | VARCHAR(30) | 類型: virtual_office/coworking_fixed/coworking_flexible/meeting_room |
| custom_contract_type | VARCHAR(100) | 自訂合約類型 |
| plan_name | VARCHAR(100) | 方案名稱 |
| rental_address | VARCHAR(200) | 租賃地址 |
| position_number | VARCHAR(20) | 座位編號（如 V05） |
| company_name | VARCHAR(200) | 合約公司名稱 |
| start_date | DATE | 開始日期 |
| end_date | DATE | 結束日期 |
| signed_at | DATE | 簽約日期 |
| original_price | NUMERIC(10,2) | 原價 |
| discount_rate | NUMERIC(5,2) | 折扣率（預設 100） |
| monthly_rent | NUMERIC(10,2) | 月租金 |
| deposit | NUMERIC(10,2) | 押金 |
| deposit_status | VARCHAR(20) | 押金狀態: held/refunded/forfeited |
| payment_cycle | VARCHAR(20) | 繳費週期: monthly/quarterly/semi_annual/annual/biennial |
| payment_day | INTEGER | 繳費日（1-31） |
| status | VARCHAR(20) | 狀態: draft/pending_sign/active/pending_termination/expired/terminated/cancelled |
| broker_name | VARCHAR(100) | 介紹人姓名 |
| broker_firm_id | INTEGER | 介紹事務所 ID (FK → accounting_firms) |
| commission_eligible | BOOLEAN | 是否有佣金資格 |
| commission_paid | BOOLEAN | 佣金是否已付 |
| commission_due_date | DATE | 佣金到期日 |
| addon_services | JSONB | 加值服務 |
| pdf_url | TEXT | PDF 合約 URL |
| pdf_generated_at | TIMESTAMPTZ | PDF 產生時間 |
| renewal_status | VARCHAR(20) | 續約狀態 |
| renewal_notified_at | TIMESTAMPTZ | 續約通知時間 |
| renewal_confirmed_at | TIMESTAMPTZ | 續約確認時間 |
| renewal_paid_at | TIMESTAMPTZ | 續約繳費時間 |
| renewal_invoiced_at | TIMESTAMPTZ | 續約開票時間 |
| renewal_signed_at | TIMESTAMPTZ | 續約簽約時間 |
| renewal_notes | TEXT | 續約備註 |
| invoice_status | VARCHAR(20) | 發票狀態 |
| metadata | JSONB | 擴展欄位 |
| notes | TEXT | 備註 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |
| created_by | INTEGER | 建立者 |

**狀態說明**：
- `draft` - 草稿
- `pending_sign` - 待簽署
- `active` - 生效中
- `pending_termination` - 解約中（v036 新增）
- `expired` - 已到期
- `terminated` - 已終止
- `cancelled` - 已取消

**索引**：
- `idx_contracts_customer_id`
- `idx_contracts_branch_id`
- `idx_contracts_status`
- `idx_contracts_end_date`

---

### 1.4 payments（應收款）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| contract_id | INTEGER | 合約 ID (FK → contracts) |
| customer_id | INTEGER | 客戶 ID (FK → customers) |
| branch_id | INTEGER | 場館 ID (FK → branches) |
| payment_type | VARCHAR(20) | 類型: deposit/rent/addon/penalty/refund |
| payment_period | VARCHAR(20) | 繳費期間（如 2024-12） |
| amount | NUMERIC(10,2) | 金額 |
| late_fee | NUMERIC(10,2) | 滯納金 |
| payment_method | VARCHAR(30) | 付款方式: cash/transfer/credit_card/line_pay |
| payment_status | VARCHAR(20) | 狀態: pending/paid/overdue/waived/cancelled |
| due_date | DATE | 到期日 |
| paid_at | TIMESTAMPTZ | 付款時間 |
| invoice_number | VARCHAR(20) | 發票號碼 |
| invoice_date | DATE | 發票日期 |
| invoice_status | VARCHAR(20) | 發票狀態: pending/issued/void |
| overdue_days | INTEGER | 逾期天數 |
| waived_at | TIMESTAMPTZ | 免收時間 |
| waive_reason | TEXT | 免收原因 |
| cancelled_at | TIMESTAMPTZ | 取消時間（v033 新增） |
| cancel_reason | TEXT | 取消原因（v033 新增） |
| metadata | JSONB | 擴展欄位 |
| notes | TEXT | 備註 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |

**狀態說明**：
- `pending` - 待繳
- `paid` - 已繳
- `overdue` - 逾期
- `waived` - 免收
- `cancelled` - 已取消（合約終止時標記）

**索引**：
- `idx_payments_contract_id`
- `idx_payments_customer_id`
- `idx_payments_due_date`
- `idx_payments_status`
- `idx_payments_period`

---

### 1.5 commissions（佣金）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| accounting_firm_id | INTEGER | 會計事務所 ID |
| customer_id | INTEGER | 客戶 ID |
| contract_id | INTEGER | 合約 ID |
| amount | NUMERIC(10,2) | 佣金金額 |
| based_on_rent | NUMERIC(10,2) | 計算基礎（月租） |
| contract_start | DATE | 合約開始日 |
| eligible_date | DATE | 可付款日（合約滿 6 個月） |
| status | VARCHAR(20) | 狀態: pending/eligible/paid/cancelled |
| paid_at | DATE | 付款日期 |
| payment_method | VARCHAR(50) | 付款方式 |
| payment_reference | VARCHAR(100) | 付款參考 |
| metadata | JSONB | 擴展欄位 |
| notes | TEXT | 備註 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |

---

### 1.6 accounting_firms（會計事務所）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| name | VARCHAR(200) | 名稱 |
| short_name | VARCHAR(50) | 簡稱 |
| contact_person | VARCHAR(100) | 聯絡人 |
| phone | VARCHAR(20) | 電話 |
| email | VARCHAR(100) | Email |
| address | TEXT | 地址 |
| commission_rate | NUMERIC(5,2) | 佣金比率（預設 100） |
| payment_terms | VARCHAR(200) | 付款條件 |
| status | VARCHAR(20) | 狀態: active/inactive/suspended |
| total_referrals | INTEGER | 總推薦數 |
| total_commission_paid | NUMERIC(15,2) | 已付佣金總額 |
| metadata | JSONB | 擴展欄位 |
| notes | TEXT | 備註 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |

---

## 2. 流程管理表

### 2.1 renewal_cases（續約案件）

> 來源: 033_ddd_domain_tables.sql

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| contract_id | INTEGER | 合約 ID (FK → contracts) |
| status | VARCHAR(20) | 狀態: created/notified/confirmed/paid/invoiced/completed/cancelled |
| notified_at | TIMESTAMPTZ | 通知時間 |
| confirmed_at | TIMESTAMPTZ | 確認時間 |
| paid_at | TIMESTAMPTZ | 繳費時間 |
| invoiced_at | TIMESTAMPTZ | 開票時間 |
| signed_at | TIMESTAMPTZ | 簽約時間 |
| cancelled_at | TIMESTAMPTZ | 取消時間 |
| new_contract_id | INTEGER | 新合約 ID |
| cancel_reason | TEXT | 取消原因 |
| reserved_position_number | INTEGER | 預留座位 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |
| created_by | TEXT | 建立者 |

**約束**：每個合約只能有一個進行中的續約案件

---

### 2.2 termination_cases（解約案件）

> 來源: 036_termination_cases.sql

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| contract_id | INTEGER | 合約 ID (FK → contracts) |
| termination_type | VARCHAR(20) | 類型: early/not_renewing/breach |
| status | VARCHAR(20) | 狀態: notice_received/moving_out/pending_doc/pending_settlement/completed/cancelled |
| notice_date | DATE | 通知日期 |
| expected_end_date | DATE | 預計搬離日 |
| actual_move_out | DATE | 實際搬離日 |
| doc_submitted_date | DATE | 公文送件日 |
| doc_approved_date | DATE | 公文核准日 |
| settlement_date | DATE | 結算日期 |
| refund_date | DATE | 退款日期 |
| cancelled_at | TIMESTAMPTZ | 取消時間 |
| deposit_amount | NUMERIC(10,2) | 押金金額 |
| deduction_days | INTEGER | 扣除天數 |
| daily_rate | NUMERIC(10,2) | 日租金 |
| deduction_amount | NUMERIC(10,2) | 扣除金額 |
| other_deductions | NUMERIC(10,2) | 其他扣款 |
| other_deduction_notes | TEXT | 其他扣款說明 |
| refund_amount | NUMERIC(10,2) | 退還金額 |
| refund_method | VARCHAR(20) | 退款方式: cash/transfer/check |
| refund_account | TEXT | 退款帳戶 |
| refund_receipt | TEXT | 收據編號 |
| checklist | JSONB | Checklist（8 項） |
| notes | TEXT | 備註 |
| cancel_reason | TEXT | 取消原因 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |
| created_by | TEXT | 建立者 |

**Checklist 欄位**：
```json
{
  "notice_confirmed": false,
  "belongings_removed": false,
  "keys_returned": false,
  "room_inspected": false,
  "doc_submitted": false,
  "doc_approved": false,
  "settlement_calculated": false,
  "refund_processed": false
}
```

**押金結算公式**：
```
扣除天數 = MAX(0, 公文核准日 - 合約到期日)
日租金 = 月租 / 30
扣除金額 = 扣除天數 × 日租金
退還金額 = 押金 - 扣除金額 - 其他扣款
```

**約束**：每個合約只能有一個進行中的解約案件

---

### 2.3 waive_requests（免收申請）

> 來源: 033_ddd_domain_tables.sql

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| payment_id | INTEGER | 應收款 ID (FK → payments) |
| requested_by | TEXT | 申請人 |
| request_reason | TEXT | 申請原因 |
| request_amount | NUMERIC(10,2) | 申請金額 |
| status | VARCHAR(20) | 狀態: pending/approved/rejected |
| approved_by | TEXT | 核准人 |
| approved_at | TIMESTAMPTZ | 核准時間 |
| reject_reason | TEXT | 駁回原因 |
| idempotency_key | VARCHAR(64) | 冪等性 Key |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |

---

### 2.4 batch_tasks（批量任務）

> 來源: 033_ddd_domain_tables.sql

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | VARCHAR(36) | 主鍵（UUID） |
| task_type | VARCHAR(50) | 類型: send_reminder/send_renewal_notice |
| status | VARCHAR(20) | 狀態: pending/processing/completed/partial_success/failed |
| total_count | INTEGER | 總數 |
| success_count | INTEGER | 成功數 |
| failed_count | INTEGER | 失敗數 |
| created_by | TEXT | 建立者 |
| created_at | TIMESTAMPTZ | 建立時間 |
| started_at | TIMESTAMPTZ | 開始時間 |
| completed_at | TIMESTAMPTZ | 完成時間 |

**子表: batch_task_items**

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| task_id | VARCHAR(36) | 任務 ID (FK → batch_tasks) |
| target_id | INTEGER | 目標 ID |
| target_type | VARCHAR(20) | 目標類型: payment/contract |
| status | VARCHAR(20) | 狀態: pending/success/failed |
| error_code | VARCHAR(50) | 錯誤代碼 |
| error_message | TEXT | 錯誤訊息 |
| processed_at | TIMESTAMPTZ | 處理時間 |

---

## 3. 輔助功能表

### 3.1 quotes（報價單）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| quote_number | VARCHAR(50) | 報價單號（唯一） |
| customer_id | INTEGER | 客戶 ID |
| branch_id | INTEGER | 場館 ID |
| contact_name | VARCHAR(100) | 聯絡人姓名 |
| contact_phone | VARCHAR(20) | 聯絡電話 |
| contact_email | VARCHAR(100) | 聯絡 Email |
| line_user_id | VARCHAR(100) | LINE User ID |
| contract_type | VARCHAR(30) | 合約類型 |
| custom_contract_type | VARCHAR(100) | 自訂合約類型 |
| plan_name | VARCHAR(100) | 方案名稱 |
| start_date | DATE | 開始日期 |
| end_date | DATE | 結束日期 |
| original_price | NUMERIC(10,2) | 原價 |
| discount_rate | NUMERIC(5,2) | 折扣率 |
| monthly_rent | NUMERIC(10,2) | 月租 |
| deposit | NUMERIC(10,2) | 押金 |
| status | VARCHAR(20) | 狀態: draft/sent/viewed/accepted/rejected/expired/converted |
| converted_contract_id | INTEGER | 轉換的合約 ID |
| valid_until | DATE | 有效期限 |
| sent_at | TIMESTAMPTZ | 發送時間 |
| viewed_at | TIMESTAMPTZ | 檢視時間 |
| notes | TEXT | 備註 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |

---

### 3.2 invoices（發票）

> 來源: 033_ddd_domain_tables.sql

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| contract_id | INTEGER | 合約 ID |
| invoice_number | VARCHAR(20) | 發票號碼（唯一） |
| invoice_date | DATE | 發票日期 |
| amount | NUMERIC(10,2) | 金額 |
| snapshot_company_name | VARCHAR(200) | 快照：公司名稱 |
| snapshot_tax_id | VARCHAR(20) | 快照：統編 |
| snapshot_address | TEXT | 快照：地址 |
| status | VARCHAR(20) | 狀態: issued/voided |
| voided_at | TIMESTAMPTZ | 作廢時間 |
| void_reason | TEXT | 作廢原因 |
| allowance_amount | NUMERIC(10,2) | 折讓金額 |
| allowance_number | VARCHAR(20) | 折讓單號 |
| api_response | JSONB | API 回應 |
| created_at | TIMESTAMPTZ | 建立時間 |
| created_by | TEXT | 建立者 |

**關聯表: payment_invoices**

| 欄位 | 類型 | 說明 |
|------|------|------|
| payment_id | INTEGER | 應收款 ID (PK, FK) |
| invoice_id | INTEGER | 發票 ID (PK, FK) |
| created_at | TIMESTAMPTZ | 建立時間 |

---

### 3.3 legal_letters（存證信函）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| contract_id | INTEGER | 合約 ID |
| payment_id | INTEGER | 應收款 ID（可 NULL） |
| customer_id | INTEGER | 客戶 ID |
| letter_type | VARCHAR(30) | 類型 |
| recipient_name | VARCHAR(100) | 收件人姓名 |
| recipient_address | TEXT | 收件人地址 |
| amount_due | NUMERIC(10,2) | 欠款金額 |
| content | TEXT | 內容 |
| status | VARCHAR(20) | 狀態: draft/sent/delivered/returned |
| sent_at | TIMESTAMPTZ | 發送時間 |
| delivery_reference | VARCHAR(100) | 寄送編號 |
| notes | TEXT | 備註 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |

---

### 3.4 floor_plans（平面圖）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| branch_id | INTEGER | 場館 ID |
| name | VARCHAR(100) | 名稱 |
| floor_number | INTEGER | 樓層 |
| dimensions | JSONB | 尺寸設定 |
| positions | JSONB | 座位配置 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |

---

### 3.5 service_plans（服務方案）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| branch_id | INTEGER | 場館 ID（NULL = 全通用） |
| name | VARCHAR(100) | 方案名稱 |
| contract_type | VARCHAR(30) | 合約類型 |
| description | TEXT | 說明 |
| base_price | NUMERIC(10,2) | 基礎價格 |
| revenue_type | VARCHAR(30) | 營收類型: rental/service/other |
| features | JSONB | 功能列表 |
| is_active | BOOLEAN | 是否啟用 |
| sort_order | INTEGER | 排序 |
| created_at | TIMESTAMPTZ | 建立時間 |
| updated_at | TIMESTAMPTZ | 更新時間 |

---

### 3.6 notification_logs（通知記錄）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| notification_type | VARCHAR(50) | 類型: payment_reminder/renewal_notice |
| channel | VARCHAR(20) | 管道: line/email/sms |
| recipient_id | INTEGER | 收件人 ID（客戶） |
| recipient_identifier | VARCHAR(100) | 收件人識別（如 LINE ID） |
| related_type | VARCHAR(50) | 關聯類型: payment/contract |
| related_id | INTEGER | 關聯 ID |
| message_content | TEXT | 訊息內容 |
| status | VARCHAR(20) | 狀態: sent/failed |
| error_message | TEXT | 錯誤訊息 |
| sent_at | TIMESTAMPTZ | 發送時間 |
| created_at | TIMESTAMPTZ | 建立時間 |

---

## 4. 系統表

### 4.1 audit_logs（審計日誌）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | BIGSERIAL | 主鍵 |
| table_name | VARCHAR(50) | 表名 |
| record_id | INTEGER | 記錄 ID |
| action | VARCHAR(10) | 動作: INSERT/UPDATE/DELETE |
| old_data | JSONB | 舊資料 |
| new_data | JSONB | 新資料 |
| changed_fields | TEXT[] | 變更欄位 |
| user_id | INTEGER | 使用者 ID |
| user_role | VARCHAR(20) | 使用者角色 |
| ip_address | INET | IP 位址 |
| created_at | TIMESTAMPTZ | 建立時間 |

---

### 4.2 system_settings（系統設定）

| 欄位 | 類型 | 說明 |
|------|------|------|
| id | SERIAL | 主鍵 |
| setting_key | VARCHAR(100) | 設定鍵（唯一） |
| setting_value | TEXT | 設定值 |
| setting_type | VARCHAR(20) | 類型: string/number/boolean/json |
| description | TEXT | 說明 |
| updated_at | TIMESTAMPTZ | 更新時間 |
| updated_by | INTEGER | 更新者 |

---

## 5. 視圖

| 視圖 | 說明 |
|------|------|
| `v_customer_summary` | 客戶摘要（含合約/繳費統計） |
| `v_payments_due` | 應收款列表（待繳/逾期） |
| `v_renewal_reminders` | 續約提醒（90 天內到期） |
| `v_renewal_cases` | 續約案件視圖 |
| `v_termination_cases` | 解約案件視圖 |
| `v_commission_tracker` | 佣金追蹤 |
| `v_branch_revenue_summary` | 場館營收摘要 |
| `v_overdue_details` | 逾期款項詳情 |
| `v_line_user_lookup` | LINE 用戶查詢 |
| `v_today_tasks` | 今日待辦事項 |
| `v_waive_requests` | 免收申請視圖 |
| `v_floor_positions` | 座位狀態視圖 |
| `v_quotes` | 報價單視圖 |

---

## 6. 變更歷史

| 版本 | 日期 | Migration | 變更內容 |
|------|------|-----------|----------|
| v033 | 2024-12-22 | 033_ddd_domain_tables.sql | 新增 renewal_cases, waive_requests, invoices, batch_tasks；payments 新增 cancelled 狀態 |
| v034 | 2024-12-23 | 034_ai_learning.sql | 新增 AI 學習相關表 |
| v036 | 2024-12-25 | 036_termination_cases.sql | 新增 termination_cases 表；contracts.status 新增 pending_termination |

---

## 附錄：關聯圖

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Hour Jungle CRM                            │
│                                                                     │
│  ┌──────────────┐        ┌──────────────┐        ┌──────────────┐  │
│  │   branches   │◄───────│   customers  │───────►│accounting_firms│ │
│  └──────────────┘        └──────────────┘        └──────────────┘  │
│         │                       │                                   │
│         │                       │                                   │
│         ▼                       ▼                                   │
│  ┌──────────────────────────────────────────────────┐              │
│  │                    contracts                      │              │
│  │  (核心實體 - 生命週期驅動一切)                    │              │
│  └──────────────────────────────────────────────────┘              │
│         │                       │                       │           │
│         │                       │                       │           │
│         ▼                       ▼                       ▼           │
│  ┌──────────────┐        ┌──────────────┐        ┌──────────────┐  │
│  │   payments   │        │renewal_cases │        │termination   │  │
│  │  (應收款)    │        │  (續約流程)  │        │   _cases     │  │
│  └──────────────┘        └──────────────┘        │  (解約流程)  │  │
│         │                                         └──────────────┘  │
│         │                                                           │
│         ▼                                                           │
│  ┌──────────────┐        ┌──────────────┐                          │
│  │waive_requests│        │   invoices   │                          │
│  │  (免收申請)  │        │   (發票)     │                          │
│  └──────────────┘        └──────────────┘                          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```
