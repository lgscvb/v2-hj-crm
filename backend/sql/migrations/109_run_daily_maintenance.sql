-- ============================================================================
-- Migration 109: 建立每日維護函數
--
-- 解決問題：
-- 1. 付款逾期狀態未自動更新 (pending → overdue)
-- 2. 合約到期未自動更新 (active → expired)
-- 3. 當月應收未自動產生
--
-- 使用方式：前端 Dashboard 載入時自動呼叫
-- SELECT * FROM run_daily_maintenance();
--
-- Date: 2026-01-02
-- ============================================================================

-- ============================================================================
-- 1. 建立 auto_expire_contracts() - 自動更新過期合約
-- ============================================================================

CREATE OR REPLACE FUNCTION auto_expire_contracts()
RETURNS TABLE (
    expired_count INTEGER,
    contract_numbers TEXT[]
) AS $$
DECLARE
    v_expired_count INTEGER;
    v_contract_numbers TEXT[];
BEGIN
    -- 更新所有已過期但仍為 active 的合約（排除有續約草稿的）
    WITH expired AS (
        UPDATE contracts c
        SET status = 'expired',
            updated_at = NOW()
        WHERE c.status = 'active'
          AND c.end_date < CURRENT_DATE
          -- 排除有續約草稿/待簽署的合約
          AND NOT EXISTS (
            SELECT 1
            FROM contracts nc
            WHERE nc.renewed_from_id = c.id
              AND nc.status IN ('renewal_draft', 'pending_sign')
          )
        RETURNING c.contract_number
    )
    SELECT COUNT(*)::INTEGER, ARRAY_AGG(contract_number)
    INTO v_expired_count, v_contract_numbers
    FROM expired;

    RETURN QUERY SELECT v_expired_count, COALESCE(v_contract_numbers, ARRAY[]::TEXT[]);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION auto_expire_contracts() IS
'自動將過期合約標記為 expired（排除有續約草稿的）';

-- ============================================================================
-- 2. 建立 run_daily_maintenance() - 統一維護入口
-- ============================================================================

CREATE OR REPLACE FUNCTION run_daily_maintenance()
RETURNS JSONB AS $$
DECLARE
    v_payments_result RECORD;
    v_overdue_result RECORD;
    v_expired_result RECORD;
    v_result JSONB;
BEGIN
    -- 1. 產生當月應收（冪等）
    SELECT * INTO v_payments_result FROM generate_monthly_payments();

    -- 2. 更新逾期狀態
    SELECT * INTO v_overdue_result FROM batch_update_overdue_status();

    -- 3. 更新過期合約
    SELECT * INTO v_expired_result FROM auto_expire_contracts();

    -- 組合結果
    v_result := jsonb_build_object(
        'executed_at', NOW(),
        'payments_generated', jsonb_build_object(
            'count', COALESCE(v_payments_result.payments_created, 0),
            'amount', COALESCE(v_payments_result.total_amount, 0)
        ),
        'overdue_updated', jsonb_build_object(
            'count', COALESCE(v_overdue_result.updated_count, 0),
            'amount', COALESCE(v_overdue_result.total_overdue_amount, 0)
        ),
        'contracts_expired', jsonb_build_object(
            'count', COALESCE(v_expired_result.expired_count, 0),
            'contracts', COALESCE(v_expired_result.contract_numbers, ARRAY[]::TEXT[])
        )
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION run_daily_maintenance() IS
'每日維護函數：產生應收、更新逾期、更新過期合約（冪等，可重複呼叫）';

-- 授權
GRANT EXECUTE ON FUNCTION auto_expire_contracts() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION run_daily_maintenance() TO anon, authenticated;

-- ============================================================================
-- 3. 驗證
-- ============================================================================

DO $$
DECLARE
    v_result JSONB;
BEGIN
    -- 執行一次維護
    SELECT run_daily_maintenance() INTO v_result;

    RAISE NOTICE '=== Migration 109 完成 ===';
    RAISE NOTICE '每日維護函數已建立';
    RAISE NOTICE '首次執行結果: %', v_result;
END $$;
