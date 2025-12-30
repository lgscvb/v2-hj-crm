-- 076_fix_billing_views_and_cleanup.sql
-- 修正 billing cycles 邊界 + A/B 逾期視圖分流 + 清理 covers_through
--
-- 內容：
-- 1. 修正 get_contract_billing_cycles 的 v_current_period_idx 邊界
-- 2. 修正 get_contract_billing_summary 的 next_amount NULL 邏輯
-- 3. 重建 v_overdue_details（A 行動清單）- promise_expired
-- 4. 重建 v_payments_due（B 監控清單）- has_valid_promise
-- 5. 清理 covers_through 錯誤資料
--
-- Date: 2025-12-30

-- ============================================================================
-- 1. 修正 get_contract_billing_cycles 函數（防止空範圍）
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

    -- 使用 get_contract_end_exclusive 取得動態排他邊界
    v_end_exclusive := get_contract_end_exclusive(v_contract.start_date, v_contract.end_date);

    -- 計算總期數（使用排他邊界）
    IF v_end_exclusive IS NOT NULL THEN
        SELECT COUNT(*) INTO v_total_periods
        FROM generate_series(0, 999) AS gs(n)
        WHERE v_contract.start_date + (gs.n * v_cycle_interval) < v_end_exclusive;
    ELSE
        -- 無結束日期，預設顯示 12 期
        v_total_periods := 12;
    END IF;

    -- 確保至少 1 期
    v_total_periods := GREATEST(v_total_periods, 1);

    -- 找出當前期數
    SELECT COUNT(*) INTO v_current_period_idx
    FROM generate_series(0, 999) AS gs(n)
    WHERE v_contract.start_date + (gs.n * v_cycle_interval) < CURRENT_DATE;

    -- ★ 修正：確保 v_current_period_idx 不超過 v_total_periods
    v_current_period_idx := LEAST(GREATEST(v_current_period_idx, 1), v_total_periods);

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
        inv.invoice_number::TEXT,
        (p.period_index = v_current_period_idx) AS is_current,
        (p.due_date < CURRENT_DATE AND COALESCE(pay.payment_status, 'pending') NOT IN ('paid', 'waived')) AS is_overdue,
        (p.due_date > CURRENT_DATE) AS is_future
    FROM periods p
    LEFT JOIN payments pay
        ON pay.contract_id = p_contract_id
        AND pay.payment_period = p.payment_period
        AND pay.payment_type = 'rent'
    LEFT JOIN payment_invoices pi
        ON pi.payment_id = pay.id
    LEFT JOIN invoices inv
        ON inv.id = pi.invoice_id
    ORDER BY p.period_index;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 2. 修正 get_contract_billing_summary 函數（next_amount 一致性）
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

    -- 計算總期數（使用排他邊界）
    IF v_end_exclusive IS NOT NULL AND v_end_exclusive <= CURRENT_DATE THEN
        -- 合約已結束，計算全部期數
        SELECT COUNT(*) INTO v_total_periods
        FROM generate_series(0, 999) AS gs(n)
        WHERE v_contract.start_date + (gs.n * v_cycle_interval) < v_end_exclusive;
    ELSE
        -- 合約進行中，計算到目前為止應有的期數
        SELECT COUNT(*) INTO v_total_periods
        FROM generate_series(0, 999) AS gs(n)
        WHERE v_contract.start_date + (gs.n * v_cycle_interval) < CURRENT_DATE;
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
        -- 如果合約已結束，不顯示下一期
        IF v_end_exclusive IS NOT NULL AND CURRENT_DATE >= v_end_exclusive THEN
            v_next_due_date := NULL;
            v_next_amount := NULL;  -- ★ 修正：next_due_date 為 NULL 時 next_amount 也為 NULL
        ELSE
            v_next_due_date := (v_contract.start_date + (v_total_periods * v_cycle_interval))::DATE;
            v_next_amount := v_contract.monthly_rent * v_cycle_months;
        END IF;
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
        'next_amount', v_next_amount,  -- ★ 修正：不再用 COALESCE 補值
        'total_paid', COALESCE(v_total_paid, 0),
        'total_expected', v_total_expected,
        'payment_cycle', v_contract.payment_cycle,
        'is_billable', true
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 3. 重建 v_overdue_details（A 行動清單）
-- ============================================================================
-- 語義：只顯示「該催的」，承諾未到期的不出現
-- promise_expired = 曾承諾但違約（承諾日已過期）

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

    -- ★ promise_expired：曾承諾但違約（承諾日已過期）
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
ORDER BY COALESCE(p.promised_pay_date, p.due_date) ASC;

COMMENT ON VIEW v_overdue_details IS
'逾期款項詳情視圖（A 行動清單：承諾未到期者不列，promise_expired 標記違約）';

GRANT SELECT ON v_overdue_details TO anon, authenticated;

-- ============================================================================
-- 4. 重建 v_payments_due（B 監控清單）
-- ============================================================================
-- 語義：全部待收都在，承諾中的保留但標記
-- has_valid_promise = 有有效承諾（承諾日未過期）

DROP VIEW IF EXISTS v_payments_due CASCADE;

CREATE VIEW v_payments_due AS
SELECT
    p.id,
    p.contract_id,
    p.customer_id,
    p.branch_id,
    p.payment_type,
    p.payment_period,
    p.amount,
    p.late_fee,
    p.due_date,
    p.payment_status,
    p.overdue_days,
    p.notes,

    -- 承諾付款日期
    p.promised_pay_date,

    -- ★ has_valid_promise：有有效承諾（承諾日未過期）
    CASE
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
        THEN TRUE
        ELSE FALSE
    END AS has_valid_promise,

    -- 有效到期日
    COALESCE(p.promised_pay_date, p.due_date) AS effective_due_date,

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

    -- 緊急度（改用 effective_due_date）
    CASE
        -- 有承諾日期且未過期 → 等待承諾（不催繳）
        WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE
        THEN 'waiting_promise'
        -- 逾期判斷（基於有效到期日）
        WHEN COALESCE(p.promised_pay_date, p.due_date) < CURRENT_DATE
             AND (CURRENT_DATE - COALESCE(p.promised_pay_date, p.due_date)) > 30
        THEN 'critical'
        WHEN COALESCE(p.promised_pay_date, p.due_date) < CURRENT_DATE
             AND (CURRENT_DATE - COALESCE(p.promised_pay_date, p.due_date)) > 14
        THEN 'high'
        WHEN COALESCE(p.promised_pay_date, p.due_date) < CURRENT_DATE
        THEN 'medium'
        WHEN COALESCE(p.promised_pay_date, p.due_date) <= CURRENT_DATE + INTERVAL '3 days'
        THEN 'upcoming'
        ELSE 'normal'
    END AS urgency,

    -- 總應收金額
    p.amount + COALESCE(p.late_fee, 0) AS total_due

FROM payments p
JOIN customers c ON p.customer_id = c.id
JOIN branches b ON p.branch_id = b.id
LEFT JOIN contracts ct ON p.contract_id = ct.id
WHERE p.payment_status IN ('pending', 'overdue')
  -- 排除解約中/已解約的合約
  AND (ct.status IS NULL OR ct.status NOT IN ('pending_termination', 'terminated'))
  -- 排除非計費合約（內部/免租金座位）
  AND (ct.is_billable IS NULL OR ct.is_billable = true)
ORDER BY
    -- 等待承諾的排在最後
    CASE WHEN p.promised_pay_date IS NOT NULL AND p.promised_pay_date >= CURRENT_DATE THEN 1 ELSE 0 END,
    -- 其餘按有效到期日排序
    COALESCE(p.promised_pay_date, p.due_date) ASC;

COMMENT ON VIEW v_payments_due IS
'應收款列表（B 監控清單：has_valid_promise 標記承諾中，waiting_promise 不催繳）';

GRANT SELECT ON v_payments_due TO anon, authenticated;

-- ============================================================================
-- 5. 清理 covers_through 錯誤資料
-- ============================================================================
-- 清理條件：
-- - covers_through < due_date 且差距 > 7 天
-- - 排除 E 編號（已結束合約）
-- - 只清理 payment_type = 'rent' 且 payment_status = 'paid'

-- 先記錄將被清理的筆數
DO $$
DECLARE
    v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM payments p
    JOIN contracts c ON p.contract_id = c.id
    WHERE p.covers_through IS NOT NULL
      AND p.covers_through < p.due_date
      AND (p.due_date - p.covers_through) > 7
      AND p.payment_type = 'rent'
      AND p.payment_status = 'paid';

    RAISE NOTICE '將清理 % 筆 covers_through 錯誤資料', v_count;
END $$;

-- 執行清理
UPDATE payments p
SET covers_through = NULL
FROM contracts c
WHERE p.contract_id = c.id
  AND p.covers_through IS NOT NULL
  AND p.covers_through < p.due_date
  AND (p.due_date - p.covers_through) > 7
  AND p.payment_type = 'rent'
  AND p.payment_status = 'paid';

-- ============================================================================
-- 6. 驗證
-- ============================================================================

DO $$
DECLARE
    v_remaining_errors INT;
    v_overdue_count INT;
    v_waiting_promise_count INT;
BEGIN
    -- 檢查剩餘錯誤
    SELECT COUNT(*) INTO v_remaining_errors
    FROM payments
    WHERE covers_through IS NOT NULL
      AND covers_through < due_date
      AND (due_date - covers_through) > 7;

    -- 檢查逾期視圖
    SELECT COUNT(*) INTO v_overdue_count FROM v_overdue_details;

    -- 檢查等待承諾數量
    SELECT COUNT(*) INTO v_waiting_promise_count
    FROM v_payments_due
    WHERE urgency = 'waiting_promise';

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 076 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '✅ get_contract_billing_cycles: v_current_period_idx 已加 LEAST clamp';
    RAISE NOTICE '✅ get_contract_billing_summary: next_amount 當 next_due_date 為 NULL 時也為 NULL';
    RAISE NOTICE '✅ v_overdue_details: A 行動清單（promise_expired 標記違約）';
    RAISE NOTICE '✅ v_payments_due: B 監控清單（has_valid_promise 標記承諾中）';
    RAISE NOTICE '✅ covers_through 錯誤資料已清理';
    RAISE NOTICE '';
    RAISE NOTICE '--- 統計 ---';
    RAISE NOTICE '剩餘 covers_through 錯誤: % 筆', v_remaining_errors;
    RAISE NOTICE '逾期款項（行動清單）: % 筆', v_overdue_count;
    RAISE NOTICE '等待承諾: % 筆', v_waiting_promise_count;
END $$;
