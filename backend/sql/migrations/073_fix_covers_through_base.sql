-- 073_fix_covers_through_base.sql
-- 修正 covers_through 計算基準 + 統一合約結束日邊界判斷
--
-- 核心問題：
-- 1. covers_through 從 contract.start_date 起算，但應從「上次已付區間」接續
-- 2. end_date 的語義不一致（有的含當日、有的排他）
-- 3. generate_monthly_payments 在 070 移除了預付跳過邏輯
--
-- 解法：
-- 1. 建立 get_contract_end_exclusive(start_date, end_date) 動態推導排他邊界
-- 2. 修正 calculate_covers_through 從上次已付區間開始
-- 3. generate_monthly_payments 使用新的 helper + 恢復預付跳過
--
-- Date: 2025-12-29

-- ============================================================================
-- 1. 建立 get_contract_end_exclusive 函數
-- ============================================================================
-- 規則：
-- - 同日（start_day == end_day）或月末對齊 → 視為排他邊界（不加 1 天）
-- - 否則視為含當日 → 排他邊界 = end_date + 1 day
--
-- 這樣可以兼容：
-- - 新合約（2023-12-07 ~ 2025-12-07）→ 同日 → end_exclusive = 2025-12-07
-- - 舊合約（2023-12-07 ~ 2025-12-06）→ 不同日 → end_exclusive = 2025-12-07

CREATE OR REPLACE FUNCTION get_contract_end_exclusive(
    p_start_date DATE,
    p_end_date DATE
) RETURNS DATE AS $$
DECLARE
    v_start_day INT;
    v_end_day INT;
    v_start_is_eom BOOLEAN;
    v_end_is_eom BOOLEAN;
BEGIN
    -- 如果沒有結束日，回傳 NULL
    IF p_end_date IS NULL THEN
        RETURN NULL;
    END IF;

    -- 取得日期的「日」
    v_start_day := EXTRACT(DAY FROM p_start_date);
    v_end_day := EXTRACT(DAY FROM p_end_date);

    -- 判斷是否為月末
    v_start_is_eom := (p_start_date = (DATE_TRUNC('month', p_start_date) + INTERVAL '1 month' - INTERVAL '1 day')::DATE);
    v_end_is_eom := (p_end_date = (DATE_TRUNC('month', p_end_date) + INTERVAL '1 month' - INTERVAL '1 day')::DATE);

    -- 規則判斷
    IF v_start_day = v_end_day THEN
        -- 同日 → 視為「剛好 N 週期」→ end_date 本身就是排他邊界
        RETURN p_end_date;
    ELSIF v_start_is_eom AND v_end_is_eom THEN
        -- 月末對齊 → 同樣視為「剛好 N 週期」
        RETURN p_end_date;
    ELSE
        -- 不同日 → 視為「含當日」→ 排他邊界 = end_date + 1 day
        RETURN p_end_date + INTERVAL '1 day';
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION get_contract_end_exclusive IS
'動態推導合約結束日的排他邊界。同日或月末對齊視為排他，否則視為含當日需加 1 天。';

-- ============================================================================
-- 2. 修正 calculate_covers_through 函數
-- ============================================================================
-- 變更：
-- - 從「上次已付區間」接續計算，而非從 start_date
-- - 首期已付且金額包含押金時，扣除押金
-- - 使用 get_contract_end_exclusive 作為上限

CREATE OR REPLACE FUNCTION calculate_covers_through(
    p_contract_id INT,
    p_amount NUMERIC,
    p_payment_type TEXT
) RETURNS DATE AS $$
DECLARE
    v_contract RECORD;
    v_prev_covers_through DATE;
    v_coverage_start DATE;
    v_months_covered INT;
    v_covers_through DATE;
    v_end_exclusive DATE;
    v_rent_amount NUMERIC;
    v_has_prior_paid BOOLEAN;
    v_cycle_months INT;
BEGIN
    -- 只處理租金類型
    IF p_payment_type != 'rent' THEN
        RETURN NULL;
    END IF;

    -- 取得合約資訊
    SELECT
        monthly_rent,
        deposit,
        start_date,
        end_date,
        COALESCE(payment_cycle, 'monthly') AS payment_cycle
    INTO v_contract
    FROM contracts
    WHERE id = p_contract_id;

    IF NOT FOUND OR v_contract.monthly_rent IS NULL OR v_contract.monthly_rent = 0 THEN
        RETURN NULL;
    END IF;

    -- 取得繳費週期月數
    CASE v_contract.payment_cycle
        WHEN 'monthly' THEN v_cycle_months := 1;
        WHEN 'quarterly' THEN v_cycle_months := 3;
        WHEN 'semi_annual' THEN v_cycle_months := 6;
        WHEN 'annual' THEN v_cycle_months := 12;
        WHEN 'biennial' THEN v_cycle_months := 24;
        WHEN 'triennial' THEN v_cycle_months := 36;
        ELSE v_cycle_months := 1;
    END CASE;

    -- 查找上次已付款項的 covers_through
    SELECT MAX(covers_through) INTO v_prev_covers_through
    FROM payments
    WHERE contract_id = p_contract_id
      AND payment_type = 'rent'
      AND payment_status = 'paid'
      AND covers_through IS NOT NULL;

    -- 判斷是否有先前已付款項
    v_has_prior_paid := (v_prev_covers_through IS NOT NULL);

    -- 計算起始點
    IF v_has_prior_paid THEN
        -- 從上次涵蓋日期的下一天開始
        v_coverage_start := v_prev_covers_through + INTERVAL '1 day';
    ELSE
        -- 首期，從合約開始日起算
        v_coverage_start := v_contract.start_date;
    END IF;

    -- 計算租金金額（首期可能包含押金）
    IF NOT v_has_prior_paid
       AND v_contract.deposit IS NOT NULL
       AND v_contract.deposit > 0
       AND p_amount >= v_contract.deposit + v_contract.monthly_rent * v_cycle_months THEN
        -- 首期且金額足以涵蓋押金+至少一期租金 → 扣除押金
        v_rent_amount := p_amount - v_contract.deposit;
    ELSE
        v_rent_amount := p_amount;
    END IF;

    -- 計算涵蓋月數
    v_months_covered := GREATEST(FLOOR(v_rent_amount / v_contract.monthly_rent)::INT, 1);

    -- 計算涵蓋到期日
    v_covers_through := (v_coverage_start + (v_months_covered || ' months')::INTERVAL - INTERVAL '1 day')::DATE;

    -- 取得合約結束日的排他邊界
    v_end_exclusive := get_contract_end_exclusive(v_contract.start_date, v_contract.end_date);

    -- 不超過合約結束日（排他邊界 - 1 天 = 最後有效服務日）
    IF v_end_exclusive IS NOT NULL AND v_covers_through >= v_end_exclusive THEN
        v_covers_through := v_end_exclusive - INTERVAL '1 day';
    END IF;

    RETURN v_covers_through;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION calculate_covers_through IS
'根據付款金額計算涵蓋到期日。從上次已付區間接續，首期可扣除押金。';

-- ============================================================================
-- 3. 修正 generate_monthly_payments 函數
-- ============================================================================
-- 變更：
-- - 使用 get_contract_end_exclusive 判斷合約邊界
-- - 恢復預付款跳過邏輯（skipped_prepaid）
-- - 只在 v_due_date < v_end_exclusive 時產生付款

DROP FUNCTION IF EXISTS generate_monthly_payments(TEXT);

CREATE OR REPLACE FUNCTION generate_monthly_payments(target_period TEXT DEFAULT NULL)
RETURNS TABLE (
    contracts_processed INT,
    payments_created INT,
    total_amount NUMERIC,
    skipped_existing INT,
    skipped_no_payment INT,
    skipped_prepaid INT,
    skipped_beyond_contract INT
) AS $$
DECLARE
    v_target_year INT;
    v_target_month INT;
    v_target_period TEXT;
    v_target_start DATE;
    v_target_end DATE;
    v_contracts_processed INT := 0;
    v_payments_created INT := 0;
    v_total_amount NUMERIC := 0;
    v_skipped_existing INT := 0;
    v_skipped_no_payment INT := 0;
    v_skipped_prepaid INT := 0;
    v_skipped_beyond_contract INT := 0;
    v_contract RECORD;
    v_payment_day INT;
    v_due_date DATE;
    v_amount NUMERIC;
    v_multiplier INT;
    v_should_create BOOLEAN;
    v_existing_count INT;
    v_prepaid_through DATE;
    v_end_exclusive DATE;
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

    -- 遍歷所有活躍合約
    FOR v_contract IN
        SELECT
            c.id,
            c.customer_id,
            c.branch_id,
            c.start_date,
            c.end_date,
            c.monthly_rent,
            COALESCE(c.payment_cycle, 'monthly') AS payment_cycle,
            COALESCE(c.payment_day, EXTRACT(DAY FROM c.start_date)::INT) AS payment_day,
            COALESCE(c.is_billable, true) AS is_billable
        FROM contracts c
        WHERE c.status = 'active'
          AND c.start_date <= v_target_end  -- 合約已開始
          AND (c.end_date IS NULL OR c.end_date >= v_target_start)  -- 合約未結束
    LOOP
        v_contracts_processed := v_contracts_processed + 1;
        v_should_create := FALSE;
        v_multiplier := 1;

        -- 檢查是否可計費
        IF NOT v_contract.is_billable OR v_contract.monthly_rent IS NULL OR v_contract.monthly_rent <= 0 THEN
            v_skipped_no_payment := v_skipped_no_payment + 1;
            CONTINUE;
        END IF;

        -- 根據繳費週期判斷是否需要在目標月份繳費
        CASE v_contract.payment_cycle
            WHEN 'monthly' THEN
                v_should_create := TRUE;
                v_multiplier := 1;

            WHEN 'quarterly' THEN
                IF (v_target_month - EXTRACT(MONTH FROM v_contract.start_date)::INT + 12) % 3 = 0 THEN
                    v_should_create := TRUE;
                    v_multiplier := 3;
                END IF;

            WHEN 'semi_annual' THEN
                IF (v_target_month - EXTRACT(MONTH FROM v_contract.start_date)::INT + 12) % 6 = 0 THEN
                    v_should_create := TRUE;
                    v_multiplier := 6;
                END IF;

            WHEN 'annual' THEN
                IF EXTRACT(MONTH FROM v_contract.start_date) = v_target_month THEN
                    v_should_create := TRUE;
                    v_multiplier := 12;
                END IF;

            WHEN 'biennial' THEN
                IF EXTRACT(MONTH FROM v_contract.start_date) = v_target_month THEN
                    IF ((v_target_year - EXTRACT(YEAR FROM v_contract.start_date)::INT) * 12 +
                        (v_target_month - EXTRACT(MONTH FROM v_contract.start_date)::INT)) % 24 = 0 THEN
                        v_should_create := TRUE;
                        v_multiplier := 24;
                    END IF;
                END IF;

            WHEN 'triennial' THEN
                IF EXTRACT(MONTH FROM v_contract.start_date) = v_target_month THEN
                    IF ((v_target_year - EXTRACT(YEAR FROM v_contract.start_date)::INT) * 12 +
                        (v_target_month - EXTRACT(MONTH FROM v_contract.start_date)::INT)) % 36 = 0 THEN
                        v_should_create := TRUE;
                        v_multiplier := 36;
                    END IF;
                END IF;

            ELSE
                v_should_create := TRUE;
                v_multiplier := 1;
        END CASE;

        IF NOT v_should_create THEN
            v_skipped_no_payment := v_skipped_no_payment + 1;
            CONTINUE;
        END IF;

        -- 計算繳費日（考慮月底）
        v_payment_day := LEAST(v_contract.payment_day, EXTRACT(DAY FROM v_target_end)::INT);
        v_due_date := MAKE_DATE(v_target_year, v_target_month, v_payment_day);

        -- 確保合約在繳費日前已開始
        IF v_contract.start_date > v_due_date THEN
            v_skipped_no_payment := v_skipped_no_payment + 1;
            CONTINUE;
        END IF;

        -- ★ 使用 get_contract_end_exclusive 判斷合約邊界
        v_end_exclusive := get_contract_end_exclusive(v_contract.start_date, v_contract.end_date);

        -- 如果 due_date >= end_exclusive，代表這期付款已超出合約
        IF v_end_exclusive IS NOT NULL AND v_due_date >= v_end_exclusive THEN
            v_skipped_beyond_contract := v_skipped_beyond_contract + 1;
            RAISE NOTICE '合約 % 的 % 期 due_date (%) >= end_exclusive (%)，跳過',
                v_contract.id, v_target_period, v_due_date, v_end_exclusive;
            CONTINUE;
        END IF;

        -- 檢查是否已有記錄（paid 或 pending）
        SELECT COUNT(*) INTO v_existing_count
        FROM payments
        WHERE contract_id = v_contract.id
          AND payment_period = v_target_period
          AND payment_type = 'rent';

        IF v_existing_count > 0 THEN
            v_skipped_existing := v_skipped_existing + 1;
            CONTINUE;
        END IF;

        -- ★ 恢復：檢查是否有預付款涵蓋此期間
        SELECT MAX(covers_through) INTO v_prepaid_through
        FROM payments
        WHERE contract_id = v_contract.id
          AND payment_type = 'rent'
          AND payment_status = 'paid'
          AND covers_through IS NOT NULL;

        IF v_prepaid_through IS NOT NULL AND v_prepaid_through >= v_due_date THEN
            v_skipped_prepaid := v_skipped_prepaid + 1;
            RAISE NOTICE '合約 % 已有預付款涵蓋至 %，跳過 %', v_contract.id, v_prepaid_through, v_target_period;
            CONTINUE;
        END IF;

        -- 計算金額
        v_amount := v_contract.monthly_rent * v_multiplier;

        -- 建立待繳記錄
        INSERT INTO payments (
            contract_id,
            customer_id,
            branch_id,
            payment_type,
            payment_period,
            amount,
            due_date,
            payment_status
        ) VALUES (
            v_contract.id,
            v_contract.customer_id,
            v_contract.branch_id,
            'rent',
            v_target_period,
            v_amount,
            v_due_date,
            'pending'
        );

        v_payments_created := v_payments_created + 1;
        v_total_amount := v_total_amount + v_amount;

    END LOOP;

    RAISE NOTICE '完成！處理合約: %, 建立記錄: %, 總金額: $%, 已存在跳過: %, 本月無需繳費: %, 預付跳過: %, 超出合約: %',
        v_contracts_processed, v_payments_created, v_total_amount,
        v_skipped_existing, v_skipped_no_payment, v_skipped_prepaid, v_skipped_beyond_contract;

    RETURN QUERY SELECT
        v_contracts_processed,
        v_payments_created,
        v_total_amount,
        v_skipped_existing,
        v_skipped_no_payment,
        v_skipped_prepaid,
        v_skipped_beyond_contract;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_monthly_payments IS
'生成指定月份的待繳記錄。使用動態排他邊界、預付款跳過、is_billable 過濾。';

-- ============================================================================
-- 4. 回填既有 paid 款項的 covers_through
-- ============================================================================

-- 只回填 covers_through 為 NULL 的已付款項
UPDATE payments p
SET covers_through = calculate_covers_through(p.contract_id, p.amount, p.payment_type)
WHERE p.payment_status = 'paid'
  AND p.payment_type = 'rent'
  AND p.covers_through IS NULL;

-- ============================================================================
-- 5. 授權
-- ============================================================================

GRANT EXECUTE ON FUNCTION get_contract_end_exclusive TO anon, authenticated;
GRANT EXECUTE ON FUNCTION calculate_covers_through TO anon, authenticated;
GRANT EXECUTE ON FUNCTION generate_monthly_payments TO anon, authenticated;

-- ============================================================================
-- 6. 驗證
-- ============================================================================

DO $$
DECLARE
    v_test_result DATE;
    v_backfill_count INT;
BEGIN
    -- 測試 get_contract_end_exclusive
    -- Case 1: 同日 (2023-12-07 ~ 2025-12-07) → 應回傳 2025-12-07
    v_test_result := get_contract_end_exclusive('2023-12-07'::DATE, '2025-12-07'::DATE);
    IF v_test_result != '2025-12-07'::DATE THEN
        RAISE EXCEPTION '測試失敗: 同日案例應回傳 2025-12-07，實際 %', v_test_result;
    END IF;

    -- Case 2: 不同日 (2023-12-07 ~ 2025-12-06) → 應回傳 2025-12-07
    v_test_result := get_contract_end_exclusive('2023-12-07'::DATE, '2025-12-06'::DATE);
    IF v_test_result != '2025-12-07'::DATE THEN
        RAISE EXCEPTION '測試失敗: 不同日案例應回傳 2025-12-07，實際 %', v_test_result;
    END IF;

    -- Case 3: 月末對齊 (2023-01-31 ~ 2025-01-31) → 應回傳 2025-01-31
    v_test_result := get_contract_end_exclusive('2023-01-31'::DATE, '2025-01-31'::DATE);
    IF v_test_result != '2025-01-31'::DATE THEN
        RAISE EXCEPTION '測試失敗: 月末對齊應回傳 2025-01-31，實際 %', v_test_result;
    END IF;

    -- 計算回填數量
    SELECT COUNT(*) INTO v_backfill_count
    FROM payments
    WHERE covers_through IS NOT NULL
      AND payment_status = 'paid'
      AND payment_type = 'rent';

    RAISE NOTICE '=== Migration 073 完成 ===';
    RAISE NOTICE '✅ get_contract_end_exclusive 函數已建立並通過測試';
    RAISE NOTICE '✅ calculate_covers_through 已修正為從上次已付區間接續';
    RAISE NOTICE '✅ generate_monthly_payments 已恢復預付跳過 + 使用動態邊界';
    RAISE NOTICE '✅ 已回填 % 筆已付款項的 covers_through', v_backfill_count;
END $$;
