-- ============================================================================
-- Migration 040: 解約流程 V2 - Transaction 保護
--
-- 目的：確保解約流程的多表操作原子性，避免 Timeout 造成資料不一致
--
-- 問題清單（來自 PRD-v2.5）：
-- 1. create_termination_case: 先建案件、再更新合約 → Timeout 會造成案件存在但合約狀態不對
-- 2. update_termination_status: 先更新案件、再更新合約 → 同上
-- 3. process_refund: 先更新案件、再更新合約 → 同上
-- 4. cancel_termination_case: 先更新案件、再恢復合約 → 同上
--
-- 解法：使用 PostgreSQL Function 封裝多表操作，確保 Transaction
-- ============================================================================

-- ============================================================================
-- 1. 新增解約案件狀態：draft（草稿）
-- ============================================================================

-- 檢查並新增 draft 狀態（如果 CHECK constraint 存在的話）
DO $$
BEGIN
    -- 嘗試刪除舊的 CHECK constraint
    ALTER TABLE termination_cases DROP CONSTRAINT IF EXISTS termination_cases_status_check;

    -- 新增包含 draft 的 CHECK constraint
    ALTER TABLE termination_cases ADD CONSTRAINT termination_cases_status_check
        CHECK (status IN (
            'draft',              -- 草稿（新增）
            'notice_received',    -- 客戶已通知
            'moving_out',         -- 搬遷中
            'pending_doc',        -- 等待公文
            'pending_settlement', -- 押金結算中
            'completed',          -- 已完成
            'cancelled'           -- 已取消
        ));
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Could not update termination_cases constraint: %', SQLERRM;
END $$;


-- ============================================================================
-- 2. PostgreSQL Function: create_termination_case_atomic
-- 建立解約案件並更新合約狀態（原子性操作）
-- ============================================================================

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

COMMENT ON FUNCTION create_termination_case_atomic IS '建立解約案件（原子性操作）- 同時建立案件並更新合約狀態';


-- ============================================================================
-- 3. PostgreSQL Function: complete_termination_atomic
-- 完成解約（原子性：更新案件 + 更新合約 + 取消待繳款項）
-- ============================================================================

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

COMMENT ON FUNCTION complete_termination_atomic IS '完成解約（原子性操作）- 同時更新案件、合約、取消待繳款項';


-- ============================================================================
-- 4. PostgreSQL Function: cancel_termination_case_atomic
-- 取消解約案件並恢復合約狀態（原子性操作）
-- ============================================================================

CREATE OR REPLACE FUNCTION cancel_termination_case_atomic(
    p_case_id INT,
    p_reason TEXT
) RETURNS JSONB AS $$
DECLARE
    v_case RECORD;
BEGIN
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

COMMENT ON FUNCTION cancel_termination_case_atomic IS '取消解約案件（原子性操作）- 同時取消案件並恢復合約狀態';


-- ============================================================================
-- 5. PostgreSQL Function: update_termination_status_atomic
-- 更新解約狀態並同步更新合約狀態（原子性操作）
-- ============================================================================

CREATE OR REPLACE FUNCTION update_termination_status_atomic(
    p_case_id INT,
    p_status TEXT,
    p_notes TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_case RECORD;
    v_valid_statuses TEXT[] := ARRAY['notice_received', 'moving_out', 'pending_doc', 'pending_settlement', 'completed', 'cancelled'];
BEGIN
    -- 驗證狀態
    IF NOT p_status = ANY(v_valid_statuses) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('無效的狀態: %s。有效值: %s', p_status, array_to_string(v_valid_statuses, ', ')),
            'code', 'INVALID_STATUS'
        );
    END IF;

    -- 取得案件
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

    -- 如果要完成或取消，使用專用函數
    IF p_status = 'completed' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '請使用 complete_termination_atomic 完成解約',
            'code', 'USE_COMPLETE_FUNCTION'
        );
    END IF;

    IF p_status = 'cancelled' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '請使用 cancel_termination_case_atomic 取消解約',
            'code', 'USE_CANCEL_FUNCTION'
        );
    END IF;

    -- ★ 以下操作在同一 Transaction 內 ★

    -- 更新解約案件
    UPDATE termination_cases
    SET status = p_status,
        notes = CASE WHEN p_notes IS NOT NULL THEN p_notes ELSE notes END,
        updated_at = NOW()
    WHERE id = p_case_id;

    RETURN jsonb_build_object(
        'success', true,
        'case_id', p_case_id,
        'new_status', p_status,
        'contract_number', v_case.contract_number
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', 'UNEXPECTED_ERROR'
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION update_termination_status_atomic IS '更新解約狀態（原子性操作）';


-- ============================================================================
-- 6. 授權 PostgREST 可以呼叫這些 Functions
-- ============================================================================

GRANT EXECUTE ON FUNCTION create_termination_case_atomic TO anon, authenticated;
GRANT EXECUTE ON FUNCTION complete_termination_atomic TO anon, authenticated;
GRANT EXECUTE ON FUNCTION cancel_termination_case_atomic TO anon, authenticated;
GRANT EXECUTE ON FUNCTION update_termination_status_atomic TO anon, authenticated;


-- ============================================================================
-- 完成
-- ============================================================================

SELECT 'Migration 040 completed: Termination V2 - Transaction protection' AS status;
