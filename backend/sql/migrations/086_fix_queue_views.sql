-- 086_fix_queue_views.sql
-- 修正 commission 和 termination queue 視圖的欄位名稱
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. v_commission_queue - 佣金看板（修正欄位）
-- ============================================================================

DROP VIEW IF EXISTS v_commission_queue CASCADE;

CREATE VIEW v_commission_queue AS
SELECT
    cw.commission_id,
    cw.contract_id,
    cw.customer_id,
    cw.branch_id,
    cw.accounting_firm_id,
    cw.contract_number,
    cw.position_number,
    cw.customer_name,
    cw.customer_company_name,
    cw.firm_name,
    cw.firm_short_name,
    cw.branch_name,
    cw.contract_start_date,
    cw.contract_end_date,
    cw.contract_status,
    cw.monthly_rent,
    cw.commission_rate,
    cw.amount AS commission_amount,
    cw.status AS commission_status,
    cw.eligible_date AS eligibility_date,
    cw.paid_at,
    cw.process_key,
    cw.entity_id,
    cw.days_until_eligible,
    cw.is_eligible,
    cw.decision_blocked_by,
    cw.decision_next_action,
    cw.decision_action_key,
    cw.decision_owner,
    cw.decision_priority,

    -- ★ 改用公司名稱
    CONCAT(
        cw.contract_number, ' ',
        COALESCE(NULLIF(cw.customer_company_name, ''), cw.customer_name)
    ) AS title,

    cw.decision_due_date,
    cw.workspace_url,
    0 AS overdue_days,
    cw.is_overdue

FROM v_commission_workspace cw
WHERE cw.decision_blocked_by IS NOT NULL
ORDER BY
    CASE cw.decision_priority
        WHEN 'urgent' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        ELSE 4
    END,
    cw.eligible_date ASC NULLS LAST;

COMMENT ON VIEW v_commission_queue IS '佣金待辦清單 - 使用公司名稱';
GRANT SELECT ON v_commission_queue TO anon, authenticated;

-- ============================================================================
-- 2. v_termination_queue - 解約看板（修正欄位）
-- ============================================================================

DROP VIEW IF EXISTS v_termination_queue CASCADE;

CREATE VIEW v_termination_queue AS
SELECT
    tw.id,
    tw.contract_id,
    tw.customer_id,
    tw.branch_id,
    tw.contract_number,
    tw.position_number,
    tw.customer_name,
    tw.company_name,
    tw.branch_name,
    tw.termination_type AS type,
    tw.type_label,
    tw.status,
    tw.status_label,
    tw.notice_date,
    tw.expected_end_date,
    tw.actual_move_out AS actual_end_date,
    tw.actual_move_out AS move_out_date,
    tw.chk_keys_returned AS keys_returned,
    tw.chk_room_inspected AS room_inspected,
    tw.chk_doc_submitted AS tax_doc_submitted,
    tw.chk_doc_approved AS tax_doc_approved,
    tw.deposit_amount,
    tw.deduction_amount AS deductions,
    tw.refund_amount,
    tw.created_at,
    tw.progress AS days_since_start,
    tw.decision_blocked_by AS next_step,
    tw.decision_blocked_by AS next_step_status,
    tw.decision_next_action AS next_step_action,

    'termination'::TEXT AS process_key,
    tw.id AS entity_id,

    -- ★ 改用公司名稱
    CONCAT(
        tw.contract_number, ' ',
        COALESCE(NULLIF(tw.company_name, ''), tw.customer_name),
        ' - ', tw.type_label
    ) AS title,

    tw.is_settlement_overdue OR tw.is_refund_overdue AS is_overdue,

    CASE
        WHEN tw.is_settlement_overdue THEN tw.days_waiting_doc
        WHEN tw.is_refund_overdue THEN tw.days_waiting_doc
        ELSE 0
    END AS overdue_days,

    tw.expected_end_date AS decision_due_date,
    CONCAT('/terminations/', tw.id, '/workspace') AS workspace_url,

    CASE
        WHEN tw.is_settlement_overdue THEN 'urgent'
        WHEN tw.is_refund_overdue THEN 'urgent'
        WHEN tw.is_doc_overdue THEN 'high'
        ELSE 'medium'
    END AS decision_priority,

    tw.decision_blocked_by,
    tw.decision_next_action AS decision_action_key

FROM v_termination_workspace tw
WHERE tw.status NOT IN ('completed', 'cancelled')
ORDER BY
    CASE
        WHEN tw.is_settlement_overdue THEN 1
        WHEN tw.is_refund_overdue THEN 2
        WHEN tw.is_doc_overdue THEN 3
        ELSE 4
    END,
    tw.created_at ASC;

COMMENT ON VIEW v_termination_queue IS '解約待辦清單 - 使用公司名稱';
GRANT SELECT ON v_termination_queue TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 086 完成 ===';
    RAISE NOTICE '✅ v_commission_queue 已修正';
    RAISE NOTICE '✅ v_termination_queue 已修正';
END $$;
