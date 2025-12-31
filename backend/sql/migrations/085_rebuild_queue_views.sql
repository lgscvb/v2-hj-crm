-- 085_rebuild_queue_views.sql
-- 重建所有 Queue 視圖（統一使用公司名稱）
--
-- 問題：
-- 之前的 migration CASCADE 刪除了 queue 視圖但未重建
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. v_payment_queue - 付款看板
-- ============================================================================

DROP VIEW IF EXISTS v_payment_queue CASCADE;

CREATE VIEW v_payment_queue AS
SELECT
    pw.payment_id,
    pw.contract_id,
    pw.customer_id,
    pw.branch_id,
    pw.payment_type,
    pw.payment_period,
    pw.amount,
    pw.payment_status,
    pw.due_date,
    pw.paid_at,
    pw.invoice_number,
    pw.invoice_date,
    pw.invoice_status,
    pw.contract_number,
    pw.position_number,
    pw.customer_name,
    pw.customer_phone,
    pw.customer_email,
    pw.line_user_id,
    pw.branch_code,
    pw.branch_name,
    pw.process_key,
    pw.entity_id,
    pw.actual_overdue_days,
    pw.is_overdue,
    pw.decision_blocked_by,
    pw.decision_next_action,
    pw.decision_action_key,
    pw.decision_owner,
    pw.decision_priority,
    pw.promised_pay_date,
    pw.has_valid_promise,
    pw.days_until_promise,

    -- ★ 改用公司名稱
    CONCAT(
        pw.contract_number, ' ',
        COALESCE(
            NULLIF(pw.contract_company_name, ''),
            NULLIF(pw.customer_company_name, ''),
            pw.customer_name
        ),
        ' (', pw.payment_period, ')'
    ) AS title,

    pw.due_date AS decision_due_date,
    CONCAT('/payments/', pw.payment_id, '/workspace') AS workspace_url,
    pw.actual_overdue_days AS overdue_days

FROM v_payment_workspace pw
WHERE pw.decision_blocked_by IS NOT NULL
ORDER BY
    CASE pw.decision_priority
        WHEN 'urgent' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        ELSE 4
    END,
    pw.due_date ASC NULLS LAST;

COMMENT ON VIEW v_payment_queue IS '付款待辦清單 - 使用公司名稱';
GRANT SELECT ON v_payment_queue TO anon, authenticated;

-- ============================================================================
-- 2. v_invoice_queue - 發票看板
-- ============================================================================

DROP VIEW IF EXISTS v_invoice_queue CASCADE;

CREATE VIEW v_invoice_queue AS
SELECT
    iw.payment_id,
    iw.contract_id,
    iw.customer_id,
    iw.branch_id,
    iw.payment_type,
    iw.payment_period,
    iw.amount,
    iw.payment_status,
    iw.due_date,
    iw.paid_at,
    iw.invoice_number,
    iw.invoice_date,
    iw.invoice_status,
    iw.contract_number,
    iw.position_number,
    iw.customer_name,
    iw.customer_phone,
    iw.customer_email,
    iw.branch_code,
    iw.branch_name,
    iw.process_key,
    iw.entity_id,
    iw.effective_tax_id,
    iw.days_since_paid,
    iw.needs_invoice,
    iw.is_overdue,
    iw.decision_blocked_by,
    iw.decision_next_action,
    iw.decision_action_key,
    iw.decision_owner,
    iw.decision_priority,

    -- ★ 改用公司名稱
    CONCAT(
        iw.contract_number, ' ',
        COALESCE(
            NULLIF(iw.contract_company_name, ''),
            NULLIF(iw.customer_company_name, ''),
            iw.customer_name
        ),
        ' (', iw.payment_period, ')'
    ) AS title,

    iw.decision_due_date,
    iw.workspace_url,
    iw.days_since_paid AS overdue_days

FROM v_invoice_workspace iw
WHERE iw.decision_blocked_by IS NOT NULL
ORDER BY
    CASE iw.decision_priority
        WHEN 'urgent' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        ELSE 4
    END,
    iw.due_date ASC NULLS LAST;

COMMENT ON VIEW v_invoice_queue IS '發票待辦清單 - 使用公司名稱';
GRANT SELECT ON v_invoice_queue TO anon, authenticated;

-- ============================================================================
-- 3. v_commission_queue - 佣金看板
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
    cw.commission_amount,
    cw.commission_status,
    cw.eligibility_date,
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

    cw.eligibility_date AS decision_due_date,
    CONCAT('/commissions/', cw.commission_id, '/workspace') AS workspace_url,
    0 AS overdue_days,
    FALSE AS is_overdue

FROM v_commission_workspace cw
WHERE cw.decision_blocked_by IS NOT NULL
ORDER BY
    CASE cw.decision_priority
        WHEN 'urgent' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        ELSE 4
    END,
    cw.eligibility_date ASC NULLS LAST;

COMMENT ON VIEW v_commission_queue IS '佣金待辦清單 - 使用公司名稱';
GRANT SELECT ON v_commission_queue TO anon, authenticated;

-- ============================================================================
-- 4. v_termination_queue - 解約看板
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
    tw.type,
    tw.type_label,
    tw.status,
    tw.status_label,
    tw.notice_date,
    tw.expected_end_date,
    tw.actual_end_date,
    tw.move_out_date,
    tw.keys_returned,
    tw.room_inspected,
    tw.tax_doc_submitted,
    tw.tax_doc_approved,
    tw.deposit_amount,
    tw.deductions,
    tw.refund_amount,
    tw.refund_status,
    tw.created_at,
    tw.days_since_start,
    tw.settlement_deadline,
    tw.next_step,
    tw.next_step_status,
    tw.next_step_action,

    'termination'::TEXT AS process_key,
    tw.id AS entity_id,

    -- ★ 改用公司名稱
    CONCAT(
        tw.contract_number, ' ',
        COALESCE(NULLIF(tw.company_name, ''), tw.customer_name),
        ' - ', tw.type_label
    ) AS title,

    CASE
        WHEN tw.days_since_start > 60 THEN TRUE
        WHEN tw.settlement_deadline IS NOT NULL AND tw.settlement_deadline < CURRENT_DATE THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    CASE
        WHEN tw.days_since_start > 60 THEN tw.days_since_start - 60
        WHEN tw.settlement_deadline IS NOT NULL AND tw.settlement_deadline < CURRENT_DATE
            THEN (CURRENT_DATE - tw.settlement_deadline)::INT
        ELSE 0
    END AS overdue_days,

    COALESCE(tw.settlement_deadline, tw.move_out_date, tw.expected_end_date) AS decision_due_date,
    CONCAT('/terminations/', tw.id, '/workspace') AS workspace_url,

    CASE
        WHEN tw.days_since_start > 60 THEN 'urgent'
        WHEN tw.settlement_deadline IS NOT NULL AND tw.settlement_deadline < CURRENT_DATE THEN 'urgent'
        WHEN tw.days_since_start > 30 THEN 'high'
        WHEN tw.next_step_status = 'blocked' THEN 'high'
        ELSE 'medium'
    END AS decision_priority,

    tw.next_step AS decision_blocked_by,
    tw.next_step_action AS decision_action_key

FROM v_termination_workspace tw
WHERE tw.status NOT IN ('completed', 'cancelled')
ORDER BY
    CASE
        WHEN tw.days_since_start > 60 THEN 1
        WHEN tw.settlement_deadline IS NOT NULL AND tw.settlement_deadline < CURRENT_DATE THEN 2
        WHEN tw.days_since_start > 30 THEN 3
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
    RAISE NOTICE '=== Migration 085 完成 ===';
    RAISE NOTICE '✅ v_payment_queue 已重建（使用公司名稱）';
    RAISE NOTICE '✅ v_invoice_queue 已重建（使用公司名稱）';
    RAISE NOTICE '✅ v_commission_queue 已重建（使用公司名稱）';
    RAISE NOTICE '✅ v_termination_queue 已重建（使用公司名稱）';
END $$;
