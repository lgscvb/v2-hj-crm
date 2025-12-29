-- 068_quick_terminate_contract.sql
-- 快速終止合約功能（繞過解約流程）
-- Date: 2025-12-29

-- ============================================================================
-- 1. 建立快速終止合約函數
-- ============================================================================

CREATE OR REPLACE FUNCTION quick_terminate_contract(
    p_contract_id INT,
    p_reason TEXT DEFAULT NULL,
    p_operator TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_contract RECORD;
    v_cancelled_payments INT;
BEGIN
    -- ★ 設置 flag，讓 Trigger 放行
    PERFORM set_config('app.from_rpc', 'true', true);

    -- 1. 取得合約
    SELECT id, contract_number, status, customer_id
    INTO v_contract
    FROM contracts
    WHERE id = p_contract_id;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('找不到合約 ID: %s', p_contract_id),
            'code', 'CONTRACT_NOT_FOUND'
        );
    END IF;

    -- 2. 檢查狀態（允許 active, pending, pending_sign）
    IF v_contract.status NOT IN ('active', 'pending', 'pending_sign', 'expired') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('無法終止狀態為「%s」的合約', v_contract.status),
            'code', 'INVALID_STATUS'
        );
    END IF;

    -- ★ 以下操作在同一 Transaction 內 ★

    -- 3. 更新合約狀態為已終止
    UPDATE contracts
    SET status = 'terminated',
        notes = CASE
            WHEN p_reason IS NOT NULL AND TRIM(p_reason) != ''
            THEN COALESCE(notes, '') || E'\n[快速終止] ' || NOW()::DATE || ' - ' || TRIM(p_reason) || ' (by ' || COALESCE(p_operator, 'system') || ')'
            ELSE COALESCE(notes, '') || E'\n[快速終止] ' || NOW()::DATE || ' (by ' || COALESCE(p_operator, 'system') || ')'
        END,
        updated_at = NOW()
    WHERE id = p_contract_id;

    -- 4. 取消所有待繳款項
    UPDATE payments
    SET status = 'cancelled',
        notes = COALESCE(notes, '') || E'\n因快速終止合約而取消',
        updated_at = NOW()
    WHERE contract_id = p_contract_id
      AND status = 'pending';

    GET DIAGNOSTICS v_cancelled_payments = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'contract_id', p_contract_id,
        'contract_number', v_contract.contract_number,
        'cancelled_payments', v_cancelled_payments,
        'message', format('合約 %s 已終止，取消 %s 筆待繳款項', v_contract.contract_number, v_cancelled_payments)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', 'UNEXPECTED_ERROR'
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION quick_terminate_contract IS '快速終止合約（適用於測試資料或不需要押金處理的情況）';

-- 授權
GRANT EXECUTE ON FUNCTION quick_terminate_contract TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 068 完成 ===';
    RAISE NOTICE '✅ quick_terminate_contract 函數已建立';
    RAISE NOTICE '用法: SELECT quick_terminate_contract(contract_id, reason, operator)';
END $$;
