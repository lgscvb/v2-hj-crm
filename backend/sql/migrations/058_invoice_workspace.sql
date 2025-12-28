-- 058_invoice_workspace.sql
-- 發票流程 Workspace 視圖 - Decision Table 模式
-- Date: 2025-12-28

-- ============================================================================
-- 1. 發票 Workspace 視圖
-- ============================================================================

DROP VIEW IF EXISTS v_invoice_workspace CASCADE;

CREATE VIEW v_invoice_workspace AS
WITH
-- 已開發票的付款（透過 payments.invoice_number）
invoiced_payments AS (
    SELECT
        p.id AS payment_id,
        p.invoice_number,
        p.invoice_date,
        p.invoice_status
    FROM payments p
    WHERE p.invoice_number IS NOT NULL
)
SELECT
    -- 付款基本資訊
    p.id AS payment_id,
    p.contract_id,
    p.customer_id,
    p.branch_id,
    p.payment_type,
    p.payment_period,
    p.amount,
    p.payment_status,
    p.due_date,
    p.paid_at,

    -- 發票資訊
    p.invoice_number,
    p.invoice_date,
    p.invoice_status,

    -- 合約資訊
    c.contract_number,
    c.company_name AS contract_company_name,
    c.position_number,

    -- 客戶資訊
    cust.name AS customer_name,
    cust.company_name AS customer_company_name,
    cust.company_tax_id,
    cust.invoice_tax_id,
    cust.invoice_title,
    cust.invoice_delivery,
    cust.phone AS customer_phone,
    cust.email AS customer_email,

    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,

    -- ========== 計算欄位 ==========

    -- 流程識別
    'invoice'::TEXT AS process_key,
    p.id AS entity_id,

    -- 標題（供 Kanban 卡片顯示）
    CONCAT(c.position_number, ' ', cust.name, ' (', p.payment_period, ')') AS title,

    -- 有效統編（優先使用發票專用，否則用公司統編）
    COALESCE(cust.invoice_tax_id, cust.company_tax_id) AS effective_tax_id,

    -- 付款後天數
    CASE
        WHEN p.paid_at IS NOT NULL
        THEN EXTRACT(DAY FROM NOW() - p.paid_at)::INT
        ELSE NULL
    END AS days_since_paid,

    -- 是否需要開發票（已付款但未開票）
    CASE
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
        THEN TRUE
        ELSE FALSE
    END AS needs_invoice,

    -- 是否逾期開票（付款後超過 3 天）
    CASE
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
         AND p.paid_at < NOW() - INTERVAL '3 days'
        THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    -- ========== Decision Table（卡點判斷，first-match wins） ==========

    CASE
        -- 已開票完成 = 無卡點
        WHEN p.invoice_status = 'issued'
        THEN NULL

        -- 未付款 = 無需開票
        WHEN p.payment_status != 'paid'
        THEN NULL

        -- 優先序 1：缺少統編（需要開發票但沒有統編）
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
         AND COALESCE(cust.invoice_tax_id, cust.company_tax_id) IS NULL
        THEN 'need_tax_id'

        -- 優先序 2：開票逾期（付款後 3 天未開票）
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
         AND p.paid_at < NOW() - INTERVAL '3 days'
        THEN 'invoice_overdue'

        -- 優先序 3：待開票（剛付款需開票）
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
        THEN 'need_issue_invoice'

        -- 優先序 4：作廢待重開
        WHEN p.invoice_status = 'void'
        THEN 'need_reissue'

        ELSE NULL
    END AS decision_blocked_by,

    -- 下一步行動（繁體中文，顯示用）
    CASE
        WHEN p.invoice_status = 'issued'
        THEN NULL
        WHEN p.payment_status != 'paid'
        THEN NULL
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
         AND COALESCE(cust.invoice_tax_id, cust.company_tax_id) IS NULL
        THEN '請補齊客戶統一編號'
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
         AND p.paid_at < NOW() - INTERVAL '3 days'
        THEN '儘速開立發票'
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
        THEN '開立發票'
        WHEN p.invoice_status = 'void'
        THEN '重新開立發票'
        ELSE NULL
    END AS decision_next_action,

    -- 行動代碼（程式用）
    CASE
        WHEN p.invoice_status = 'issued'
        THEN NULL
        WHEN p.payment_status != 'paid'
        THEN NULL
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
         AND COALESCE(cust.invoice_tax_id, cust.company_tax_id) IS NULL
        THEN 'UPDATE_CUSTOMER'
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
        THEN 'ISSUE_INVOICE'
        WHEN p.invoice_status = 'void'
        THEN 'ISSUE_INVOICE'
        ELSE NULL
    END AS decision_action_key,

    -- 責任人
    CASE
        WHEN p.invoice_status = 'issued'
        THEN NULL
        WHEN p.payment_status != 'paid'
        THEN NULL
        WHEN COALESCE(cust.invoice_tax_id, cust.company_tax_id) IS NULL
        THEN 'Sales'  -- 補統編是業務責任
        ELSE 'Finance'
    END AS decision_owner,

    -- 優先級
    CASE
        WHEN p.invoice_status = 'issued'
        THEN NULL
        WHEN p.payment_status != 'paid'
        THEN NULL
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
         AND COALESCE(cust.invoice_tax_id, cust.company_tax_id) IS NULL
        THEN 'high'  -- 缺統編阻擋開票
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
         AND p.paid_at < NOW() - INTERVAL '3 days'
        THEN 'high'  -- 逾期
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
        THEN 'medium'
        WHEN p.invoice_status = 'void'
        THEN 'medium'
        ELSE NULL
    END AS decision_priority,

    -- 應處理日期（付款日 + 3 天）
    CASE
        WHEN p.paid_at IS NOT NULL
        THEN (p.paid_at + INTERVAL '3 days')::DATE
        ELSE NULL
    END AS decision_due_date,

    -- Workspace URL
    CONCAT('/payments/', p.id, '/invoice') AS workspace_url

FROM payments p
JOIN contracts c ON p.contract_id = c.id
JOIN customers cust ON p.customer_id = cust.id
JOIN branches b ON p.branch_id = b.id
WHERE p.amount > 0;

COMMENT ON VIEW v_invoice_workspace IS '發票流程 Workspace 視圖 - Decision Table 模式';

GRANT SELECT ON v_invoice_workspace TO anon, authenticated;

-- ============================================================================
-- 2. 發票待辦清單視圖（僅顯示需處理項目）
-- ============================================================================

DROP VIEW IF EXISTS v_invoice_queue CASCADE;

CREATE VIEW v_invoice_queue AS
SELECT *
FROM v_invoice_workspace
WHERE decision_blocked_by IS NOT NULL
ORDER BY
    CASE decision_priority
        WHEN 'urgent' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low' THEN 4
        ELSE 5
    END,
    is_overdue DESC,
    decision_due_date ASC NULLS LAST;

COMMENT ON VIEW v_invoice_queue IS '發票待辦清單 - 僅顯示需處理項目';

GRANT SELECT ON v_invoice_queue TO anon, authenticated;

-- ============================================================================
-- 3. Dashboard 統計視圖
-- ============================================================================

DROP VIEW IF EXISTS v_invoice_dashboard_stats CASCADE;

CREATE VIEW v_invoice_dashboard_stats AS
SELECT
    COUNT(*) FILTER (WHERE decision_blocked_by IS NOT NULL) AS total_action_needed,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_tax_id') AS need_tax_id_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'invoice_overdue') AS overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_issue_invoice') AS pending_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_reissue') AS reissue_count,
    SUM(amount) FILTER (WHERE decision_blocked_by IS NOT NULL) AS total_pending_amount
FROM v_invoice_workspace;

COMMENT ON VIEW v_invoice_dashboard_stats IS '發票 Dashboard 統計';

GRANT SELECT ON v_invoice_dashboard_stats TO anon, authenticated;
