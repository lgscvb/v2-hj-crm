-- ============================================================================
-- Migration 041: 發票開立冪等性保護
--
-- 目的：防止因 Timeout 造成的重複開票問題
--
-- 問題：
-- 1. 呼叫光貿 API 開票成功
-- 2. 網路 Timeout，回應未返回
-- 3. 本地 payments.invoice_number 未更新
-- 4. 用戶再次點擊開票 → 重複發票！
--
-- 解法：
-- 1. 開票前先建立 invoice_operations 記錄
-- 2. 記錄 order_id（光貿訂單編號，唯一）
-- 3. API 成功後更新記錄
-- 4. 重試時先檢查是否有已完成的操作
-- ============================================================================

-- ============================================================================
-- 1. 發票操作記錄表
-- ============================================================================

CREATE TABLE IF NOT EXISTS invoice_operations (
    id                  SERIAL PRIMARY KEY,
    payment_id          INT NOT NULL REFERENCES payments(id),
    order_id            VARCHAR(64) UNIQUE NOT NULL,  -- 光貿訂單編號（唯一）
    operation_type      VARCHAR(20) NOT NULL DEFAULT 'create'
                        CHECK (operation_type IN ('create', 'void', 'allowance')),
    status              VARCHAR(20) NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'sent', 'completed', 'failed')),
    invoice_number      VARCHAR(20),                  -- 開票成功後記錄
    api_request         JSONB,                        -- API 請求內容（除錯用）
    api_response        JSONB,                        -- API 回應內容
    error_message       TEXT,                         -- 錯誤訊息
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    sent_at             TIMESTAMPTZ,                  -- API 發送時間
    completed_at        TIMESTAMPTZ,                  -- 完成時間
    created_by          TEXT
);

CREATE INDEX idx_invoice_operations_payment_id ON invoice_operations(payment_id);
CREATE INDEX idx_invoice_operations_order_id ON invoice_operations(order_id);
CREATE INDEX idx_invoice_operations_status ON invoice_operations(status);

COMMENT ON TABLE invoice_operations IS '發票操作記錄（冪等性保護）';
COMMENT ON COLUMN invoice_operations.order_id IS '光貿訂單編號，確保不重複';
COMMENT ON COLUMN invoice_operations.status IS 'pending=待發送, sent=已發送等待回應, completed=已完成, failed=失敗';


-- ============================================================================
-- 2. PostgreSQL Function: check_invoice_operation
-- 檢查是否有已完成的發票操作
-- ============================================================================

CREATE OR REPLACE FUNCTION check_invoice_operation(
    p_payment_id INT,
    p_operation_type TEXT DEFAULT 'create'
) RETURNS JSONB AS $$
DECLARE
    v_operation RECORD;
BEGIN
    -- 尋找已完成或進行中的操作
    SELECT *
    INTO v_operation
    FROM invoice_operations
    WHERE payment_id = p_payment_id
      AND operation_type = p_operation_type
      AND status IN ('sent', 'completed')
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_operation IS NULL THEN
        RETURN jsonb_build_object(
            'has_operation', false
        );
    END IF;

    IF v_operation.status = 'completed' THEN
        RETURN jsonb_build_object(
            'has_operation', true,
            'operation_id', v_operation.id,
            'status', v_operation.status,
            'invoice_number', v_operation.invoice_number,
            'completed_at', v_operation.completed_at,
            'message', '此付款已有完成的發票操作'
        );
    ELSE
        -- status = 'sent'，操作進行中
        RETURN jsonb_build_object(
            'has_operation', true,
            'operation_id', v_operation.id,
            'status', v_operation.status,
            'sent_at', v_operation.sent_at,
            'message', '發票操作進行中，請稍候'
        );
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION check_invoice_operation IS '檢查是否有已完成或進行中的發票操作';


-- ============================================================================
-- 3. PostgreSQL Function: create_invoice_operation
-- 建立發票操作記錄（開票前呼叫）
-- ============================================================================

CREATE OR REPLACE FUNCTION create_invoice_operation(
    p_payment_id INT,
    p_order_id TEXT,
    p_operation_type TEXT DEFAULT 'create',
    p_api_request JSONB DEFAULT NULL,
    p_created_by TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_operation_id INT;
    v_existing RECORD;
BEGIN
    -- 1. 檢查是否有進行中或已完成的操作
    SELECT *
    INTO v_existing
    FROM invoice_operations
    WHERE payment_id = p_payment_id
      AND operation_type = p_operation_type
      AND status IN ('sent', 'completed')
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_existing IS NOT NULL THEN
        IF v_existing.status = 'completed' THEN
            RETURN jsonb_build_object(
                'success', false,
                'code', 'ALREADY_COMPLETED',
                'invoice_number', v_existing.invoice_number,
                'message', format('此付款已開立發票: %s', v_existing.invoice_number)
            );
        ELSE
            RETURN jsonb_build_object(
                'success', false,
                'code', 'IN_PROGRESS',
                'operation_id', v_existing.id,
                'message', '發票操作進行中，請稍候重試'
            );
        END IF;
    END IF;

    -- 2. 建立新操作記錄
    INSERT INTO invoice_operations (
        payment_id,
        order_id,
        operation_type,
        status,
        api_request,
        created_by
    ) VALUES (
        p_payment_id,
        p_order_id,
        p_operation_type,
        'pending',
        p_api_request,
        p_created_by
    )
    RETURNING id INTO v_operation_id;

    RETURN jsonb_build_object(
        'success', true,
        'operation_id', v_operation_id,
        'order_id', p_order_id,
        'message', '操作記錄已建立'
    );

EXCEPTION WHEN unique_violation THEN
    -- order_id 重複，可能是同一請求的重試
    SELECT *
    INTO v_existing
    FROM invoice_operations
    WHERE order_id = p_order_id;

    IF v_existing.status = 'completed' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ALREADY_COMPLETED',
            'invoice_number', v_existing.invoice_number,
            'message', format('此訂單已開立發票: %s', v_existing.invoice_number)
        );
    ELSE
        RETURN jsonb_build_object(
            'success', true,
            'operation_id', v_existing.id,
            'order_id', p_order_id,
            'already_exists', true,
            'message', '使用已存在的操作記錄'
        );
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION create_invoice_operation IS '建立發票操作記錄（冪等性保護）';


-- ============================================================================
-- 4. PostgreSQL Function: update_invoice_operation_sent
-- 標記操作為「已發送」（呼叫 API 前）
-- ============================================================================

CREATE OR REPLACE FUNCTION update_invoice_operation_sent(
    p_operation_id INT
) RETURNS JSONB AS $$
BEGIN
    UPDATE invoice_operations
    SET status = 'sent',
        sent_at = NOW()
    WHERE id = p_operation_id AND status = 'pending';

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', '找不到待發送的操作記錄'
        );
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'operation_id', p_operation_id
    );
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 5. PostgreSQL Function: complete_invoice_operation
-- 完成發票操作（API 成功後呼叫）
-- ============================================================================

CREATE OR REPLACE FUNCTION complete_invoice_operation(
    p_operation_id INT,
    p_invoice_number TEXT,
    p_api_response JSONB DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    v_operation RECORD;
BEGIN
    -- 取得操作記錄
    SELECT *
    INTO v_operation
    FROM invoice_operations
    WHERE id = p_operation_id;

    IF v_operation IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', '找不到操作記錄'
        );
    END IF;

    -- ★ Transaction 內同時更新 ★

    -- 1. 更新操作記錄
    UPDATE invoice_operations
    SET status = 'completed',
        invoice_number = p_invoice_number,
        api_response = p_api_response,
        completed_at = NOW()
    WHERE id = p_operation_id;

    -- 2. 更新 payments 表
    UPDATE payments
    SET invoice_number = p_invoice_number,
        invoice_date = CURRENT_DATE,
        invoice_status = 'issued',
        updated_at = NOW()
    WHERE id = v_operation.payment_id;

    RETURN jsonb_build_object(
        'success', true,
        'operation_id', p_operation_id,
        'payment_id', v_operation.payment_id,
        'invoice_number', p_invoice_number,
        'message', '發票開立完成'
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION complete_invoice_operation IS '完成發票操作（Transaction 保護）';


-- ============================================================================
-- 6. PostgreSQL Function: fail_invoice_operation
-- 標記發票操作失敗
-- ============================================================================

CREATE OR REPLACE FUNCTION fail_invoice_operation(
    p_operation_id INT,
    p_error_message TEXT,
    p_api_response JSONB DEFAULT NULL
) RETURNS JSONB AS $$
BEGIN
    UPDATE invoice_operations
    SET status = 'failed',
        error_message = p_error_message,
        api_response = p_api_response,
        completed_at = NOW()
    WHERE id = p_operation_id;

    RETURN jsonb_build_object(
        'success', true,
        'operation_id', p_operation_id,
        'message', '已記錄失敗'
    );
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- 7. 授權
-- ============================================================================

GRANT SELECT, INSERT, UPDATE ON invoice_operations TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE invoice_operations_id_seq TO anon, authenticated;
GRANT EXECUTE ON FUNCTION check_invoice_operation TO anon, authenticated;
GRANT EXECUTE ON FUNCTION create_invoice_operation TO anon, authenticated;
GRANT EXECUTE ON FUNCTION update_invoice_operation_sent TO anon, authenticated;
GRANT EXECUTE ON FUNCTION complete_invoice_operation TO anon, authenticated;
GRANT EXECUTE ON FUNCTION fail_invoice_operation TO anon, authenticated;


-- ============================================================================
-- 完成
-- ============================================================================

SELECT 'Migration 041 completed: Invoice idempotency protection' AS status;
