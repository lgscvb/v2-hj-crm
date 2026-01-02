-- ============================================================================
-- Migration 108: 修正 v_overdue_details 排除解約中合約
--
-- 問題：解約中的合約(pending_termination)付款仍顯示在 Dashboard 逾期列表
-- 原因：v_overdue_details 沒有過濾 contract.status
-- 修正：新增 contract.status NOT IN ('pending_termination', 'terminated') 條件
--
-- Date: 2026-01-02
-- ============================================================================

-- ============================================================================
-- 1. 重建 v_overdue_details（排除解約中/已終止合約）
-- ============================================================================

DROP VIEW IF EXISTS v_overdue_details CASCADE;

CREATE VIEW v_overdue_details AS
SELECT
    p.id AS payment_id,
    p.customer_id,
    cu.name AS customer_name,
    cu.company_name,
    cu.phone,
    cu.line_user_id,
    p.contract_id,
    c.contract_number,
    p.branch_id,
    b.name AS branch_name,
    p.amount AS total_due,
    p.due_date,
    p.payment_period,

    -- 承諾付款日期（保留，用於標記「承諾過期」）
    p.promised_pay_date,

    -- promise_expired：曾承諾但違約（承諾日已過期）
    CASE
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date < CURRENT_DATE
        THEN TRUE
        ELSE FALSE
    END AS promise_expired,

    -- 有效到期日（優先使用承諾日期）
    COALESCE(p.promised_pay_date, p.due_date) AS effective_due_date,

    -- 逾期天數（基於有效到期日）
    CASE
        WHEN COALESCE(p.promised_pay_date, p.due_date) < CURRENT_DATE
        THEN CURRENT_DATE - COALESCE(p.promised_pay_date, p.due_date)
        ELSE 0
    END AS days_overdue,

    -- 緊急度
    CASE
        WHEN (CURRENT_DATE - COALESCE(p.promised_pay_date, p.due_date)) <= 7 THEN 'warning'
        WHEN (CURRENT_DATE - COALESCE(p.promised_pay_date, p.due_date)) <= 30 THEN 'danger'
        ELSE 'critical'
    END AS urgency_level

FROM payments p
JOIN customers cu ON p.customer_id = cu.id
LEFT JOIN contracts c ON p.contract_id = c.id
LEFT JOIN branches b ON p.branch_id = b.id
WHERE p.payment_status IN ('pending', 'overdue')
  -- 只列真正逾期（承諾未到期者排除）
  AND COALESCE(p.promised_pay_date, p.due_date) < CURRENT_DATE
  AND p.amount > 0
  AND COALESCE(c.is_billable, true) = true
  -- ★ 2026-01-02: 排除解約中/已終止的合約（這些款項在解約流程處理）
  AND (c.status IS NULL OR c.status NOT IN ('pending_termination', 'terminated'))
ORDER BY COALESCE(p.promised_pay_date, p.due_date) ASC;

COMMENT ON VIEW v_overdue_details IS
'逾期款項詳情視圖（A 行動清單：承諾未到期者不列，排除解約中/已終止合約）';

GRANT SELECT ON v_overdue_details TO anon, authenticated;

-- ============================================================================
-- 2. 驗證
-- ============================================================================

DO $$
DECLARE
    v_count INT;
BEGIN
    -- 檢查是否有解約中合約的付款出現在 view 中
    SELECT COUNT(*) INTO v_count
    FROM v_overdue_details od
    JOIN contracts c ON od.contract_id = c.id
    WHERE c.status IN ('pending_termination', 'terminated');

    IF v_count > 0 THEN
        RAISE EXCEPTION '錯誤：仍有 % 筆解約中/已終止合約的付款出現在 v_overdue_details', v_count;
    END IF;

    RAISE NOTICE '=== Migration 108 完成 ===';
    RAISE NOTICE '已更新 v_overdue_details，排除 pending_termination/terminated 合約';
END $$;
