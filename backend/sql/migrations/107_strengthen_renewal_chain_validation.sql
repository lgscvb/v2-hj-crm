-- ============================================================================
-- Migration 107: 強化續約鏈驗證（簡化版）
--
-- 目的：防止並發導致的續約鏈不一致
--
-- 修改內容：
-- 1. activate_renewal 加入 FOR UPDATE 鎖定（防止並發）
-- 2. activate_renewal 檢查是否已有其他 active/signed 續約
--
-- 說明：Python 層（renewal_tools_v3.py）已有完整驗證，
--       DB 層只需確保並發安全和最終一致性檢查
--
-- 日期：2026-01-02
-- ============================================================================

CREATE OR REPLACE FUNCTION activate_renewal(
    p_new_contract_id INT,
    p_operator TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_new_contract RECORD;
    v_old_contract RECORD;
    v_other_active RECORD;
BEGIN
    -- ★ 設置 flag，讓 Trigger 放行
    PERFORM set_config('app.from_rpc', 'true', true);

    -- 1. 取得新合約（FOR UPDATE 鎖定，防止並發啟用）
    SELECT * INTO v_new_contract
    FROM contracts
    WHERE id = p_new_contract_id
    FOR UPDATE;

    IF v_new_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('找不到合約 ID: %s', p_new_contract_id),
            'code', 'CONTRACT_NOT_FOUND'
        );
    END IF;

    IF v_new_contract.status != 'renewal_draft' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('合約狀態必須是 renewal_draft，目前是 %s', v_new_contract.status),
            'code', 'INVALID_STATUS'
        );
    END IF;

    IF v_new_contract.renewed_from_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '此合約沒有關聯的舊合約（renewed_from_id 為空）',
            'code', 'NO_OLD_CONTRACT'
        );
    END IF;

    -- 2. 取得舊合約（FOR UPDATE 鎖定）
    SELECT * INTO v_old_contract
    FROM contracts
    WHERE id = v_new_contract.renewed_from_id
    FOR UPDATE;

    IF v_old_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('找不到舊合約 ID: %s', v_new_contract.renewed_from_id),
            'code', 'OLD_CONTRACT_NOT_FOUND'
        );
    END IF;

    -- ★ 檢查舊合約狀態（含 renewed 狀態檢查）
    IF v_old_contract.status = 'renewed' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('舊合約 %s 已完成續約（狀態為 renewed）', v_old_contract.contract_number),
            'code', 'ALREADY_RENEWED'
        );
    END IF;

    IF v_old_contract.status NOT IN ('active', 'expired') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('舊合約狀態必須是 active 或 expired，目前是 %s', v_old_contract.status),
            'code', 'INVALID_OLD_STATUS'
        );
    END IF;

    -- ★ 檢查是否已有其他 active/signed 續約合約（防止重複續約）
    SELECT id, contract_number, status INTO v_other_active
    FROM contracts
    WHERE renewed_from_id = v_new_contract.renewed_from_id
      AND id != p_new_contract_id
      AND status IN ('active', 'signed');

    IF v_other_active IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('舊合約已有其他%s的續約合約 (ID: %s)',
                CASE v_other_active.status WHEN 'active' THEN '生效中' ELSE '已簽署' END,
                v_other_active.id
            ),
            'code', 'DUPLICATE_RENEWAL'
        );
    END IF;

    -- ★ 以下操作在同一 Transaction 內 ★

    -- 3. 更新新合約狀態為 active
    UPDATE contracts
    SET status = 'active',
        updated_at = NOW()
    WHERE id = p_new_contract_id;

    -- 4. 更新舊合約狀態為 renewed
    UPDATE contracts
    SET status = 'renewed',
        updated_at = NOW()
    WHERE id = v_new_contract.renewed_from_id;

    -- 5. 更新 renewal_operations（如果存在）
    UPDATE renewal_operations
    SET status = 'activated',
        activated_at = NOW(),
        activated_by = p_operator
    WHERE new_contract_id = p_new_contract_id
      AND status = 'draft';

    RETURN jsonb_build_object(
        'success', true,
        'new_contract_id', p_new_contract_id,
        'new_contract_number', v_new_contract.contract_number,
        'old_contract_id', v_new_contract.renewed_from_id,
        'old_contract_number', v_old_contract.contract_number,
        'message', format('續約啟用成功！新合約 %s 已生效，舊合約 %s 已標記為已續約',
            v_new_contract.contract_number, v_old_contract.contract_number)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', 'UNEXPECTED_ERROR'
    );
END;
$$ LANGUAGE plpgsql;


-- 授權
GRANT EXECUTE ON FUNCTION activate_renewal TO anon, authenticated;


-- 驗證
DO $$
BEGIN
    RAISE NOTICE '=== Migration 107 完成 ===';
    RAISE NOTICE '強化內容：';
    RAISE NOTICE '  1. FOR UPDATE 鎖定（防止並發啟用）';
    RAISE NOTICE '  2. 檢查舊合約 renewed 狀態';
    RAISE NOTICE '  3. 檢查是否已有其他 active/signed 續約';
END $$;

SELECT 'Migration 107 completed: Strengthen renewal chain validation' AS status;
