-- ============================================================================
-- Migration 043: 保護 contracts 關鍵欄位
--
-- 目的：防止前端/PostgREST 直接修改 status 和 renewed_from_id
-- 策略：Trigger 檢查 session variable，只允許從 PostgreSQL Function 修改
--
-- 被保護的欄位：
-- - status（合約狀態）
-- - renewed_from_id（續約關聯）
--
-- 不保護的欄位（舊前端仍可直接修改）：
-- - renewal_*_at（Checklist 時間戳）
-- - renewal_notes、renewal_status 等
-- ============================================================================

-- ============================================================================
-- 1. 建立保護 Trigger Function
-- ============================================================================

CREATE OR REPLACE FUNCTION protect_contract_critical_fields()
RETURNS TRIGGER AS $$
BEGIN
    -- 檢查是否從 RPC（PostgreSQL Function）呼叫
    -- 如果 app.from_rpc 有值，表示是正規路徑，放行
    IF current_setting('app.from_rpc', true) IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- 檢查 status 是否被修改
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        RAISE EXCEPTION '禁止直接修改合約狀態。請使用續約/解約專用 API。(目前: % → 嘗試改為: %)',
            OLD.status, NEW.status
            USING ERRCODE = 'P0001';  -- 自定義錯誤碼
    END IF;

    -- 檢查 renewed_from_id 是否被修改
    IF OLD.renewed_from_id IS DISTINCT FROM NEW.renewed_from_id THEN
        RAISE EXCEPTION '禁止直接修改續約關聯。請使用續約專用 API。'
            USING ERRCODE = 'P0001';
    END IF;

    -- 其他欄位允許修改
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION protect_contract_critical_fields IS
'保護 contracts 表的關鍵欄位（status, renewed_from_id），只允許從 PostgreSQL Function 修改';


-- ============================================================================
-- 2. 建立 Trigger
-- ============================================================================

-- 先移除舊的 Trigger（如果存在）
DROP TRIGGER IF EXISTS tr_protect_contract_critical_fields ON contracts;

-- 建立新 Trigger
CREATE TRIGGER tr_protect_contract_critical_fields
    BEFORE UPDATE ON contracts
    FOR EACH ROW
    EXECUTE FUNCTION protect_contract_critical_fields();

COMMENT ON TRIGGER tr_protect_contract_critical_fields ON contracts IS
'保護關鍵欄位，防止直接 PATCH 繞過業務邏輯';


-- ============================================================================
-- 3. 修改現有 PostgreSQL Functions，加入 set_config 放行
-- ============================================================================

-- 3.1 activate_renewal（續約啟用）
CREATE OR REPLACE FUNCTION activate_renewal(
    p_new_contract_id INT,
    p_operator TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_new_contract RECORD;
    v_old_contract RECORD;
    v_operation RECORD;
BEGIN
    -- ★ 設置 flag，讓 Trigger 放行
    PERFORM set_config('app.from_rpc', 'true', true);

    -- 1. 取得新合約（必須是 renewal_draft）
    SELECT * INTO v_new_contract
    FROM contracts
    WHERE id = p_new_contract_id;

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

    -- 2. 取得舊合約
    SELECT * INTO v_old_contract
    FROM contracts
    WHERE id = v_new_contract.renewed_from_id;

    IF v_old_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('找不到舊合約 ID: %s', v_new_contract.renewed_from_id),
            'code', 'OLD_CONTRACT_NOT_FOUND'
        );
    END IF;

    IF v_old_contract.status NOT IN ('active', 'expired') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('舊合約狀態必須是 active 或 expired，目前是 %s', v_old_contract.status),
            'code', 'INVALID_OLD_STATUS'
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


-- 3.2 cancel_renewal_draft（取消續約草稿）
CREATE OR REPLACE FUNCTION cancel_renewal_draft(
    p_new_contract_id INT,
    p_reason TEXT DEFAULT NULL,
    p_operator TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_contract RECORD;
BEGIN
    -- ★ 設置 flag，讓 Trigger 放行
    PERFORM set_config('app.from_rpc', 'true', true);

    -- 1. 取得合約
    SELECT * INTO v_contract
    FROM contracts
    WHERE id = p_new_contract_id;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('找不到合約 ID: %s', p_new_contract_id),
            'code', 'CONTRACT_NOT_FOUND'
        );
    END IF;

    IF v_contract.status != 'renewal_draft' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('只能取消 renewal_draft 狀態的合約，目前是 %s', v_contract.status),
            'code', 'INVALID_STATUS'
        );
    END IF;

    -- 2. 刪除草稿合約（或標記為 cancelled）
    UPDATE contracts
    SET status = 'cancelled',
        notes = COALESCE(notes, '') || E'\n[取消] ' || COALESCE(p_reason, '無原因') || ' by ' || COALESCE(p_operator, 'system'),
        updated_at = NOW()
    WHERE id = p_new_contract_id;

    -- 3. 更新 renewal_operations
    UPDATE renewal_operations
    SET status = 'cancelled',
        cancelled_at = NOW(),
        cancelled_by = p_operator,
        cancel_reason = p_reason
    WHERE new_contract_id = p_new_contract_id
      AND status = 'draft';

    RETURN jsonb_build_object(
        'success', true,
        'contract_id', p_new_contract_id,
        'message', '續約草稿已取消'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', 'UNEXPECTED_ERROR'
    );
END;
$$ LANGUAGE plpgsql;


-- 3.3 更新解約相關 Functions（已有的 040_termination_v2.sql）
-- create_termination_case_atomic
CREATE OR REPLACE FUNCTION create_termination_case_atomic(
    p_contract_id INT,
    p_termination_type TEXT DEFAULT 'not_renewing',
    p_notice_date DATE DEFAULT NULL,
    p_expected_end_date DATE DEFAULT NULL,
    p_notes TEXT DEFAULT NULL,
    p_created_by TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_contract RECORD;
    v_existing RECORD;
    v_case_id INT;
    v_daily_rate NUMERIC;
    v_deposit NUMERIC;
BEGIN
    -- ★ 設置 flag，讓 Trigger 放行
    PERFORM set_config('app.from_rpc', 'true', true);

    -- 1. 取得合約資訊
    SELECT id, contract_number, end_date, monthly_rent, deposit, status
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

    IF v_contract.status != 'active' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('合約狀態必須是 active，目前是 %s', v_contract.status),
            'code', 'INVALID_CONTRACT_STATUS'
        );
    END IF;

    -- 2. 檢查是否已有進行中的解約案件
    SELECT id INTO v_existing
    FROM termination_cases
    WHERE contract_id = p_contract_id
      AND status NOT IN ('completed', 'cancelled');

    IF v_existing IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('合約已有進行中的解約案件 (ID: %s)', v_existing.id),
            'code', 'CASE_ALREADY_EXISTS'
        );
    END IF;

    -- 3. 計算日租金和押金
    v_daily_rate := ROUND(COALESCE(v_contract.monthly_rent, 0) / 30, 2);
    v_deposit := COALESCE(v_contract.deposit, 0);

    -- ★ 以下操作在同一 Transaction 內 ★

    -- 4. 建立解約案件
    INSERT INTO termination_cases (
        contract_id,
        termination_type,
        status,
        notice_date,
        expected_end_date,
        deposit_amount,
        daily_rate,
        notes,
        created_by,
        created_at
    ) VALUES (
        p_contract_id,
        p_termination_type,
        'notice_received',
        COALESCE(p_notice_date, CURRENT_DATE),
        COALESCE(p_expected_end_date, v_contract.end_date),
        v_deposit,
        v_daily_rate,
        p_notes,
        p_created_by,
        NOW()
    )
    RETURNING id INTO v_case_id;

    -- 5. 更新合約狀態
    UPDATE contracts
    SET status = 'pending_termination',
        updated_at = NOW()
    WHERE id = p_contract_id;

    RETURN jsonb_build_object(
        'success', true,
        'case_id', v_case_id,
        'contract_id', p_contract_id,
        'contract_number', v_contract.contract_number,
        'termination_type', p_termination_type,
        'status', 'notice_received',
        'deposit_amount', v_deposit,
        'daily_rate', v_daily_rate,
        'message', format('解約案件已建立，合約 %s 狀態已更新為「解約中」', v_contract.contract_number)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', 'UNEXPECTED_ERROR'
    );
END;
$$ LANGUAGE plpgsql;


-- 3.4 complete_termination_atomic
CREATE OR REPLACE FUNCTION complete_termination_atomic(
    p_case_id INT,
    p_refund_method TEXT,
    p_refund_account TEXT DEFAULT NULL,
    p_refund_receipt TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_case RECORD;
    v_cancelled_payments INT;
BEGIN
    -- ★ 設置 flag，讓 Trigger 放行
    PERFORM set_config('app.from_rpc', 'true', true);

    -- 1. 取得解約案件
    SELECT tc.*, c.contract_number, c.id as contract_id
    INTO v_case
    FROM termination_cases tc
    JOIN contracts c ON tc.contract_id = c.id
    WHERE tc.id = p_case_id;

    IF v_case IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('找不到解約案件 ID: %s', p_case_id),
            'code', 'CASE_NOT_FOUND'
        );
    END IF;

    IF v_case.status IN ('completed', 'cancelled') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('案件狀態已是 %s，無法完成', v_case.status),
            'code', 'INVALID_STATUS'
        );
    END IF;

    IF v_case.refund_amount IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '請先執行押金結算 (calculate_deposit_settlement)',
            'code', 'SETTLEMENT_NOT_DONE'
        );
    END IF;

    -- ★ 以下操作在同一 Transaction 內 ★

    -- 2. 更新解約案件狀態
    UPDATE termination_cases
    SET status = 'completed',
        refund_method = p_refund_method,
        refund_account = p_refund_account,
        refund_receipt = p_refund_receipt,
        refund_date = CURRENT_DATE,
        notes = CASE
            WHEN p_notes IS NOT NULL THEN COALESCE(notes, '') || E'\n退款備註: ' || p_notes
            ELSE notes
        END,
        checklist = jsonb_set(COALESCE(checklist, '{}'::jsonb), '{refund_processed}', 'true'),
        updated_at = NOW()
    WHERE id = p_case_id;

    -- 3. 更新合約狀態為已終止
    UPDATE contracts
    SET status = 'terminated',
        updated_at = NOW()
    WHERE id = v_case.contract_id;

    -- 4. 取消所有待繳款項
    UPDATE payments
    SET status = 'cancelled',
        notes = COALESCE(notes, '') || E'\n因解約取消',
        updated_at = NOW()
    WHERE contract_id = v_case.contract_id
      AND status = 'pending';

    GET DIAGNOSTICS v_cancelled_payments = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'case_id', p_case_id,
        'contract_id', v_case.contract_id,
        'contract_number', v_case.contract_number,
        'refund_amount', v_case.refund_amount,
        'refund_method', p_refund_method,
        'cancelled_payments', v_cancelled_payments,
        'message', format('解約完成！已退還押金 $%s，取消 %s 筆待繳款項', v_case.refund_amount, v_cancelled_payments)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', 'UNEXPECTED_ERROR'
    );
END;
$$ LANGUAGE plpgsql;


-- 3.5 cancel_termination_case_atomic
CREATE OR REPLACE FUNCTION cancel_termination_case_atomic(
    p_case_id INT,
    p_reason TEXT
) RETURNS JSONB AS $$
DECLARE
    v_case RECORD;
BEGIN
    -- ★ 設置 flag，讓 Trigger 放行
    PERFORM set_config('app.from_rpc', 'true', true);

    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '請提供取消原因',
            'code', 'REASON_REQUIRED'
        );
    END IF;

    -- 1. 取得解約案件
    SELECT tc.*, c.contract_number
    INTO v_case
    FROM termination_cases tc
    JOIN contracts c ON tc.contract_id = c.id
    WHERE tc.id = p_case_id;

    IF v_case IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('找不到解約案件 ID: %s', p_case_id),
            'code', 'CASE_NOT_FOUND'
        );
    END IF;

    IF v_case.status IN ('completed', 'cancelled') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('無法取消狀態為「%s」的案件', v_case.status),
            'code', 'INVALID_STATUS'
        );
    END IF;

    -- ★ 以下操作在同一 Transaction 內 ★

    -- 2. 更新解約案件狀態
    UPDATE termination_cases
    SET status = 'cancelled',
        cancelled_at = NOW(),
        cancel_reason = TRIM(p_reason),
        updated_at = NOW()
    WHERE id = p_case_id;

    -- 3. 恢復合約狀態為 active
    UPDATE contracts
    SET status = 'active',
        updated_at = NOW()
    WHERE id = v_case.contract_id;

    RETURN jsonb_build_object(
        'success', true,
        'case_id', p_case_id,
        'contract_id', v_case.contract_id,
        'contract_number', v_case.contract_number,
        'message', '解約案件已取消，合約狀態已恢復為「生效中」'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', 'UNEXPECTED_ERROR'
    );
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 4. 授權
-- ============================================================================

GRANT EXECUTE ON FUNCTION protect_contract_critical_fields TO anon, authenticated;
GRANT EXECUTE ON FUNCTION activate_renewal TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cancel_renewal_draft TO anon, authenticated;


-- ============================================================================
-- 5. 驗證
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 043 完成 ===';
    RAISE NOTICE '已建立 Trigger: tr_protect_contract_critical_fields';
    RAISE NOTICE '被保護的欄位: status, renewed_from_id';
    RAISE NOTICE '放行機制: set_config(app.from_rpc, true, true)';
    RAISE NOTICE '';
    RAISE NOTICE '測試方式:';
    RAISE NOTICE '  1. 直接 PATCH contracts.status → 應該失敗';
    RAISE NOTICE '  2. 呼叫 activate_renewal() → 應該成功';
END $$;

SELECT 'Migration 043 completed: Contract status protection' AS status;
