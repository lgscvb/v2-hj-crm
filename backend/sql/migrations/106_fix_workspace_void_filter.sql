-- ============================================================================
-- Migration 106: 統一 v_contract_workspace 的 void/voided 過濾
--
-- 背景：
-- - Migration 103 修正了 v_contract_workspace，使用 IS DISTINCT FROM 'voided'
-- - 但 payments.invoice_status constraint 只允許 'void'（不是 'voided'）
-- - 實際資料中只會有 'void'，所以 'voided' 過濾無效
-- - Migration 105 已修正 v_renewal_reminders 使用 NOT IN ('void', 'voided') 容錯
-- - 需要同步更新 v_contract_workspace
--
-- 修正：
-- - first_invoices CTE 改用 NOT IN ('void', 'voided')
-- - 保持與 Migration 105 的 v_renewal_reminders 一致
--
-- Date: 2026-01-02
-- ============================================================================

-- ============================================================================
-- 1. 重建 v_contract_workspace（統一 void/voided 過濾）
-- ============================================================================

DROP VIEW IF EXISTS v_renewal_queue CASCADE;
DROP VIEW IF EXISTS v_renewal_dashboard_stats CASCADE;
DROP VIEW IF EXISTS v_contract_workspace CASCADE;

CREATE VIEW v_contract_workspace AS
WITH
-- 找出每張合約的「上一張合約」（renewed_from）
prev_contracts AS (
    SELECT
        id AS contract_id,
        renewed_from_id AS prev_contract_id
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
),
-- 找出每張合約的「下一張續約合約」（最新一筆，排除已取消）
next_contracts AS (
    SELECT DISTINCT ON (renewed_from_id)
        renewed_from_id AS old_contract_id,
        id AS next_contract_id,
        status AS next_status,
        signed_at AS next_signed_at,
        created_at AS next_created_at,
        start_date AS next_start_date,
        end_date AS next_end_date,
        sent_for_sign_at AS next_sent_for_sign_at,
        contract_period AS next_contract_period,
        monthly_rent AS next_monthly_rent,
        payment_cycle AS next_payment_cycle
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
      AND status NOT IN ('cancelled', 'terminated')
    ORDER BY renewed_from_id, created_at DESC
),
-- 只 JOIN 續約合約的第一期付款
first_payments AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        id AS first_payment_id,
        payment_status AS first_payment_status,
        paid_at AS first_payment_paid_at,
        due_date AS first_payment_due_date,
        amount AS first_payment_amount,
        payment_method AS first_payment_method
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
),
-- ★ 106 修正：發票需排除已作廢（容錯處理 void 和 voided）
first_invoices AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        invoice_number AS first_invoice_number,
        invoice_date AS first_invoice_date,
        invoice_status AS first_invoice_status
    FROM payments
    WHERE payment_type = 'rent'
      AND invoice_number IS NOT NULL
      AND invoice_status NOT IN ('void', 'voided')
    ORDER BY contract_id, payment_period ASC
)
SELECT
    -- 合約基本資訊
    c.id,
    c.contract_number,
    c.contract_period,
    c.customer_id,
    c.branch_id,
    c.contract_type,
    c.plan_name,
    c.start_date,
    c.end_date,
    c.monthly_rent,
    c.deposit,
    c.payment_cycle,
    c.payment_day,
    c.status,
    c.position_number,
    c.signed_at,
    c.sent_for_sign_at,
    c.renewed_from_id,
    c.created_at,
    c.updated_at,

    -- 補齊欄位
    c.original_price,
    c.deposit_status,
    c.rental_address,

    -- 承租人資訊（合約層級）
    c.company_name,
    c.representative_name,
    c.representative_address,
    c.id_number,
    c.company_tax_id,
    c.phone,
    c.email,

    -- 客戶資訊
    cust.name AS customer_name,
    cust.company_name AS customer_company_name,
    cust.phone AS customer_phone,
    cust.email AS customer_email,
    cust.line_user_id,
    cust.status AS customer_status,
    cust.address AS customer_address,
    cust.risk_level AS customer_risk_level,

    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,

    -- 續約追蹤欄位（意願管理）
    c.renewal_notified_at,
    c.renewal_confirmed_at,
    c.renewal_notes,

    -- 上一張合約
    pc.prev_contract_id,

    -- 下一張續約合約
    nc.next_contract_id,
    nc.next_status,
    nc.next_signed_at,
    nc.next_created_at,
    nc.next_start_date,
    nc.next_end_date,
    nc.next_sent_for_sign_at,
    nc.next_contract_period,
    nc.next_monthly_rent,
    nc.next_payment_cycle,

    -- 送簽開始時間
    COALESCE(nc.next_sent_for_sign_at, nc.next_created_at) AS signing_start_at,

    -- 是否有續約草稿
    nc.next_contract_id IS NOT NULL AS has_renewal_draft,
    nc.next_sent_for_sign_at IS NOT NULL AS is_sent_for_sign,

    -- 付款/發票資訊
    fp.first_payment_id,
    fp.first_payment_status,
    fp.first_payment_paid_at,
    fp.first_payment_due_date,
    fp.first_payment_amount,
    fp.first_payment_method,

    fi.first_invoice_number,
    fi.first_invoice_date,

    -- ========== 計算欄位 ==========

    -- 剩餘天數
    c.end_date - CURRENT_DATE AS days_until_expiry,

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

    -- ========== Timeline 節點狀態 ==========

    -- 1. 續約意願
    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL THEN 'done'
        WHEN c.renewal_notified_at IS NOT NULL THEN 'pending'
        ELSE 'not_started'
    END AS timeline_intent_status,

    -- 2. 文件回簽（看 next_contract）
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN 'done'
        WHEN nc.next_status IN ('active', 'signed') THEN 'done'
        WHEN nc.next_sent_for_sign_at IS NOT NULL THEN 'pending'
        WHEN nc.next_status = 'renewal_draft' THEN 'draft'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'unknown'
    END AS timeline_signing_status,

    -- 3. 收款
    CASE
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        WHEN fp.first_payment_status = 'paid' THEN 'done'
        WHEN fp.first_payment_status = 'overdue' THEN 'blocked'
        WHEN fp.first_payment_status IS NOT NULL THEN 'pending'
        ELSE 'not_created'
    END AS timeline_payment_status,

    -- 4. 發票（★ 106 修正：已在 CTE 排除 void/voided）
    CASE
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        WHEN fi.first_invoice_number IS NOT NULL THEN 'done'
        WHEN fp.first_payment_status = 'paid' THEN 'pending'
        ELSE 'not_created'
    END AS timeline_invoice_status,

    -- 5. 啟用
    CASE
        WHEN nc.next_status = 'active' THEN 'done'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'pending'
    END AS timeline_activation_status,

    -- ========== 布林 Flags ==========

    c.renewal_notified_at IS NOT NULL AS is_notified,
    c.renewal_confirmed_at IS NOT NULL AS is_confirmed,
    -- is_paid
    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fp.first_payment_status = 'paid' THEN true
        ELSE false
    END AS is_paid,
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_signed,
    -- ★ 106 修正：is_invoiced 已在 CTE 排除 void/voided
    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fi.first_invoice_number IS NOT NULL THEN true
        ELSE false
    END AS is_invoiced,

    -- ========== Decision（卡點判斷，first-match wins） ==========

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN 'need_create_renewal'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - COALESCE(nc.next_sent_for_sign_at, nc.next_created_at)) > 14
        THEN 'signing_overdue'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN 'payment_pending'
        WHEN fp.first_payment_status = 'paid'
         AND fi.first_invoice_number IS NULL
        THEN 'invoice_pending'
        WHEN nc.next_status = 'active'
        THEN 'completed'
        ELSE NULL
    END AS decision_blocked_by,

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN '建立續約合約草稿'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - COALESCE(nc.next_sent_for_sign_at, nc.next_created_at)) > 14
        THEN '發催簽通知'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN '催收首期款項'
        WHEN fp.first_payment_status = 'paid'
         AND fi.first_invoice_number IS NULL
        THEN '開立首期發票'
        WHEN nc.next_status = 'active'
        THEN NULL
        ELSE NULL
    END AS decision_next_action,

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN 'Sales'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - COALESCE(nc.next_sent_for_sign_at, nc.next_created_at)) > 14
        THEN 'Sales'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN 'Finance'
        WHEN fp.first_payment_status = 'paid'
         AND fi.first_invoice_number IS NULL
        THEN 'Finance'
        ELSE NULL
    END AS decision_owner

FROM contracts c
JOIN customers cust ON c.customer_id = cust.id
JOIN branches b ON c.branch_id = b.id
LEFT JOIN prev_contracts pc ON pc.contract_id = c.id
LEFT JOIN next_contracts nc ON nc.old_contract_id = c.id
LEFT JOIN first_payments fp ON fp.contract_id = nc.next_contract_id
LEFT JOIN first_invoices fi ON fi.contract_id = nc.next_contract_id;

COMMENT ON VIEW v_contract_workspace IS 'Contract Workspace V6 - 統一 void/voided 過濾 (106)';

GRANT SELECT ON v_contract_workspace TO anon, authenticated;

-- ============================================================================
-- 2. 重建 v_renewal_queue（依賴 v_contract_workspace）
-- ============================================================================

CREATE VIEW v_renewal_queue AS
SELECT
    cw.*,
    'renewal'::TEXT AS process_key,
    cw.id AS entity_id,

    CONCAT(
        cw.contract_number, ' ',
        COALESCE(NULLIF(cw.company_name, ''), cw.customer_name)
    ) AS title,

    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN TRUE
        WHEN cw.days_until_expiry < 0 AND cw.next_contract_id IS NULL THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN cw.days_pending_sign
        WHEN cw.days_until_expiry < 0 THEN ABS(cw.days_until_expiry)
        ELSE 0
    END AS overdue_days,

    cw.end_date AS decision_due_date,
    CONCAT('/contracts/', cw.id, '/workspace') AS workspace_url,

    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'urgent'
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 'high'
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'medium'
        WHEN cw.decision_blocked_by = 'need_create_renewal' THEN
            CASE
                WHEN cw.days_until_expiry <= 0 THEN 'urgent'
                WHEN cw.days_until_expiry <= 14 THEN 'high'
                WHEN cw.days_until_expiry <= 30 THEN 'medium'
                ELSE 'low'
            END
        WHEN cw.decision_blocked_by IS NOT NULL THEN 'medium'
        ELSE NULL
    END AS decision_priority,

    CASE
        WHEN cw.decision_blocked_by = 'need_create_renewal' THEN 'CREATE_DRAFT'
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'SEND_SIGN_REMINDER'
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 'GO_TO_PAYMENTS'
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'GO_TO_INVOICES'
        ELSE NULL
    END AS decision_action_key

FROM v_contract_workspace cw
WHERE cw.decision_blocked_by IS NOT NULL
  AND cw.decision_blocked_by != 'completed'
  AND cw.status = 'active'
ORDER BY
    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 1
        WHEN cw.decision_blocked_by = 'need_create_renewal' AND cw.days_until_expiry <= 0 THEN 2
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 3
        WHEN cw.decision_blocked_by = 'need_create_renewal' AND cw.days_until_expiry <= 14 THEN 4
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 5
        ELSE 6
    END,
    cw.days_until_expiry ASC NULLS LAST;

COMMENT ON VIEW v_renewal_queue IS '續約待辦清單 (106)';
GRANT SELECT ON v_renewal_queue TO anon, authenticated;

-- ============================================================================
-- 3. 重建 v_renewal_dashboard_stats
-- ============================================================================

CREATE VIEW v_renewal_dashboard_stats AS
SELECT
    COUNT(*) AS total_action_needed,
    COUNT(*) FILTER (WHERE decision_priority = 'urgent') AS urgent_count,
    COUNT(*) FILTER (WHERE decision_priority = 'high') AS high_count,
    COUNT(*) FILTER (WHERE decision_priority = 'medium') AS medium_count,
    COUNT(*) FILTER (WHERE decision_priority = 'low') AS low_count,
    COUNT(*) FILTER (WHERE is_overdue = TRUE) AS overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_create_renewal') AS need_create_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'signing_overdue') AS signing_overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'payment_pending') AS payment_pending_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'invoice_pending') AS invoice_pending_count
FROM v_renewal_queue;

COMMENT ON VIEW v_renewal_dashboard_stats IS '續約 Dashboard 統計 (106)';
GRANT SELECT ON v_renewal_dashboard_stats TO anon, authenticated;

-- ============================================================================
-- 4. 驗證
-- ============================================================================

DO $$
DECLARE
    workspace_count INT;
    void_count INT;
BEGIN
    SELECT COUNT(*) INTO workspace_count FROM v_contract_workspace;

    -- 檢查是否有 void 狀態的發票會被正確排除
    SELECT COUNT(*) INTO void_count
    FROM payments
    WHERE invoice_status = 'void'
      AND invoice_number IS NOT NULL;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 106 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '修正內容：';
    RAISE NOTICE '- v_contract_workspace first_invoices CTE 統一使用 NOT IN (''void'', ''voided'')';
    RAISE NOTICE '- 與 Migration 105 的 v_renewal_reminders 保持一致';
    RAISE NOTICE '';
    RAISE NOTICE '統計：';
    RAISE NOTICE '- v_contract_workspace: % 筆', workspace_count;
    RAISE NOTICE '- 已作廢發票（被排除）: % 筆', void_count;
END $$;
