-- 077_fix_billing_edge_cases.sql
-- 修復 076 code review 發現的邊界問題
--
-- 修復項目：
-- 1. 未來合約（start_date > CURRENT_DATE）的 billing summary 計算
-- 2. v_payments_due 新增 days_overdue（基於 effective_due_date）避免與 urgency 不一致
-- 3. 修正 076 註解（清理範圍包含 E 編號）
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. 修正 get_contract_billing_summary：處理未來合約
-- ============================================================================

CREATE OR REPLACE FUNCTION get_contract_billing_summary(p_contract_id INT)
RETURNS JSONB AS $$
DECLARE
    v_contract RECORD;
    v_cycle_interval INTERVAL;
    v_cycle_months INT;
    v_total_periods INT;
    v_paid_periods INT;
    v_pending_periods INT;
    v_overdue_periods INT;
    v_not_created_periods INT;
    v_next_due_date DATE;
    v_next_amount NUMERIC;
    v_total_paid NUMERIC;
    v_total_expected NUMERIC;
    v_end_exclusive DATE;
BEGIN
    -- 取得合約資訊
    SELECT
        c.id,
        c.start_date,
        c.end_date,
        c.monthly_rent,
        COALESCE(c.payment_cycle, 'monthly') AS payment_cycle,
        COALESCE(c.payment_day, EXTRACT(DAY FROM c.start_date)::INT) AS payment_day,
        c.is_billable
    INTO v_contract
    FROM contracts c
    WHERE c.id = p_contract_id;

    -- 如果合約不存在或不計費
    IF v_contract IS NULL OR COALESCE(v_contract.is_billable, true) = false THEN
        RETURN jsonb_build_object(
            'total_periods', 0,
            'paid_periods', 0,
            'pending_periods', 0,
            'overdue_periods', 0,
            'not_created_periods', 0,
            'next_due_date', NULL,
            'next_amount', NULL,
            'total_paid', 0,
            'total_expected', 0,
            'is_billable', false
        );
    END IF;

    -- 根據繳費週期決定間隔
    CASE v_contract.payment_cycle
        WHEN 'monthly' THEN v_cycle_interval := '1 month'; v_cycle_months := 1;
        WHEN 'quarterly' THEN v_cycle_interval := '3 months'; v_cycle_months := 3;
        WHEN 'semi_annual' THEN v_cycle_interval := '6 months'; v_cycle_months := 6;
        WHEN 'annual' THEN v_cycle_interval := '12 months'; v_cycle_months := 12;
        WHEN 'biennial' THEN v_cycle_interval := '24 months'; v_cycle_months := 24;
        WHEN 'triennial' THEN v_cycle_interval := '36 months'; v_cycle_months := 36;
        ELSE v_cycle_interval := '1 month'; v_cycle_months := 1;
    END CASE;

    -- 使用 get_contract_end_exclusive 取得動態排他邊界
    v_end_exclusive := get_contract_end_exclusive(v_contract.start_date, v_contract.end_date);

    -- ★ 修正：處理未來合約（start_date > CURRENT_DATE）
    IF v_contract.start_date > CURRENT_DATE THEN
        -- 合約尚未開始，總期數為 0，下一期為首期
        v_total_periods := 0;
        v_next_due_date := v_contract.start_date;
        v_next_amount := v_contract.monthly_rent * v_cycle_months;
    ELSIF v_end_exclusive IS NOT NULL AND v_end_exclusive <= CURRENT_DATE THEN
        -- 合約已結束，計算全部期數
        SELECT COUNT(*) INTO v_total_periods
        FROM generate_series(0, 999) AS gs(n)
        WHERE v_contract.start_date + (gs.n * v_cycle_interval) < v_end_exclusive;

        v_next_due_date := NULL;
        v_next_amount := NULL;
    ELSE
        -- 合約進行中，計算到目前為止應有的期數
        SELECT COUNT(*) INTO v_total_periods
        FROM generate_series(0, 999) AS gs(n)
        WHERE v_contract.start_date + (gs.n * v_cycle_interval) < CURRENT_DATE;

        v_total_periods := GREATEST(v_total_periods, 1);

        -- 下一期應繳日（稍後可能被待繳記錄覆蓋）
        v_next_due_date := (v_contract.start_date + (v_total_periods * v_cycle_interval))::DATE;
        v_next_amount := v_contract.monthly_rent * v_cycle_months;
    END IF;

    -- 計算各狀態數量
    SELECT
        COUNT(*) FILTER (WHERE payment_status = 'paid'),
        COUNT(*) FILTER (WHERE payment_status = 'pending'),
        COUNT(*) FILTER (WHERE payment_status = 'overdue'),
        SUM(CASE WHEN payment_status = 'paid' THEN amount ELSE 0 END)
    INTO v_paid_periods, v_pending_periods, v_overdue_periods, v_total_paid
    FROM payments
    WHERE contract_id = p_contract_id
      AND payment_type = 'rent';

    -- 計算未建立的期數（只有進行中的合約才計算）
    IF v_total_periods > 0 THEN
        v_not_created_periods := GREATEST(0, v_total_periods - COALESCE(v_paid_periods, 0) - COALESCE(v_pending_periods, 0) - COALESCE(v_overdue_periods, 0));
    ELSE
        v_not_created_periods := 0;
    END IF;

    -- 找下一個應繳日（優先使用待繳記錄）
    SELECT
        due_date,
        amount
    INTO v_next_due_date, v_next_amount
    FROM payments
    WHERE contract_id = p_contract_id
      AND payment_type = 'rent'
      AND payment_status IN ('pending', 'overdue')
    ORDER BY due_date
    LIMIT 1;

    -- 如果沒有待繳記錄且合約已結束
    IF v_next_due_date IS NULL AND v_end_exclusive IS NOT NULL AND CURRENT_DATE >= v_end_exclusive THEN
        v_next_due_date := NULL;
        v_next_amount := NULL;
    -- 如果沒有待繳記錄且合約尚未開始
    ELSIF v_next_due_date IS NULL AND v_contract.start_date > CURRENT_DATE THEN
        v_next_due_date := v_contract.start_date;
        v_next_amount := v_contract.monthly_rent * v_cycle_months;
    -- 如果沒有待繳記錄且合約進行中
    ELSIF v_next_due_date IS NULL AND v_total_periods > 0 THEN
        v_next_due_date := (v_contract.start_date + (v_total_periods * v_cycle_interval))::DATE;
        v_next_amount := v_contract.monthly_rent * v_cycle_months;
    END IF;

    -- 計算預期總額
    v_total_expected := v_contract.monthly_rent * v_cycle_months * GREATEST(v_total_periods, 1);

    RETURN jsonb_build_object(
        'total_periods', v_total_periods,
        'paid_periods', COALESCE(v_paid_periods, 0),
        'pending_periods', COALESCE(v_pending_periods, 0),
        'overdue_periods', COALESCE(v_overdue_periods, 0),
        'not_created_periods', v_not_created_periods,
        'next_due_date', v_next_due_date,
        'next_amount', v_next_amount,
        'total_paid', COALESCE(v_total_paid, 0),
        'total_expected', v_total_expected,
        'payment_cycle', v_contract.payment_cycle,
        'is_billable', true
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 2. 重建 v_payments_due：新增 days_overdue（基於 effective_due_date）
-- ============================================================================

DROP VIEW IF EXISTS v_payments_due CASCADE;

CREATE VIEW v_payments_due AS
WITH payment_data AS (
    SELECT
        p.*,
        -- 有效到期日（優先使用承諾日期）
        COALESCE(p.promised_pay_date, p.due_date) AS effective_due_date,
        -- 是否有有效承諾
        (p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE) AS has_valid_promise
    FROM payments p
    WHERE p.payment_status IN ('pending', 'overdue')
)
SELECT
    pd.id,
    pd.contract_id,
    pd.customer_id,
    pd.branch_id,
    pd.payment_type,
    pd.payment_period,
    pd.amount,
    pd.late_fee,
    pd.due_date,
    pd.payment_status,
    pd.notes,

    -- 承諾付款日期
    pd.promised_pay_date,

    -- has_valid_promise：有有效承諾（承諾日未過期）
    pd.has_valid_promise,

    -- 有效到期日（CTE 計算，避免重複）
    pd.effective_due_date,

    -- ★ 新增：days_overdue 基於 effective_due_date（與 urgency 一致）
    CASE
        WHEN pd.effective_due_date < CURRENT_DATE
        THEN CURRENT_DATE - pd.effective_due_date
        ELSE 0
    END AS days_overdue,

    -- 客戶資訊
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.line_user_id,
    c.risk_level,

    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,

    -- 合約資訊
    ct.contract_number,
    ct.monthly_rent,
    ct.end_date AS contract_end_date,
    ct.status AS contract_status,

    -- 緊急度（使用 CTE 的 effective_due_date）
    CASE
        WHEN pd.has_valid_promise THEN 'waiting_promise'
        WHEN pd.effective_due_date < CURRENT_DATE
             AND (CURRENT_DATE - pd.effective_due_date) > 30 THEN 'critical'
        WHEN pd.effective_due_date < CURRENT_DATE
             AND (CURRENT_DATE - pd.effective_due_date) > 14 THEN 'high'
        WHEN pd.effective_due_date < CURRENT_DATE THEN 'medium'
        WHEN pd.effective_due_date <= CURRENT_DATE + INTERVAL '3 days' THEN 'upcoming'
        ELSE 'normal'
    END AS urgency,

    -- 總應收金額
    pd.amount + COALESCE(pd.late_fee, 0) AS total_due

FROM payment_data pd
JOIN customers c ON pd.customer_id = c.id
JOIN branches b ON pd.branch_id = b.id
LEFT JOIN contracts ct ON pd.contract_id = ct.id
WHERE (ct.status IS NULL OR ct.status NOT IN ('pending_termination', 'terminated'))
  AND (ct.is_billable IS NULL OR ct.is_billable = true)
ORDER BY
    CASE WHEN pd.has_valid_promise THEN 1 ELSE 0 END,
    pd.effective_due_date ASC;

COMMENT ON VIEW v_payments_due IS
'應收款列表（B 監控清單）- days_overdue 與 urgency 均基於 effective_due_date';

GRANT SELECT ON v_payments_due TO anon, authenticated;

-- ============================================================================
-- 3. 驗證
-- ============================================================================

DO $$
DECLARE
    v_future_contract_count INT;
    v_payments_due_count INT;
BEGIN
    -- 檢查是否有未來合約
    SELECT COUNT(*) INTO v_future_contract_count
    FROM contracts
    WHERE start_date > CURRENT_DATE
      AND status NOT IN ('terminated', 'cancelled');

    -- 檢查 v_payments_due
    SELECT COUNT(*) INTO v_payments_due_count FROM v_payments_due;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 077 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '修復項目：';
    RAISE NOTICE '✅ get_contract_billing_summary: 處理未來合約（start_date > CURRENT_DATE）';
    RAISE NOTICE '✅ v_payments_due: 新增 days_overdue（基於 effective_due_date）';
    RAISE NOTICE '✅ v_payments_due: 使用 CTE 避免重複計算 effective_due_date';
    RAISE NOTICE '';
    RAISE NOTICE '--- 統計 ---';
    RAISE NOTICE '未來合約數量: %', v_future_contract_count;
    RAISE NOTICE 'v_payments_due 筆數: %', v_payments_due_count;
END $$;
