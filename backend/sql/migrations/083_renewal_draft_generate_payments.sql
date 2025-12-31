-- 083_renewal_draft_generate_payments.sql
-- 續約草稿自動產生付款記錄
--
-- 問題：
-- 建立續約草稿後，Workspace 的「首期收款」顯示「未開始」
-- 因為 renewal_draft 沒有對應的付款記錄
--
-- 解法：
-- 建立函數 generate_renewal_payments(contract_id)
-- 在建立續約草稿後呼叫，產生首期付款記錄（pending 狀態）
--
-- Date: 2025-12-31

-- ============================================================================
-- 函數：為續約合約產生付款記錄
-- ============================================================================

CREATE OR REPLACE FUNCTION generate_renewal_payments(
    p_contract_id INT,
    p_periods INT DEFAULT 1  -- 預設只產生首期，可選產生多期
)
RETURNS JSONB AS $$
DECLARE
    v_contract RECORD;
    v_payment_day INT;
    v_multiplier INT;
    v_amount NUMERIC;
    v_period_start DATE;
    v_period_end DATE;
    v_payment_period TEXT;
    v_due_date DATE;
    v_created_count INT := 0;
    v_skipped_count INT := 0;
    v_total_amount NUMERIC := 0;
    v_existing_count INT;
    i INT;
BEGIN
    -- 1. 取得合約資訊
    SELECT
        c.*,
        COALESCE(c.payment_day, EXTRACT(DAY FROM c.start_date)::INT) AS calc_payment_day
    INTO v_contract
    FROM contracts c
    WHERE c.id = p_contract_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '找不到合約');
    END IF;

    -- 2. 只處理 renewal_draft 或 active 狀態
    IF v_contract.status NOT IN ('renewal_draft', 'active', 'pending_sign', 'signed') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('合約狀態為 %s，無法產生付款記錄', v_contract.status)
        );
    END IF;

    -- 3. 計算繳費週期乘數
    v_multiplier := CASE v_contract.payment_cycle
        WHEN 'monthly' THEN 1
        WHEN 'quarterly' THEN 3
        WHEN 'semi_annual' THEN 6
        WHEN 'annual' THEN 12
        WHEN 'biennial' THEN 24
        WHEN 'triennial' THEN 36
        ELSE 1
    END;

    v_amount := v_contract.monthly_rent * v_multiplier;
    v_payment_day := v_contract.calc_payment_day;

    -- 4. 產生付款記錄
    FOR i IN 0..(p_periods - 1) LOOP
        -- 計算期間起始日（根據繳費週期）
        v_period_start := v_contract.start_date + (i * v_multiplier * INTERVAL '1 month');
        v_period_end := v_period_start + (v_multiplier * INTERVAL '1 month') - INTERVAL '1 day';

        -- 確保不超過合約結束日
        IF v_period_start > v_contract.end_date THEN
            EXIT;
        END IF;

        -- 計算 payment_period（YYYY-MM 格式）
        v_payment_period := TO_CHAR(v_period_start, 'YYYY-MM');

        -- 計算到期日
        v_due_date := MAKE_DATE(
            EXTRACT(YEAR FROM v_period_start)::INT,
            EXTRACT(MONTH FROM v_period_start)::INT,
            LEAST(v_payment_day, EXTRACT(DAY FROM (DATE_TRUNC('month', v_period_start) + INTERVAL '1 month - 1 day'))::INT)
        );

        -- 檢查是否已存在
        SELECT COUNT(*) INTO v_existing_count
        FROM payments
        WHERE contract_id = p_contract_id
          AND payment_period = v_payment_period
          AND payment_type = 'rent';

        IF v_existing_count > 0 THEN
            v_skipped_count := v_skipped_count + 1;
            CONTINUE;
        END IF;

        -- 建立付款記錄
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
            p_contract_id,
            v_contract.customer_id,
            v_contract.branch_id,
            'rent',
            v_payment_period,
            v_amount,
            v_due_date,
            'pending',
            v_period_end
        );

        v_created_count := v_created_count + 1;
        v_total_amount := v_total_amount + v_amount;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'contract_id', p_contract_id,
        'contract_number', v_contract.contract_number,
        'created_count', v_created_count,
        'skipped_existing', v_skipped_count,
        'total_amount', v_total_amount,
        'message', format('已產生 %s 筆付款記錄，總金額 $%s', v_created_count, v_total_amount)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_renewal_payments IS '為續約合約產生付款記錄（首期或多期）';

-- 授權
GRANT EXECUTE ON FUNCTION generate_renewal_payments TO anon, authenticated;

-- ============================================================================
-- 為現有續約草稿補建付款記錄
-- ============================================================================

DO $$
DECLARE
    v_draft RECORD;
    v_result JSONB;
BEGIN
    FOR v_draft IN
        SELECT id, contract_number
        FROM contracts
        WHERE status = 'renewal_draft'
          AND NOT EXISTS (
              SELECT 1 FROM payments p WHERE p.contract_id = contracts.id
          )
    LOOP
        SELECT generate_renewal_payments(v_draft.id) INTO v_result;
        RAISE NOTICE '合約 % (ID %): %', v_draft.contract_number, v_draft.id, v_result->>'message';
    END LOOP;
END $$;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 083 完成 ===';
    RAISE NOTICE '✅ 新增 generate_renewal_payments 函數';
    RAISE NOTICE '說明：建立續約草稿後呼叫此函數產生付款記錄';
    RAISE NOTICE '用法：SELECT generate_renewal_payments(contract_id, periods)';
END $$;
