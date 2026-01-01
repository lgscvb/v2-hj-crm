-- ============================================================================
-- Migration 099: 修復 v_renewal_queue action_key 對齊 ActionDispatcher
--
-- 問題：
-- - payment_pending 輸出 SEND_REMINDER（屬於 payment 流程）
-- - invoice_pending 輸出 ISSUE_INVOICE（屬於 invoice 流程）
-- - 但 renewal 流程的 ActionDispatcher 沒有這些 handlers
--
-- 修復：
-- - payment_pending → GO_TO_PAYMENTS（導流到繳費管理）
-- - invoice_pending → GO_TO_INVOICES（導流到發票管理）
--
-- Date: 2026-01-01
-- ============================================================================

-- ============================================================================
-- 1. 重建 v_renewal_queue（修正 action_key）
-- ============================================================================

DROP VIEW IF EXISTS v_renewal_queue CASCADE;

CREATE VIEW v_renewal_queue AS
SELECT
    cw.*,
    'renewal'::TEXT AS process_key,
    cw.id AS entity_id,

    -- 改用公司名稱（合約編號 + 公司名稱）
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

    -- ★ 099 修復：action_key 對齊 renewal 流程的 ActionDispatcher
    CASE
        WHEN cw.decision_blocked_by = 'need_create_renewal' THEN 'CREATE_DRAFT'
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'SEND_SIGN_REMINDER'
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 'GO_TO_PAYMENTS'      -- ★ 修復：導流
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'GO_TO_INVOICES'      -- ★ 修復：導流
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

COMMENT ON VIEW v_renewal_queue IS '續約待辦清單 - action_key 對齊 ActionDispatcher (099)';
GRANT SELECT ON v_renewal_queue TO anon, authenticated;

-- ============================================================================
-- 2. 重建 v_renewal_dashboard_stats（依賴 v_renewal_queue）
-- ============================================================================

DROP VIEW IF EXISTS v_renewal_dashboard_stats CASCADE;

CREATE VIEW v_renewal_dashboard_stats AS
SELECT
    COUNT(*) AS total_action_needed,
    COUNT(*) FILTER (WHERE decision_priority = 'urgent') AS urgent_count,
    COUNT(*) FILTER (WHERE decision_priority = 'high') AS high_count,
    COUNT(*) FILTER (WHERE decision_priority = 'medium') AS medium_count,
    COUNT(*) FILTER (WHERE decision_priority = 'low') AS low_count,
    COUNT(*) FILTER (WHERE is_overdue = TRUE) AS overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_create_renewal') AS need_create_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_send_for_sign') AS need_send_sign_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'waiting_for_sign') AS waiting_sign_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'signing_overdue') AS signing_overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'payment_pending') AS payment_pending_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'invoice_pending') AS invoice_pending_count
FROM v_renewal_queue;

COMMENT ON VIEW v_renewal_dashboard_stats IS '續約 Dashboard 統計 (099)';
GRANT SELECT ON v_renewal_dashboard_stats TO anon, authenticated;

-- ============================================================================
-- 3. 重建 v_renewal_reminders（統一發票來源：改用 payments 表）
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
      AND status NOT IN ('cancelled', 'terminated')
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
-- ★ 099 修復：改用 payments 表（統一發票來源，包含外部開立）
first_invoices AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        invoice_number,
        invoice_date
    FROM payments
    WHERE payment_type = 'rent'
      AND invoice_number IS NOT NULL
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

    -- ========== 前端用計算欄位 ==========

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

    -- 完成度分數（0-7，對應 7 步驟）
    (
        (CASE WHEN ct.renewal_notified_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN ct.renewal_confirmed_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_contract_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_sent_for_sign_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_signed_at IS NOT NULL OR nc.next_status IN ('active', 'signed') THEN 1 ELSE 0 END) +
        (CASE WHEN fp.payment_status = 'paid' THEN 1 ELSE 0 END) +
        (CASE WHEN fi.invoice_number IS NOT NULL THEN 1 ELSE 0 END)
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

COMMENT ON VIEW v_renewal_reminders IS '續約提醒視圖 - 發票來源統一用 payments 表 (099)';
GRANT SELECT ON v_renewal_reminders TO anon, authenticated;

-- ============================================================================
-- 4. 重建 v_monthly_reminders_summary
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
-- 5. 驗證
-- ============================================================================

DO $$
DECLARE
    queue_count INT;
    reminders_count INT;
BEGIN
    SELECT COUNT(*) INTO queue_count FROM v_renewal_queue;
    SELECT COUNT(*) INTO reminders_count FROM v_renewal_reminders;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 099 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '1. v_renewal_queue 已更新 action_key:';
    RAISE NOTICE '   - payment_pending → GO_TO_PAYMENTS';
    RAISE NOTICE '   - invoice_pending → GO_TO_INVOICES';
    RAISE NOTICE '   待辦筆數: %', queue_count;
    RAISE NOTICE '';
    RAISE NOTICE '2. v_renewal_reminders 已更新發票來源:';
    RAISE NOTICE '   - 改用 payments 表（含外部開立發票）';
    RAISE NOTICE '   續約提醒筆數: %', reminders_count;
    RAISE NOTICE '';
END $$;
