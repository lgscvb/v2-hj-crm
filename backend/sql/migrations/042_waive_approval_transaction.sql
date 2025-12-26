-- ============================================================================
-- Migration 042: 免收核准 Transaction 保護
--
-- 目的：確保免收核准的多表操作原子性
--
-- 問題（來自 PRD-v2.5）：
-- 1. billing_approve_waive 先更新 payments.payment_status = 'waived'
-- 2. 再更新 waive_requests.status = 'approved'
-- 3. Timeout 在中間會造成：付款已免收但申請仍顯示 pending
-- 4. 主管可能再次點擊核准，但付款已處理
--
-- 解法：使用 PostgreSQL Function 封裝，確保 Transaction
-- ============================================================================

-- ============================================================================
-- 1. PostgreSQL Function: approve_waive_request
-- 核准免收申請（原子性操作）
-- ============================================================================

CREATE OR REPLACE FUNCTION approve_waive_request(
    p_request_id INT,
    p_approved_by TEXT
) RETURNS JSONB AS $$
DECLARE
    v_request RECORD;
    v_payment RECORD;
BEGIN
    -- 1. 取得申請
    SELECT *
    INTO v_request
    FROM waive_requests
    WHERE id = p_request_id;

    IF v_request IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '找不到免收申請',
            'code', 'NOT_FOUND'
        );
    END IF;

    -- 2. 驗證申請狀態
    IF v_request.status != 'pending' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('申請狀態為 %s，無法核准', v_request.status),
            'code', 'INVALID_STATUS'
        );
    END IF;

    -- 3. 取得付款記錄
    SELECT *
    INTO v_payment
    FROM payments
    WHERE id = v_request.payment_id;

    IF v_payment IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '找不到關聯的付款記錄',
            'code', 'PAYMENT_NOT_FOUND'
        );
    END IF;

    -- 4. 檢查付款狀態
    IF v_payment.payment_status NOT IN ('pending', 'overdue') THEN
        -- 自動駁回申請
        UPDATE waive_requests
        SET status = 'rejected',
            reject_reason = '款項狀態已變更',
            updated_at = NOW()
        WHERE id = p_request_id;

        RETURN jsonb_build_object(
            'success', false,
            'error', '款項狀態已變更，無法核准',
            'code', 'STATUS_CHANGED',
            'http_status', 409,
            'request_status', 'rejected',
            'current_payment_status', v_payment.payment_status
        );
    END IF;

    -- ★ 以下操作在同一 Transaction 內 ★

    -- 5. 更新付款狀態為 waived
    UPDATE payments
    SET payment_status = 'waived',
        notes = COALESCE(notes, '') || E'\n[免收] 核准人: ' || p_approved_by || ', 原因: ' || COALESCE(v_request.request_reason, ''),
        updated_at = NOW()
    WHERE id = v_request.payment_id;

    -- 6. 更新申請狀態為 approved
    UPDATE waive_requests
    SET status = 'approved',
        approved_by = p_approved_by,
        approved_at = NOW(),
        updated_at = NOW()
    WHERE id = p_request_id;

    RETURN jsonb_build_object(
        'success', true,
        'request_id', p_request_id,
        'payment_id', v_request.payment_id,
        'approved_by', p_approved_by,
        'message', '免收已核准'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', 'UNEXPECTED_ERROR'
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION approve_waive_request IS '核准免收申請（原子性操作）- 同時更新 payments 和 waive_requests';


-- ============================================================================
-- 2. PostgreSQL Function: reject_waive_request
-- 駁回免收申請（原子性操作）
-- ============================================================================

CREATE OR REPLACE FUNCTION reject_waive_request(
    p_request_id INT,
    p_rejected_by TEXT,
    p_reject_reason TEXT
) RETURNS JSONB AS $$
DECLARE
    v_request RECORD;
BEGIN
    IF p_reject_reason IS NULL OR TRIM(p_reject_reason) = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '必須提供駁回原因',
            'code', 'REASON_REQUIRED'
        );
    END IF;

    -- 取得申請
    SELECT *
    INTO v_request
    FROM waive_requests
    WHERE id = p_request_id;

    IF v_request IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', '找不到免收申請',
            'code', 'NOT_FOUND'
        );
    END IF;

    IF v_request.status != 'pending' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('申請狀態為 %s，無法駁回', v_request.status),
            'code', 'INVALID_STATUS'
        );
    END IF;

    -- 更新申請狀態
    UPDATE waive_requests
    SET status = 'rejected',
        rejected_by = p_rejected_by,
        reject_reason = TRIM(p_reject_reason),
        rejected_at = NOW(),
        updated_at = NOW()
    WHERE id = p_request_id;

    RETURN jsonb_build_object(
        'success', true,
        'request_id', p_request_id,
        'rejected_by', p_rejected_by,
        'message', '免收申請已駁回'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'code', 'UNEXPECTED_ERROR'
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION reject_waive_request IS '駁回免收申請';


-- ============================================================================
-- 3. 授權
-- ============================================================================

GRANT EXECUTE ON FUNCTION approve_waive_request TO anon, authenticated;
GRANT EXECUTE ON FUNCTION reject_waive_request TO anon, authenticated;


-- ============================================================================
-- 完成
-- ============================================================================

SELECT 'Migration 042 completed: Waive approval Transaction protection' AS status;
