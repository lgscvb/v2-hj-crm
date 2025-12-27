-- 053_fix_zero_amount_overdue.sql
-- 修正 $0 付款出現在逾期列表的問題
--
-- 問題：
-- 1. v_overdue_details 沒有排除 amount = 0 的記錄
-- 2. generate_monthly_payments 沒有過濾 is_billable = false 或 monthly_rent = 0 的合約
--
-- 解法：
-- 1. v_overdue_details 加入 amount > 0 條件
-- 2. generate_monthly_payments 加入 is_billable = true AND monthly_rent > 0 條件

-- ============================================================================
-- 1. 修正 v_overdue_details 視圖
-- ============================================================================

DROP VIEW IF EXISTS v_overdue_details CASCADE;

CREATE OR REPLACE VIEW v_overdue_details AS
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
    (CURRENT_DATE - p.due_date) AS days_overdue,
    CASE
        WHEN (CURRENT_DATE - p.due_date) <= 7 THEN 'warning'
        WHEN (CURRENT_DATE - p.due_date) <= 30 THEN 'danger'
        ELSE 'critical'
    END AS urgency_level
FROM payments p
JOIN customers cu ON p.customer_id = cu.id
LEFT JOIN contracts c ON p.contract_id = c.id
LEFT JOIN branches b ON p.branch_id = b.id
WHERE p.payment_status IN ('pending', 'overdue')
  AND p.due_date < CURRENT_DATE
  AND p.amount > 0  -- ★ 新增：排除 $0 的記錄
ORDER BY p.due_date ASC;

COMMENT ON VIEW v_overdue_details IS '逾期款項詳情視圖（排除 $0 記錄）';

GRANT SELECT ON v_overdue_details TO anon, authenticated;

-- ============================================================================
-- 2. 修正 generate_monthly_payments 函數
-- ============================================================================

CREATE OR REPLACE FUNCTION generate_monthly_payments(target_period TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_target_period TEXT;
    v_target_year INT;
    v_target_month INT;
    v_target_start DATE;
    v_target_end DATE;
    v_contract RECORD;
    v_due_date DATE;
    v_payment_exists BOOLEAN;
    v_should_create BOOLEAN;
    v_multiplier INT;
    v_amount NUMERIC(10,2);
    v_covers_through DATE;
    v_contracts_processed INT := 0;
    v_payments_created INT := 0;
    v_payments_skipped INT := 0;
BEGIN
    -- 如果沒有指定期間，使用當月
    IF target_period IS NULL THEN
        v_target_period := TO_CHAR(CURRENT_DATE, 'YYYY-MM');
    ELSE
        v_target_period := target_period;
    END IF;

    -- 解析年月
    v_target_year := EXTRACT(YEAR FROM (v_target_period || '-01')::DATE);
    v_target_month := EXTRACT(MONTH FROM (v_target_period || '-01')::DATE);
    v_target_start := (v_target_period || '-01')::DATE;
    v_target_end := (v_target_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE;

    RAISE NOTICE '生成 % 待繳記錄...', v_target_period;

    -- 遍歷所有活躍合約（排除 is_billable = false 和 monthly_rent = 0）
    FOR v_contract IN
        SELECT
            c.id,
            c.customer_id,
            c.branch_id,
            c.start_date,
            c.end_date,
            c.monthly_rent,
            COALESCE(c.payment_cycle, 'monthly') AS payment_cycle,
            COALESCE(c.payment_day, EXTRACT(DAY FROM c.start_date)::INT) AS payment_day
        FROM contracts c
        WHERE c.status = 'active'
          AND c.start_date <= v_target_end  -- 合約已開始
          AND (c.end_date IS NULL OR c.end_date >= v_target_start)  -- 合約未結束
          AND COALESCE(c.is_billable, true) = true  -- ★ 新增：只處理需要計費的合約
          AND COALESCE(c.monthly_rent, 0) > 0       -- ★ 新增：只處理月租 > 0 的合約
    LOOP
        v_contracts_processed := v_contracts_processed + 1;
        v_should_create := FALSE;
        v_multiplier := 1;

        -- 根據繳費週期判斷是否需要在目標月份繳費
        CASE v_contract.payment_cycle
            WHEN 'monthly' THEN
                -- 每月都要繳
                v_should_create := TRUE;
                v_multiplier := 1;

            WHEN 'quarterly' THEN
                -- 每季繳費：開始月份、+3、+6、+9
                IF (v_target_month - EXTRACT(MONTH FROM v_contract.start_date)::INT + 12) % 3 = 0 THEN
                    v_should_create := TRUE;
                    v_multiplier := 3;
                END IF;

            WHEN 'semi_annual' THEN
                -- 半年繳費：開始月份、+6
                IF (v_target_month - EXTRACT(MONTH FROM v_contract.start_date)::INT + 12) % 6 = 0 THEN
                    v_should_create := TRUE;
                    v_multiplier := 6;
                END IF;

            WHEN 'annual' THEN
                -- 年繳：只有開始月份
                IF v_target_month = EXTRACT(MONTH FROM v_contract.start_date)::INT THEN
                    v_should_create := TRUE;
                    v_multiplier := 12;
                END IF;

            WHEN 'biennial' THEN
                -- 兩年繳：開始月份且年份差為偶數
                IF v_target_month = EXTRACT(MONTH FROM v_contract.start_date)::INT
                   AND (v_target_year - EXTRACT(YEAR FROM v_contract.start_date)::INT) % 2 = 0 THEN
                    v_should_create := TRUE;
                    v_multiplier := 24;
                END IF;

            WHEN 'triennial' THEN
                -- 三年繳：開始月份且年份差為 3 的倍數
                IF v_target_month = EXTRACT(MONTH FROM v_contract.start_date)::INT
                   AND (v_target_year - EXTRACT(YEAR FROM v_contract.start_date)::INT) % 3 = 0 THEN
                    v_should_create := TRUE;
                    v_multiplier := 36;
                END IF;

            ELSE
                -- 預設每月
                v_should_create := TRUE;
                v_multiplier := 1;
        END CASE;

        IF v_should_create THEN
            -- 檢查是否已有該期記錄
            SELECT EXISTS (
                SELECT 1 FROM payments
                WHERE contract_id = v_contract.id
                  AND payment_period = v_target_period
                  AND payment_type = 'rent'
            ) INTO v_payment_exists;

            IF NOT v_payment_exists THEN
                -- 計算繳費日
                v_due_date := MAKE_DATE(v_target_year, v_target_month,
                    LEAST(v_contract.payment_day, EXTRACT(DAY FROM v_target_end)::INT));

                -- 計算金額
                v_amount := v_contract.monthly_rent * v_multiplier;

                -- 計算涵蓋期間
                v_covers_through := (v_target_start + (v_multiplier || ' months')::INTERVAL - INTERVAL '1 day')::DATE;

                -- 建立待繳記錄
                INSERT INTO payments (
                    contract_id,
                    customer_id,
                    branch_id,
                    payment_type,
                    payment_period,
                    amount,
                    due_date,
                    payment_status,
                    covers_through
                ) VALUES (
                    v_contract.id,
                    v_contract.customer_id,
                    v_contract.branch_id,
                    'rent',
                    v_target_period,
                    v_amount,
                    v_due_date,
                    'pending',
                    v_covers_through
                );

                v_payments_created := v_payments_created + 1;
            ELSE
                v_payments_skipped := v_payments_skipped + 1;
            END IF;
        END IF;
    END LOOP;

    RAISE NOTICE '完成：處理 % 合約，建立 % 筆待繳，跳過 % 筆',
        v_contracts_processed, v_payments_created, v_payments_skipped;

    RETURN jsonb_build_object(
        'success', true,
        'period', v_target_period,
        'contracts_processed', v_contracts_processed,
        'payments_created', v_payments_created,
        'payments_skipped', v_payments_skipped
    );
END;
$$;

COMMENT ON FUNCTION generate_monthly_payments IS '生成月繳待繳記錄（排除 is_billable=false 和 monthly_rent=0 的合約）';

-- ============================================================================
-- 3. 修正 v_pending_payments_preview 視圖（如果存在）
-- ============================================================================

DROP VIEW IF EXISTS v_pending_payments_preview CASCADE;

CREATE OR REPLACE VIEW v_pending_payments_preview AS
SELECT
    c.id AS contract_id,
    c.contract_number,
    c.customer_id,
    cu.name AS customer_name,
    cu.company_name,
    c.branch_id,
    b.name AS branch_name,
    c.monthly_rent,
    c.payment_cycle,
    c.payment_day,
    c.start_date,
    c.end_date,
    c.is_billable,
    -- 計算下次繳費月份
    CASE
        WHEN c.payment_cycle = 'monthly' THEN TO_CHAR(CURRENT_DATE, 'YYYY-MM')
        ELSE TO_CHAR(CURRENT_DATE, 'YYYY-MM')
    END AS next_payment_period
FROM contracts c
JOIN customers cu ON c.customer_id = cu.id
JOIN branches b ON c.branch_id = b.id
WHERE c.status = 'active'
  AND COALESCE(c.is_billable, true) = true  -- ★ 排除不計費
  AND COALESCE(c.monthly_rent, 0) > 0       -- ★ 排除 $0 月租
ORDER BY c.branch_id, cu.name;

COMMENT ON VIEW v_pending_payments_preview IS '待生成繳費預覽（排除 is_billable=false 和 monthly_rent=0）';

GRANT SELECT ON v_pending_payments_preview TO anon, authenticated;

-- ============================================================================
-- 4. 清理現有的 $0 逾期記錄（標記為 paid）
-- ============================================================================

UPDATE payments
SET payment_status = 'paid',
    paid_at = NOW(),
    notes = COALESCE(notes, '') || ' [系統自動標記：金額為 $0]'
WHERE amount = 0
  AND payment_status IN ('pending', 'overdue');

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
DECLARE
    v_cleaned INT;
BEGIN
    GET DIAGNOSTICS v_cleaned = ROW_COUNT;
    RAISE NOTICE '=== Migration 053 完成 ===';
    RAISE NOTICE '✅ v_overdue_details 視圖已更新（排除 amount = 0）';
    RAISE NOTICE '✅ generate_monthly_payments 函數已更新（排除 is_billable=false, monthly_rent=0）';
    RAISE NOTICE '✅ v_pending_payments_preview 視圖已更新';
    RAISE NOTICE '✅ 已清理 % 筆 $0 逾期記錄', v_cleaned;
END $$;
