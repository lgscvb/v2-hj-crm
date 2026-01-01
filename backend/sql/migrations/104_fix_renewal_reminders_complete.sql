-- ============================================================================
-- Migration 104: 完整修復 v_renewal_reminders + 相關視圖
--
-- 問題：Migration 103 重建 v_renewal_reminders 時遺漏大量欄位：
-- - days_remaining（今日待辦排序）
-- - completion_score（Dashboard 進度）
-- - company_name（列表顯示）
-- - renewal_stage（已移交過濾）
-- - days_pending_sign（等待天數提示）
-- - metadata（階梯計費）
-- - invoice_status（向後相容）
-- - v_monthly_reminders_summary 被 CASCADE 刪除沒重建
--
-- 修復：
-- 1. 完整重建 v_renewal_reminders（基於 101，加上 voided 過濾）
-- 2. 重建 v_monthly_reminders_summary
-- 3. 更新 get_contract_timeline 加回 sent_for_sign_at
--
-- Date: 2026-01-01
-- ============================================================================

-- ============================================================================
-- 1. 重建 v_renewal_reminders（完整版 + voided 過濾）
-- ============================================================================

DROP VIEW IF EXISTS v_monthly_reminders_summary CASCADE;
DROP VIEW IF EXISTS v_renewal_reminders CASCADE;

CREATE VIEW v_renewal_reminders AS
WITH next_contracts AS (
    SELECT DISTINCT ON (renewed_from_id)
        renewed_from_id AS old_contract_id,
        id AS next_contract_id,
        status AS next_status,
        signed_at AS next_signed_at,
        created_at AS next_created_at,
        sent_for_sign_at AS next_sent_for_sign_at,
        contract_period AS next_contract_period,
        start_date AS next_start_date,
        end_date AS next_end_date,
        monthly_rent AS next_monthly_rent,
        payment_cycle AS next_payment_cycle
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
      AND status NOT IN ('cancelled', 'terminated')
    ORDER BY renewed_from_id, created_at DESC
),
first_payments AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        id AS first_payment_id,
        amount AS first_payment_amount,
        payment_status,
        paid_at,
        payment_method,
        due_date AS first_payment_due_date
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
),
-- ★ 104 修正：發票排除已作廢
first_invoices AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        invoice_number,
        invoice_date,
        invoice_status
    FROM payments
    WHERE payment_type = 'rent'
      AND invoice_number IS NOT NULL
      AND invoice_status IS DISTINCT FROM 'voided'
    ORDER BY contract_id, payment_period ASC
)
SELECT
    ct.id,
    ct.contract_number,
    ct.contract_period,
    ct.customer_id,
    ct.branch_id,
    ct.contract_type,
    ct.plan_name,
    ct.start_date,
    ct.end_date,
    ct.monthly_rent,
    ct.deposit,
    ct.payment_cycle,
    ct.payment_day,
    ct.status AS contract_status,
    ct.position_number,
    ct.metadata,

    -- 續約追蹤欄位（原始時間戳）
    ct.renewal_status,
    ct.renewal_notified_at,
    ct.renewal_confirmed_at,
    ct.renewal_notes,

    -- [DEPRECATED] 保留讀取（向後相容）
    ct.renewal_paid_at,
    ct.renewal_invoiced_at,
    ct.renewal_signed_at,
    ct.invoice_status,

    -- 剩餘天數（兩個別名都保留）
    ct.end_date - CURRENT_DATE AS days_until_expiry,
    ct.end_date - CURRENT_DATE AS days_remaining,

    -- 客戶資訊
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.email AS customer_email,
    c.line_user_id,
    c.status AS customer_status,
    c.company_tax_id AS customer_company_tax_id,

    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,

    -- 提醒優先級
    CASE
        WHEN ct.end_date - CURRENT_DATE <= 7 THEN 'urgent'
        WHEN ct.end_date - CURRENT_DATE <= 30 THEN 'high'
        WHEN ct.end_date - CURRENT_DATE <= 60 THEN 'medium'
        ELSE 'low'
    END AS priority,

    -- 合約歷史
    (SELECT COUNT(*) FROM contracts WHERE customer_id = ct.customer_id) AS total_contracts_history,

    -- ========== Next Contract 資訊 ==========

    nc.next_contract_id,
    nc.next_status,
    nc.next_signed_at,
    nc.next_created_at,
    nc.next_sent_for_sign_at,
    nc.next_contract_period,
    nc.next_start_date,
    nc.next_end_date,
    nc.next_monthly_rent,
    nc.next_payment_cycle,

    COALESCE(nc.next_sent_for_sign_at, nc.next_created_at) AS signing_start_at,
    nc.next_contract_id IS NOT NULL AS has_renewal_draft,
    nc.next_sent_for_sign_at IS NOT NULL AS is_sent_for_sign,

    -- 三段視圖狀態
    CASE
        WHEN nc.next_contract_id IS NULL THEN 'pending'
        WHEN nc.next_status = 'active' THEN 'completed'
        ELSE 'handoff'
    END AS renewal_stage,

    -- ========== 首期付款資訊 ==========

    fp.first_payment_id AS next_first_payment_id,
    fp.first_payment_amount AS next_first_payment_amount,
    fp.payment_status AS next_first_payment_status,
    fp.first_payment_due_date AS next_first_payment_due_date,
    fp.payment_status AS first_payment_status,
    fp.paid_at AS first_payment_paid_at,
    fp.payment_method AS first_payment_method,

    -- ========== 發票資訊（★ 104：排除 voided） ==========

    fi.invoice_number AS next_invoice_number,
    fi.invoice_date AS next_invoice_date,

    -- 回簽狀態
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_next_signed,

    -- 回簽等待天數
    CASE
        WHEN nc.next_sent_for_sign_at IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN EXTRACT(DAY FROM NOW() - nc.next_sent_for_sign_at)::INT
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN EXTRACT(DAY FROM NOW() - nc.next_created_at)::INT
        ELSE NULL
    END AS days_pending_sign,

    -- ========== 前端用計算欄位 ==========

    -- 意願 flags（布林）
    ct.renewal_notified_at IS NOT NULL AS is_notified,
    ct.renewal_confirmed_at IS NOT NULL AS is_confirmed,

    -- ★ 104 修正：無續約草稿時為 NULL + 排除 voided
    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fp.payment_status = 'paid' THEN true
        ELSE false
    END AS is_paid,

    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_signed,

    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fi.invoice_number IS NOT NULL THEN true
        ELSE false
    END AS is_invoiced,

    -- 向後相容欄位（已棄用，保留避免前端報錯）
    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fp.payment_status = 'paid' THEN true
        ELSE false
    END AS is_first_payment_paid,

    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fi.invoice_number IS NOT NULL THEN true
        ELSE false
    END AS is_next_invoiced,

    -- 下一步建議動作
    CASE
        WHEN ct.renewal_notified_at IS NULL THEN 'notify'
        WHEN ct.renewal_confirmed_at IS NULL THEN 'confirm'
        WHEN nc.next_contract_id IS NULL THEN 'create_draft'
        WHEN fp.payment_status IS NULL OR fp.payment_status != 'paid' THEN 'collect_payment'
        WHEN fi.invoice_number IS NULL THEN 'create_invoice'
        WHEN nc.next_signed_at IS NULL AND nc.next_status NOT IN ('active', 'signed') THEN 'get_signature'
        WHEN nc.next_status NOT IN ('active') THEN 'activate'
        ELSE 'completed'
    END AS next_action,

    -- 完成度分數（0-7，對應 7 步驟）
    (
        (CASE WHEN ct.renewal_notified_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN ct.renewal_confirmed_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_contract_id IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_sent_for_sign_at IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_signed_at IS NOT NULL OR nc.next_status IN ('active', 'signed') THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_contract_id IS NOT NULL AND fp.payment_status = 'paid' THEN 1 ELSE 0 END) +
        (CASE WHEN nc.next_contract_id IS NOT NULL AND fi.invoice_number IS NOT NULL THEN 1 ELSE 0 END)
    ) AS completion_score

FROM contracts ct
JOIN customers c ON ct.customer_id = c.id
JOIN branches b ON ct.branch_id = b.id
LEFT JOIN next_contracts nc ON nc.old_contract_id = ct.id
LEFT JOIN first_payments fp ON fp.contract_id = nc.next_contract_id
LEFT JOIN first_invoices fi ON fi.contract_id = nc.next_contract_id

WHERE ct.status = 'active'
  AND ct.end_date <= CURRENT_DATE + INTERVAL '90 days'
  AND ct.end_date >= CURRENT_DATE - INTERVAL '30 days'
  AND (nc.next_status IS NULL OR nc.next_status != 'active')

ORDER BY ct.end_date ASC;

COMMENT ON VIEW v_renewal_reminders IS '續約提醒視圖 - 完整修復 + voided 過濾 (104)';
GRANT SELECT ON v_renewal_reminders TO anon, authenticated;

-- ============================================================================
-- 2. 重建 v_monthly_reminders_summary
-- ============================================================================

CREATE VIEW v_monthly_reminders_summary AS
SELECT
    branch_id,
    branch_name,
    COUNT(*) AS total_reminders,
    COUNT(*) FILTER (WHERE priority = 'urgent') AS urgent_count,
    COUNT(*) FILTER (WHERE priority = 'high') AS high_count,
    COUNT(*) FILTER (WHERE renewal_stage = 'pending') AS pending_count,
    COUNT(*) FILTER (WHERE renewal_stage = 'handoff') AS handoff_count,
    ROUND(AVG(completion_score), 2) AS avg_completion_score
FROM v_renewal_reminders
GROUP BY branch_id, branch_name;

COMMENT ON VIEW v_monthly_reminders_summary IS '每月續約統計摘要 (104)';
GRANT SELECT ON v_monthly_reminders_summary TO anon, authenticated;

-- ============================================================================
-- 3. 更新 get_contract_timeline（加回 sent_for_sign_at）
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
            -- ★ 104 修正：加回 sent_for_sign_at
            'sent_for_sign_at', v_workspace.next_sent_for_sign_at,
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

COMMENT ON FUNCTION get_contract_timeline IS '取得合約的 Timeline 和 Decision - 加回 sent_for_sign_at (104)';

-- ============================================================================
-- 4. 驗證
-- ============================================================================

DO $$
DECLARE
    reminders_count INT;
    summary_count INT;
    has_days_remaining BOOLEAN;
    has_completion_score BOOLEAN;
    has_company_name BOOLEAN;
    has_renewal_stage BOOLEAN;
    has_days_pending_sign BOOLEAN;
    test_result JSONB;
    test_contract_id INT;
BEGIN
    SELECT COUNT(*) INTO reminders_count FROM v_renewal_reminders;
    SELECT COUNT(*) INTO summary_count FROM v_monthly_reminders_summary;

    -- 檢查關鍵欄位
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_renewal_reminders' AND column_name = 'days_remaining'
    ) INTO has_days_remaining;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_renewal_reminders' AND column_name = 'completion_score'
    ) INTO has_completion_score;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_renewal_reminders' AND column_name = 'company_name'
    ) INTO has_company_name;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_renewal_reminders' AND column_name = 'renewal_stage'
    ) INTO has_renewal_stage;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_renewal_reminders' AND column_name = 'days_pending_sign'
    ) INTO has_days_pending_sign;

    -- 測試 get_contract_timeline
    SELECT id INTO test_contract_id
    FROM v_contract_workspace
    LIMIT 1;

    IF test_contract_id IS NOT NULL THEN
        test_result := get_contract_timeline(test_contract_id);
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 104 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '1. v_renewal_reminders 完整重建（筆數: %）', reminders_count;
    RAISE NOTICE '';
    RAISE NOTICE '   關鍵欄位檢查：';
    RAISE NOTICE '   [%] days_remaining', CASE WHEN has_days_remaining THEN 'OK' ELSE 'NG' END;
    RAISE NOTICE '   [%] completion_score', CASE WHEN has_completion_score THEN 'OK' ELSE 'NG' END;
    RAISE NOTICE '   [%] company_name', CASE WHEN has_company_name THEN 'OK' ELSE 'NG' END;
    RAISE NOTICE '   [%] renewal_stage', CASE WHEN has_renewal_stage THEN 'OK' ELSE 'NG' END;
    RAISE NOTICE '   [%] days_pending_sign', CASE WHEN has_days_pending_sign THEN 'OK' ELSE 'NG' END;
    RAISE NOTICE '';
    RAISE NOTICE '2. v_monthly_reminders_summary 重建完成（筆數: %）', summary_count;
    RAISE NOTICE '';
    RAISE NOTICE '3. get_contract_timeline 更新完成';
    IF test_result->>'success' = 'true' THEN
        RAISE NOTICE '   測試結果: 成功';
    ELSE
        RAISE NOTICE '   測試結果: %', test_result->>'error';
    END IF;
    RAISE NOTICE '';
    RAISE NOTICE '修正內容：';
    RAISE NOTICE '- 恢復 101 的完整 v_renewal_reminders 欄位';
    RAISE NOTICE '- 發票排除 voided（SSOT）';
    RAISE NOTICE '- 重建 v_monthly_reminders_summary';
    RAISE NOTICE '- get_contract_timeline 加回 sent_for_sign_at';
END $$;
