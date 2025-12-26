-- Migration: 038_payment_covers_through
-- Description: 新增 covers_through 欄位追蹤預付款涵蓋期間
-- Date: 2025-12-26

-- ============================================================================
-- 1. 新增 covers_through 欄位
-- ============================================================================

ALTER TABLE payments
    ADD COLUMN IF NOT EXISTS covers_through DATE;

COMMENT ON COLUMN payments.covers_through IS '此款項涵蓋到的日期（用於預付款/年繳判斷）';

-- ============================================================================
-- 2. 建立函數：計算款項涵蓋到期日
-- ============================================================================

CREATE OR REPLACE FUNCTION calculate_covers_through(
    p_contract_id INT,
    p_amount NUMERIC,
    p_payment_type TEXT
) RETURNS DATE AS $$
DECLARE
    v_contract RECORD;
    v_months_covered INT;
    v_covers_through DATE;
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
        end_date
    INTO v_contract
    FROM contracts
    WHERE id = p_contract_id;

    IF NOT FOUND OR v_contract.monthly_rent IS NULL OR v_contract.monthly_rent = 0 THEN
        RETURN NULL;
    END IF;

    -- 計算涵蓋月數（扣除可能包含的押金）
    -- 如果金額包含押金（金額 > 月租 * 13），先扣除押金
    IF p_amount > v_contract.monthly_rent * 13 AND v_contract.deposit IS NOT NULL THEN
        v_months_covered := FLOOR((p_amount - v_contract.deposit) / v_contract.monthly_rent);
    ELSE
        v_months_covered := FLOOR(p_amount / v_contract.monthly_rent);
    END IF;

    -- 至少要涵蓋 1 個月
    IF v_months_covered < 1 THEN
        v_months_covered := 1;
    END IF;

    -- 計算涵蓋到期日（從合約開始日起算）
    v_covers_through := v_contract.start_date + (v_months_covered || ' months')::INTERVAL - INTERVAL '1 day';

    -- 不超過合約結束日
    IF v_contract.end_date IS NOT NULL AND v_covers_through > v_contract.end_date THEN
        v_covers_through := v_contract.end_date;
    END IF;

    RETURN v_covers_through;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION calculate_covers_through IS '根據付款金額和合約月租計算涵蓋到期日';

-- ============================================================================
-- 3. 建立觸發器：付款標記為 paid 時自動計算 covers_through
-- ============================================================================

CREATE OR REPLACE FUNCTION auto_set_covers_through()
RETURNS TRIGGER AS $$
BEGIN
    -- 當狀態從 pending 變成 paid，且 covers_through 為空
    IF NEW.payment_status = 'paid'
       AND (OLD.payment_status IS NULL OR OLD.payment_status != 'paid')
       AND NEW.covers_through IS NULL THEN

        NEW.covers_through := calculate_covers_through(
            NEW.contract_id,
            NEW.amount,
            NEW.payment_type
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_auto_set_covers_through ON payments;
CREATE TRIGGER trigger_auto_set_covers_through
    BEFORE UPDATE ON payments
    FOR EACH ROW
    EXECUTE FUNCTION auto_set_covers_through();

COMMENT ON FUNCTION auto_set_covers_through IS '付款標記為 paid 時自動計算涵蓋期間';

-- ============================================================================
-- 4. 修改 generate_monthly_payments 函數：檢查預付款
-- ============================================================================

CREATE OR REPLACE FUNCTION generate_monthly_payments(target_period TEXT DEFAULT NULL)
RETURNS TABLE (
    contracts_processed INT,
    payments_created INT,
    total_amount NUMERIC,
    skipped_existing INT,
    skipped_no_payment INT,
    skipped_prepaid INT
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

        -- ★ 新增：檢查是否有預付款涵蓋此期間
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

    RAISE NOTICE '完成！處理合約: %, 建立記錄: %, 總金額: $%, 已存在跳過: %, 本月無需繳費: %, 預付跳過: %',
        v_contracts_processed, v_payments_created, v_total_amount, v_skipped_existing, v_skipped_no_payment, v_skipped_prepaid;

    RETURN QUERY SELECT
        v_contracts_processed,
        v_payments_created,
        v_total_amount,
        v_skipped_existing,
        v_skipped_no_payment,
        v_skipped_prepaid;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 5. 回填現有已付款項的 covers_through
-- ============================================================================

-- 對所有已付租金款項計算 covers_through
UPDATE payments p
SET covers_through = calculate_covers_through(p.contract_id, p.amount, p.payment_type)
WHERE p.payment_status = 'paid'
  AND p.payment_type = 'rent'
  AND p.covers_through IS NULL;

-- ============================================================================
-- 6. 授權
-- ============================================================================

GRANT EXECUTE ON FUNCTION calculate_covers_through TO anon, authenticated;

-- ============================================================================
-- 7. 驗證
-- ============================================================================

DO $$
DECLARE
    v_count INT;
BEGIN
    SELECT COUNT(*) INTO v_count FROM payments WHERE covers_through IS NOT NULL;
    RAISE NOTICE '=== Payment Covers Through Migration 完成 ===';
    RAISE NOTICE '已新增: covers_through 欄位';
    RAISE NOTICE '已新增: calculate_covers_through 函數';
    RAISE NOTICE '已新增: auto_set_covers_through 觸發器';
    RAISE NOTICE '已修改: generate_monthly_payments 函數（新增預付檢查）';
    RAISE NOTICE '已回填: % 筆款項的 covers_through', v_count;
END $$;
