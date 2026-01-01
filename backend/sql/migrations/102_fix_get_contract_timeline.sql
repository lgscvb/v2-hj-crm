-- ============================================================================
-- Migration 102: 修復 get_contract_timeline 函數
--
-- 問題：
-- - Migration 100 將 v_contract_workspace 的 first_invoice_status 改為
--   first_invoice_number + first_invoice_date
-- - 但 get_contract_timeline 函數仍在讀取 first_invoice_status 欄位
-- - 導致 API 錯誤: "record \"v_workspace\" has no field \"first_invoice_status\""
--
-- 修復：
-- - 更新函數移除 first_invoice_status 引用
-- - 改用 first_invoice_number 判斷發票狀態
--
-- Date: 2026-01-01
-- ============================================================================

-- ============================================================================
-- 1. 重建 get_contract_timeline 函數
-- ============================================================================

CREATE OR REPLACE FUNCTION get_contract_timeline(p_contract_id INT)
RETURNS JSONB AS $$
DECLARE
    v_workspace RECORD;
    v_timeline JSONB;
    v_decision JSONB;
BEGIN
    -- 取得 workspace 資料
    SELECT * INTO v_workspace
    FROM v_contract_workspace
    WHERE id = p_contract_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '找不到合約');
    END IF;

    -- 組裝 timeline
    v_timeline := jsonb_build_array(
        jsonb_build_object(
            'key', 'intent',
            'label', '續約意願',
            'status', v_workspace.timeline_intent_status,
            'notified_at', v_workspace.renewal_notified_at,
            'confirmed_at', v_workspace.renewal_confirmed_at
        ),
        jsonb_build_object(
            'key', 'signing',
            'label', '文件回簽',
            'status', v_workspace.timeline_signing_status,
            'next_contract_id', v_workspace.next_contract_id,
            'next_signed_at', v_workspace.next_signed_at,
            'days_pending', v_workspace.days_pending_sign
        ),
        jsonb_build_object(
            'key', 'payment',
            'label', '首期收款',
            'status', v_workspace.timeline_payment_status,
            'payment_id', v_workspace.first_payment_id,
            'payment_status', v_workspace.first_payment_status,
            'paid_at', v_workspace.first_payment_paid_at
        ),
        jsonb_build_object(
            'key', 'invoice',
            'label', '首期發票',
            'status', v_workspace.timeline_invoice_status,
            -- ★ 102 修正：移除 first_invoice_status，改用 invoice_number 判斷
            'invoice_number', v_workspace.first_invoice_number,
            'invoice_date', v_workspace.first_invoice_date
        ),
        jsonb_build_object(
            'key', 'activation',
            'label', '合約啟用',
            'status', v_workspace.timeline_activation_status,
            'next_status', v_workspace.next_status
        )
    );

    -- 組裝 decision
    v_decision := jsonb_build_object(
        'blocked_by', v_workspace.decision_blocked_by,
        'next_action', v_workspace.decision_next_action,
        'owner', v_workspace.decision_owner
    );

    -- 回傳完整結果
    RETURN jsonb_build_object(
        'success', true,
        'contract', jsonb_build_object(
            'id', v_workspace.id,
            'contract_number', v_workspace.contract_number,
            'customer_name', v_workspace.customer_name,
            'company_name', v_workspace.company_name,
            'status', v_workspace.status,
            'start_date', v_workspace.start_date,
            'end_date', v_workspace.end_date,
            'days_until_expiry', v_workspace.days_until_expiry
        ),
        'prev_contract_id', v_workspace.prev_contract_id,
        'next_contract', CASE
            WHEN v_workspace.next_contract_id IS NOT NULL THEN
                jsonb_build_object(
                    'id', v_workspace.next_contract_id,
                    'status', v_workspace.next_status,
                    'signed_at', v_workspace.next_signed_at,
                    'start_date', v_workspace.next_start_date,
                    'end_date', v_workspace.next_end_date
                )
            ELSE NULL
        END,
        'timeline', v_timeline,
        'decision', v_decision
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_contract_timeline IS '取得合約的 Timeline 和 Decision（用於 Workspace）- 修正欄位引用 (102)';

-- ============================================================================
-- 2. 驗證
-- ============================================================================

DO $$
DECLARE
    test_result JSONB;
    test_contract_id INT;
BEGIN
    -- 取得一個可用的合約 ID 進行測試
    SELECT id INTO test_contract_id
    FROM v_contract_workspace
    LIMIT 1;

    IF test_contract_id IS NOT NULL THEN
        test_result := get_contract_timeline(test_contract_id);

        IF test_result->>'success' = 'true' THEN
            RAISE NOTICE '';
            RAISE NOTICE '=== Migration 102 完成 ===';
            RAISE NOTICE '';
            RAISE NOTICE 'get_contract_timeline 函數已修復：';
            RAISE NOTICE '- 移除 first_invoice_status 引用';
            RAISE NOTICE '- 改用 first_invoice_number + first_invoice_date';
            RAISE NOTICE '';
            RAISE NOTICE '驗證測試（合約 %）: 成功', test_contract_id;
        ELSE
            RAISE EXCEPTION '函數測試失敗: %', test_result->>'error';
        END IF;
    ELSE
        RAISE NOTICE '';
        RAISE NOTICE '=== Migration 102 完成 ===';
        RAISE NOTICE '';
        RAISE NOTICE '（無合約可測試，函數已更新）';
    END IF;
END $$;
