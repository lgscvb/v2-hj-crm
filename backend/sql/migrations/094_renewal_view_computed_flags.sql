-- 094_renewal_view_computed_flags.sql
-- 新增 v_renewal_reminders 的計算欄位，讓前端不需要 computeFlags()
--
-- 新增欄位：
-- - is_notified：是否已通知（布林）
-- - is_confirmed：是否已確認（布林）
-- - is_paid：別名，等同 is_first_payment_paid
-- - is_signed：別名，等同 is_next_signed
-- - is_invoiced：別名，等同 is_next_invoiced
-- - next_action：下一步建議動作
-- - completion_score：完成度分數（0-5）
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. 重建 v_renewal_reminders 視圖（新增計算欄位）
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
        contract_period AS next_contract_period
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
    ORDER BY renewed_from_id, created_at DESC
),
first_payments AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        payment_status,
        paid_at,
        payment_method
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
),
first_invoices AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        invoice_number,
        invoice_date
    FROM invoices
    WHERE status = 'issued'
    ORDER BY contract_id, invoice_date ASC
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

    -- [DEPRECATED] 保留讀取
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

    -- 收款狀態
    CASE WHEN fp.payment_status = 'paid' THEN true ELSE false END AS is_first_payment_paid,
    fp.payment_status AS first_payment_status,
    fp.paid_at AS first_payment_paid_at,
    fp.payment_method AS first_payment_method,

    -- 發票狀態
    fi.invoice_number AS next_invoice_number,
    fi.invoice_date AS next_invoice_date,
    fi.invoice_number IS NOT NULL AS is_next_invoiced,

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

    -- ========== 新增：前端用計算欄位 ==========

    -- 意願 flags（布林）
    ct.renewal_notified_at IS NOT NULL AS is_notified,
    ct.renewal_confirmed_at IS NOT NULL AS is_confirmed,

    -- 別名（與 computeFlags 相容）
    CASE WHEN fp.payment_status = 'paid' THEN true ELSE false END AS is_paid,
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_signed,
    fi.invoice_number IS NOT NULL AS is_invoiced,

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

    -- 完成度分數（0-5）
    (
        (CASE WHEN ct.renewal_notified_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN ct.renewal_confirmed_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN fp.payment_status = 'paid' THEN 1 ELSE 0 END) +
        (CASE WHEN fi.invoice_number IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_signed_at IS NOT NULL OR nc.next_status IN ('active', 'signed') THEN 1 ELSE 0 END)
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

COMMENT ON VIEW v_renewal_reminders IS '續約提醒視圖（V3.2）- 新增計算欄位：is_notified, is_confirmed, is_paid, is_signed, is_invoiced, next_action, completion_score';

GRANT SELECT ON v_renewal_reminders TO anon, authenticated;

-- ============================================================================
-- 2. 重建 v_monthly_reminders_summary
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
    -- 新增：完成度統計
    ROUND(AVG(completion_score), 2) AS avg_completion_score
FROM v_renewal_reminders
GROUP BY branch_id, branch_name;

GRANT SELECT ON v_monthly_reminders_summary TO anon, authenticated;

-- ============================================================================
-- 3. 建立 v_dashboard_stats（儀表板統計）
-- ============================================================================

DROP VIEW IF EXISTS v_dashboard_stats CASCADE;

CREATE VIEW v_dashboard_stats AS
SELECT
    -- 客戶統計
    SUM(active_customers) AS total_customers,
    -- 合約統計
    SUM(active_contracts) AS total_contracts,
    SUM(contracts_expiring_30days) AS contracts_expiring_soon,
    -- 本月營收（金額）
    SUM(current_month_revenue) AS monthly_revenue,
    SUM(current_month_pending) AS monthly_pending,
    SUM(current_month_overdue) AS monthly_overdue,
    -- 本月應收 = 已收 + 待收 + 逾期
    SUM(current_month_revenue) + SUM(current_month_pending) + SUM(current_month_overdue) AS monthly_receivable,
    -- 本月未收 = 待收 + 逾期
    SUM(current_month_pending) + SUM(current_month_overdue) AS monthly_outstanding,
    -- 本月筆數
    SUM(current_month_paid_count) AS paid_count,
    SUM(current_month_pending_count) AS pending_count,
    SUM(current_month_overdue_count) AS overdue_count,
    SUM(current_month_paid_count) + SUM(current_month_pending_count) + SUM(current_month_overdue_count) AS receivable_count,
    SUM(current_month_pending_count) + SUM(current_month_overdue_count) AS outstanding_count,
    -- 收款率
    CASE
        WHEN SUM(current_month_revenue) + SUM(current_month_pending) + SUM(current_month_overdue) > 0
        THEN ROUND(
            SUM(current_month_revenue)::NUMERIC /
            (SUM(current_month_revenue) + SUM(current_month_pending) + SUM(current_month_overdue)) * 100,
            1
        )
        ELSE 0
    END AS collection_rate
FROM v_branch_revenue_summary;

COMMENT ON VIEW v_dashboard_stats IS '儀表板統計視圖 - 聚合所有場館數據，取代前端 reduce()';

GRANT SELECT ON v_dashboard_stats TO anon, authenticated;

-- ============================================================================
-- 4. 驗證
-- ============================================================================

DO $$
DECLARE
    sample_record RECORD;
    stats_record RECORD;
BEGIN
    SELECT
        contract_number,
        is_notified,
        is_confirmed,
        is_paid,
        is_signed,
        is_invoiced,
        next_action,
        completion_score
    INTO sample_record
    FROM v_renewal_reminders
    LIMIT 1;

    SELECT * INTO stats_record FROM v_dashboard_stats;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 094 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '1. v_renewal_reminders 新增欄位：';
    RAISE NOTICE '   ✅ is_notified, is_confirmed, is_paid, is_signed, is_invoiced';
    RAISE NOTICE '   ✅ next_action, completion_score';
    RAISE NOTICE '';
    RAISE NOTICE '2. v_dashboard_stats 新增視圖：';
    RAISE NOTICE '   ✅ 聚合所有場館統計（取代前端 reduce）';
    RAISE NOTICE '';

    IF stats_record IS NOT NULL THEN
        RAISE NOTICE '儀表板統計：';
        RAISE NOTICE '   客戶: % | 合約: % | 即將到期: %',
            stats_record.total_customers,
            stats_record.total_contracts,
            stats_record.contracts_expiring_soon;
        RAISE NOTICE '   本月營收: % | 待收: % | 逾期: %',
            stats_record.monthly_revenue,
            stats_record.monthly_pending,
            stats_record.monthly_overdue;
        RAISE NOTICE '   收款率: % %%',
            stats_record.collection_rate;
    ELSE
        RAISE NOTICE '（無場館資料）';
    END IF;
END $$;
