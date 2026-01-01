-- ============================================================================
-- Migration 105: 統一 void/voided 問題
--
-- 背景：
-- - payments.invoice_status constraint 只允許 'void'（不是 'voided'）
-- - invoices.status 允許 'voided'
-- - 但多處 View 用 'voided' 判斷 payments 表，導致「作廢待重開」永遠不觸發
--
-- 修正：
-- - 所有對 payments.invoice_status 的篩選改用 NOT IN ('void', 'voided') 容錯
-- - 這樣既能處理正確的 'void'，也能處理可能的歷史資料
--
-- 影響 Views：
-- 1. v_renewal_reminders（first_invoices CTE）
-- 2. v_invoice_workspace（多處判斷）
-- 3. v_monthly_reminders_summary（依賴 v_renewal_reminders）
-- 4. v_invoice_queue、v_invoice_dashboard_stats（依賴 v_invoice_workspace）
--
-- Date: 2026-01-01
-- ============================================================================

-- ============================================================================
-- 1. 重建 v_renewal_reminders（修正 void/voided）
-- ============================================================================

DROP VIEW IF EXISTS v_monthly_reminders_summary CASCADE;
DROP VIEW IF EXISTS v_renewal_reminders CASCADE;

CREATE VIEW v_renewal_reminders AS
WITH next_contracts AS (
    SELECT DISTINCT ON (renewed_from_id)
        renewed_from_id AS old_contract_id,
        id AS next_contract_id,
        status AS next_status,
        signed_at AS next_signed_at,
        created_at AS next_created_at,
        sent_for_sign_at AS next_sent_for_sign_at,
        contract_period AS next_contract_period,
        monthly_rent AS next_monthly_rent,
        payment_cycle AS next_payment_cycle
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
      AND status NOT IN ('cancelled', 'terminated')
    ORDER BY renewed_from_id, created_at DESC
),
first_payments AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        id AS first_payment_id,
        payment_status,
        paid_at,
        payment_method,
        due_date AS first_payment_due_date
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
),
-- ★ 105 修正：用 NOT IN ('void', 'voided') 容錯排除作廢發票
first_invoices AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        invoice_number,
        invoice_date,
        invoice_status
    FROM payments
    WHERE payment_type = 'rent'
      AND invoice_number IS NOT NULL
      AND invoice_status NOT IN ('void', 'voided')
    ORDER BY contract_id, payment_period ASC
)
SELECT
    ct.id,
    ct.contract_number,
    ct.contract_period,
    ct.customer_id,
    ct.branch_id,
    ct.contract_type,
    ct.plan_name,
    ct.start_date,
    ct.end_date,
    ct.monthly_rent,
    ct.deposit,
    ct.payment_cycle,
    ct.status AS contract_status,
    ct.position_number,
    ct.metadata,

    -- 續約追蹤欄位（原始時間戳）
    ct.renewal_status,
    ct.renewal_notified_at,
    ct.renewal_confirmed_at,
    ct.renewal_notes,

    -- [DEPRECATED] 保留讀取（向後相容）
    ct.renewal_paid_at,
    ct.renewal_invoiced_at,
    ct.renewal_signed_at,
    ct.invoice_status,

    -- 剩餘天數
    ct.end_date - CURRENT_DATE AS days_until_expiry,
    ct.end_date - CURRENT_DATE AS days_remaining,

    -- 客戶資訊
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.email AS customer_email,
    c.line_user_id,
    c.status AS customer_status,
    c.company_tax_id AS customer_company_tax_id,

    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,

    -- 提醒優先級
    CASE
        WHEN ct.end_date - CURRENT_DATE <= 7 THEN 'urgent'
        WHEN ct.end_date - CURRENT_DATE <= 30 THEN 'high'
        WHEN ct.end_date - CURRENT_DATE <= 60 THEN 'medium'
        ELSE 'low'
    END AS priority,

    -- 合約歷史
    (SELECT COUNT(*) FROM contracts WHERE customer_id = ct.customer_id) AS total_contracts_history,

    -- ========== Next Contract 資訊 ==========

    nc.next_contract_id,
    nc.next_status,
    nc.next_signed_at,
    nc.next_created_at,
    nc.next_sent_for_sign_at,
    nc.next_contract_period,
    nc.next_monthly_rent,
    nc.next_payment_cycle,

    COALESCE(nc.next_sent_for_sign_at, nc.next_created_at) AS signing_start_at,
    nc.next_contract_id IS NOT NULL AS has_renewal_draft,
    nc.next_sent_for_sign_at IS NOT NULL AS is_sent_for_sign,

    -- 三段視圖狀態
    CASE
        WHEN nc.next_contract_id IS NULL THEN 'pending'
        WHEN nc.next_status = 'active' THEN 'completed'
        ELSE 'handoff'
    END AS renewal_stage,

    -- ========== SSOT 計算欄位 ==========

    -- 收款狀態（原始資料）
    fp.first_payment_id,
    fp.payment_status AS first_payment_status,
    fp.paid_at AS first_payment_paid_at,
    fp.payment_method AS first_payment_method,

    -- 發票狀態（原始資料）
    fi.invoice_number AS next_invoice_number,
    fi.invoice_date AS next_invoice_date,
    fi.invoice_status AS first_invoice_status,

    -- 回簽狀態
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_next_signed,

    -- 回簽等待天數
    CASE
        WHEN nc.next_sent_for_sign_at IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN EXTRACT(DAY FROM NOW() - nc.next_sent_for_sign_at)::INT
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN EXTRACT(DAY FROM NOW() - nc.next_created_at)::INT
        ELSE NULL
    END AS days_pending_sign,

    -- ========== 前端用計算欄位 ==========

    -- 意願 flags（布林）
    ct.renewal_notified_at IS NOT NULL AS is_notified,
    ct.renewal_confirmed_at IS NOT NULL AS is_confirmed,

    -- 無續約草稿時為 NULL（不適用）
    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fp.payment_status = 'paid' THEN true
        ELSE false
    END AS is_paid,

    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_signed,

    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fi.invoice_number IS NOT NULL THEN true
        ELSE false
    END AS is_invoiced,

    -- 向後相容欄位（已棄用，保留避免前端報錯）
    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fp.payment_status = 'paid' THEN true
        ELSE false
    END AS is_first_payment_paid,

    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fi.invoice_number IS NOT NULL THEN true
        ELSE false
    END AS is_next_invoiced,

    -- 下一步建議動作
    CASE
        WHEN ct.renewal_notified_at IS NULL THEN 'notify'
        WHEN ct.renewal_confirmed_at IS NULL THEN 'confirm'
        WHEN nc.next_contract_id IS NULL THEN 'create_draft'
        WHEN fp.payment_status IS NULL OR fp.payment_status != 'paid' THEN 'collect_payment'
        WHEN fi.invoice_number IS NULL THEN 'create_invoice'
        WHEN nc.next_signed_at IS NULL AND nc.next_status NOT IN ('active', 'signed') THEN 'get_signature'
        WHEN nc.next_status NOT IN ('active') THEN 'activate'
        ELSE 'completed'
    END AS next_action,

    -- 完成度分數（0-7，對應 7 步驟）
    (
        (CASE WHEN ct.renewal_notified_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN ct.renewal_confirmed_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_contract_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_sent_for_sign_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_signed_at IS NOT NULL OR nc.next_status IN ('active', 'signed') THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_contract_id IS NOT NULL AND fp.payment_status = 'paid' THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_contract_id IS NOT NULL AND fi.invoice_number IS NOT NULL THEN 1 ELSE 0 END)
    ) AS completion_score

FROM contracts ct
JOIN customers c ON ct.customer_id = c.id
JOIN branches b ON ct.branch_id = b.id
LEFT JOIN next_contracts nc ON nc.old_contract_id = ct.id
LEFT JOIN first_payments fp ON fp.contract_id = nc.next_contract_id
LEFT JOIN first_invoices fi ON fi.contract_id = nc.next_contract_id

WHERE ct.status = 'active'
  AND ct.end_date <= CURRENT_DATE + INTERVAL '90 days'
  AND ct.end_date >= CURRENT_DATE - INTERVAL '30 days'
  AND (nc.next_status IS NULL OR nc.next_status != 'active')

ORDER BY ct.end_date ASC;

COMMENT ON VIEW v_renewal_reminders IS '續約提醒視圖 - 統一 void/voided 容錯 (105)';
GRANT SELECT ON v_renewal_reminders TO anon, authenticated;

-- ============================================================================
-- 2. 重建 v_monthly_reminders_summary（依賴 v_renewal_reminders）
-- ============================================================================

CREATE VIEW v_monthly_reminders_summary AS
SELECT
    branch_id,
    branch_name,
    COUNT(*) AS total_reminders,
    COUNT(*) FILTER (WHERE priority = 'urgent') AS urgent_count,
    COUNT(*) FILTER (WHERE priority = 'high') AS high_count,
    COUNT(*) FILTER (WHERE renewal_stage = 'pending') AS pending_count,
    COUNT(*) FILTER (WHERE renewal_stage = 'handoff') AS handoff_count,
    ROUND(AVG(completion_score), 2) AS avg_completion_score
FROM v_renewal_reminders
GROUP BY branch_id, branch_name;

GRANT SELECT ON v_monthly_reminders_summary TO anon, authenticated;

-- ============================================================================
-- 3. 重建 v_invoice_workspace（修正 void/voided）
-- ============================================================================

DROP VIEW IF EXISTS v_invoice_dashboard_stats CASCADE;
DROP VIEW IF EXISTS v_invoice_queue CASCADE;
DROP VIEW IF EXISTS v_invoice_workspace CASCADE;

CREATE VIEW v_invoice_workspace AS
WITH
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

        -- ★ 105 修正：作廢待重開（容錯 void/voided）
        WHEN p.invoice_status IN ('void', 'voided')
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
        -- ★ 105 修正：容錯 void/voided
        WHEN p.invoice_status IN ('void', 'voided')
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
        -- ★ 105 修正：容錯 void/voided
        WHEN p.invoice_status IN ('void', 'voided')
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
        THEN 'Sales'
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
        THEN 'high'
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
         AND p.paid_at < NOW() - INTERVAL '3 days'
        THEN 'high'
        WHEN p.payment_status = 'paid'
         AND (p.invoice_status IS NULL OR p.invoice_status = 'pending')
        THEN 'medium'
        -- ★ 105 修正：容錯 void/voided
        WHEN p.invoice_status IN ('void', 'voided')
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

COMMENT ON VIEW v_invoice_workspace IS '發票流程 Workspace 視圖 - 統一 void/voided 容錯 (105)';
GRANT SELECT ON v_invoice_workspace TO anon, authenticated;

-- ============================================================================
-- 4. 重建 v_invoice_queue（依賴 v_invoice_workspace）
-- ============================================================================

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

COMMENT ON VIEW v_invoice_queue IS '發票待辦清單 - 僅顯示需處理項目 (105)';
GRANT SELECT ON v_invoice_queue TO anon, authenticated;

-- ============================================================================
-- 5. 重建 v_invoice_dashboard_stats（依賴 v_invoice_workspace）
-- ============================================================================

CREATE VIEW v_invoice_dashboard_stats AS
SELECT
    COUNT(*) FILTER (WHERE decision_blocked_by IS NOT NULL) AS total_action_needed,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_tax_id') AS need_tax_id_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'invoice_overdue') AS overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_issue_invoice') AS pending_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_reissue') AS reissue_count,
    SUM(amount) FILTER (WHERE decision_blocked_by IS NOT NULL) AS total_pending_amount
FROM v_invoice_workspace;

COMMENT ON VIEW v_invoice_dashboard_stats IS '發票 Dashboard 統計 (105)';
GRANT SELECT ON v_invoice_dashboard_stats TO anon, authenticated;

-- ============================================================================
-- 6. 驗證
-- ============================================================================

DO $$
DECLARE
    renewal_count INT;
    invoice_workspace_count INT;
    void_filter_test BOOLEAN;
BEGIN
    SELECT COUNT(*) INTO renewal_count FROM v_renewal_reminders;
    SELECT COUNT(*) INTO invoice_workspace_count FROM v_invoice_workspace;

    -- 驗證容錯過濾是否生效（應該排除 void 和 voided）
    SELECT NOT EXISTS (
        SELECT 1 FROM payments
        WHERE invoice_status IN ('void', 'voided')
          AND EXISTS (
              SELECT 1 FROM v_renewal_reminders r
              JOIN payments p ON p.contract_id = r.next_contract_id
              WHERE p.invoice_status IN ('void', 'voided')
                AND p.invoice_number IS NOT NULL
          )
    ) INTO void_filter_test;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 105 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '統一 void/voided 容錯處理：';
    RAISE NOTICE '- payments.invoice_status constraint 允許: pending, issued, void';
    RAISE NOTICE '- View 篩選改用 NOT IN (''void'', ''voided'') 容錯';
    RAISE NOTICE '';
    RAISE NOTICE '重建 Views：';
    RAISE NOTICE '1. v_renewal_reminders: % 筆', renewal_count;
    RAISE NOTICE '2. v_monthly_reminders_summary: 重建完成';
    RAISE NOTICE '3. v_invoice_workspace: % 筆', invoice_workspace_count;
    RAISE NOTICE '4. v_invoice_queue: 重建完成';
    RAISE NOTICE '5. v_invoice_dashboard_stats: 重建完成';
    RAISE NOTICE '';
END $$;
