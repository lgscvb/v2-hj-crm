-- 070_fix_payment_generation_boundary.sql
-- 修正付款生成邊界條件：due_date >= end_date 時不應產生付款
--
-- 問題：
-- generate_monthly_payments 只檢查 c.end_date >= v_target_start（月初）
-- 但沒有檢查付款的 due_date 是否超出合約期限
--
-- 例如：DZ-058 合約 2023-12-07 ~ 2025-12-07（半年繳）
-- 原本：2025-12-01 的檢查通過 → 產生 2025-12 期付款（due_date = 2025-12-07）
-- 正確：due_date = end_date → 不應產生（這期服務期間已超出合約）
--
-- 解法：
-- 在計算 due_date 後，檢查是否 >= contract.end_date，若是則跳過
-- Date: 2025-12-29

-- ============================================================================
-- 修正 generate_monthly_payments 函數
-- ============================================================================

CREATE OR REPLACE FUNCTION generate_monthly_payments(target_period TEXT DEFAULT NULL)
RETURNS TABLE (
    contracts_processed INT,
    payments_created INT,
    total_amount NUMERIC,
    skipped_existing INT,
    skipped_no_payment INT,
    skipped_prepaid INT,
    skipped_beyond_contract INT  -- ★ 新增：超出合約期限跳過
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
    v_skipped_beyond_contract INT := 0;  -- ★ 新增
    v_contract RECORD;
    v_payment_day INT;
    v_due_date DATE;
    v_amount NUMERIC;
    v_multiplier INT;
    v_should_create BOOLEAN;
    v_existing_count INT;
    v_prepaid_through DATE;
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
            COALESCE(c.payment_day, EXTRACT(DAY FROM c.start_date)::INT) AS payment_day
        FROM contracts c
        WHERE c.status = 'active'
          AND c.start_date <= v_target_end  -- 合約已開始
          AND (c.end_date IS NULL OR c.end_date >= v_target_start)  -- 合約未結束
    LOOP
        v_contracts_processed := v_contracts_processed + 1;
        v_should_create := FALSE;
        v_multiplier := 1;

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

        -- ★ 新增：檢查 due_date 是否超出合約期限
        -- 如果 due_date >= end_date，代表這期付款的服務期間已超出合約
        IF v_contract.end_date IS NOT NULL AND v_due_date >= v_contract.end_date THEN
            v_skipped_beyond_contract := v_skipped_beyond_contract + 1;
            RAISE NOTICE '合約 % 的 % 期 due_date (%) >= end_date (%)，跳過',
                v_contract.id, v_target_period, v_due_date, v_contract.end_date;
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

        -- 檢查是否有預付款涵蓋此期間
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

-- ============================================================================
-- 完成提示
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 070 完成 ===';
    RAISE NOTICE '✅ generate_monthly_payments 新增 due_date >= end_date 檢查';
    RAISE NOTICE '';
    RAISE NOTICE '修正說明：';
    RAISE NOTICE '- 原本只檢查 end_date >= 月初，漏掉月中/月底到期的情況';
    RAISE NOTICE '- 現在檢查 due_date >= end_date 時跳過該期付款';
    RAISE NOTICE '- 新增 skipped_beyond_contract 回傳值';
END $$;
