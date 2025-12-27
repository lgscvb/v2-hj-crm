-- 055_fix_billing_cycles_date_calc.sql
-- 修正 054 中的日期計算錯誤
--
-- 問題：
-- CURRENT_DATE - date 在 PostgreSQL 回傳 INTEGER（天數），不是 INTERVAL
-- EXTRACT(EPOCH FROM integer) 不存在
--
-- 解法：
-- 將天數乘以 INTERVAL '1 day' 轉換回 interval

-- ============================================================================
-- 1. 修正 get_contract_billing_cycles 函數
-- ============================================================================

CREATE OR REPLACE FUNCTION get_contract_billing_cycles(
    p_contract_id INT,
    p_past_n INT DEFAULT 2,
    p_future_n INT DEFAULT 3
)
RETURNS TABLE (
    period_index INT,
    payment_period TEXT,
    due_date DATE,
    expected_amount NUMERIC,
    payment_id INT,
    payment_status TEXT,
    paid_at TIMESTAMPTZ,
    invoice_id INT,
    invoice_status TEXT,
    invoice_number TEXT,
    is_current BOOLEAN,
    is_overdue BOOLEAN,
    is_future BOOLEAN
) AS $$
DECLARE
    v_contract RECORD;
    v_cycle_interval INTERVAL;
    v_cycle_months INT;
    v_total_periods INT;
    v_current_period_idx INT;
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

    -- 如果合約不存在或不計費，回傳空
    IF v_contract IS NULL OR COALESCE(v_contract.is_billable, true) = false THEN
        RETURN;
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

    -- 計算總期數（修正：將天數乘以 interval）
    IF v_contract.end_date IS NOT NULL THEN
        v_total_periods := CEIL(
            EXTRACT(EPOCH FROM ((v_contract.end_date - v_contract.start_date) * INTERVAL '1 day')) /
            EXTRACT(EPOCH FROM v_cycle_interval)
        )::INT;
    ELSE
        -- 無結束日期，預設顯示 12 期
        v_total_periods := 12;
    END IF;

    -- 確保至少 1 期
    v_total_periods := GREATEST(v_total_periods, 1);

    -- 找出當前期數（修正：將天數乘以 interval）
    v_current_period_idx := CEIL(
        EXTRACT(EPOCH FROM ((CURRENT_DATE - v_contract.start_date) * INTERVAL '1 day')) /
        EXTRACT(EPOCH FROM v_cycle_interval)
    )::INT;
    v_current_period_idx := GREATEST(v_current_period_idx, 1);

    -- 回傳週期列表（過去 N 期 + 未來 N 期，以當前期為中心）
    RETURN QUERY
    WITH periods AS (
        SELECT
            gs.idx AS period_index,
            TO_CHAR(
                v_contract.start_date + ((gs.idx - 1) * v_cycle_interval),
                'YYYY-MM'
            ) AS payment_period,
            MAKE_DATE(
                EXTRACT(YEAR FROM (v_contract.start_date + ((gs.idx - 1) * v_cycle_interval)))::INT,
                EXTRACT(MONTH FROM (v_contract.start_date + ((gs.idx - 1) * v_cycle_interval)))::INT,
                LEAST(
                    v_contract.payment_day,
                    EXTRACT(DAY FROM (
                        DATE_TRUNC('month', v_contract.start_date + ((gs.idx - 1) * v_cycle_interval)) +
                        INTERVAL '1 month' - INTERVAL '1 day'
                    ))::INT
                )
            ) AS due_date,
            v_contract.monthly_rent * v_cycle_months AS expected_amount
        FROM generate_series(
            GREATEST(1, v_current_period_idx - p_past_n),
            LEAST(v_total_periods, v_current_period_idx + p_future_n)
        ) AS gs(idx)
    )
    SELECT
        p.period_index::INT,
        p.payment_period,
        p.due_date,
        p.expected_amount,
        pay.id AS payment_id,
        pay.payment_status::TEXT,
        pay.paid_at,
        inv.id AS invoice_id,
        inv.status::TEXT AS invoice_status,
        inv.invoice_number,
        (p.period_index = v_current_period_idx) AS is_current,
        (p.due_date < CURRENT_DATE AND COALESCE(pay.payment_status, 'pending') NOT IN ('paid', 'waived')) AS is_overdue,
        (p.due_date > CURRENT_DATE) AS is_future
    FROM periods p
    LEFT JOIN payments pay
        ON pay.contract_id = p_contract_id
        AND pay.payment_period = p.payment_period
        AND pay.payment_type = 'rent'
    LEFT JOIN invoices inv
        ON inv.payment_id = pay.id
    ORDER BY p.period_index;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 2. 修正 get_contract_billing_summary 函數
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
            'next_amount', 0,
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

    -- 計算總期數（到目前為止應有的期數）（修正：將天數乘以 interval）
    IF v_contract.end_date IS NOT NULL AND v_contract.end_date < CURRENT_DATE THEN
        -- 合約已結束，計算全部期數
        v_total_periods := CEIL(
            EXTRACT(EPOCH FROM ((v_contract.end_date - v_contract.start_date) * INTERVAL '1 day')) /
            EXTRACT(EPOCH FROM v_cycle_interval)
        )::INT;
    ELSE
        -- 合約進行中，計算到目前為止應有的期數
        v_total_periods := CEIL(
            EXTRACT(EPOCH FROM ((CURRENT_DATE - v_contract.start_date) * INTERVAL '1 day')) /
            EXTRACT(EPOCH FROM v_cycle_interval)
        )::INT;
    END IF;
    v_total_periods := GREATEST(v_total_periods, 1);

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

    -- 計算未建立的期數
    v_not_created_periods := GREATEST(0, v_total_periods - v_paid_periods - v_pending_periods - v_overdue_periods);

    -- 找下一個應繳日
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

    -- 如果沒有待繳記錄，計算下一期應繳日
    IF v_next_due_date IS NULL THEN
        v_next_due_date := (v_contract.start_date + (v_total_periods * v_cycle_interval))::DATE;
        v_next_amount := v_contract.monthly_rent * v_cycle_months;
    END IF;

    -- 計算預期總額
    v_total_expected := v_contract.monthly_rent * v_cycle_months * v_total_periods;

    RETURN jsonb_build_object(
        'total_periods', v_total_periods,
        'paid_periods', COALESCE(v_paid_periods, 0),
        'pending_periods', COALESCE(v_pending_periods, 0),
        'overdue_periods', COALESCE(v_overdue_periods, 0),
        'not_created_periods', v_not_created_periods,
        'next_due_date', v_next_due_date,
        'next_amount', COALESCE(v_next_amount, v_contract.monthly_rent * v_cycle_months),
        'total_paid', COALESCE(v_total_paid, 0),
        'total_expected', v_total_expected,
        'payment_cycle', v_contract.payment_cycle,
        'is_billable', true
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 完成提示
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 055 完成 ===';
    RAISE NOTICE '✅ get_contract_billing_cycles 日期計算已修正';
    RAISE NOTICE '✅ get_contract_billing_summary 日期計算已修正';
END $$;
