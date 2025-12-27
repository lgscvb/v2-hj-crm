-- 051_update_workspace_signing.sql
-- 更新 Contract Workspace 視圖和 Timeline 函數，支援完整簽署流程

-- ============================================================================
-- 1. 更新 Contract Workspace 視圖
-- ============================================================================

DROP VIEW IF EXISTS v_contract_workspace CASCADE;

CREATE VIEW v_contract_workspace AS
WITH
-- 找出每張合約的「上一張合約」（renewed_from）
prev_contracts AS (
    SELECT
        id AS contract_id,
        renewed_from_id AS prev_contract_id
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
),
-- 找出每張合約的「下一張續約合約」（最新一筆）
next_contracts AS (
    SELECT DISTINCT ON (renewed_from_id)
        renewed_from_id AS old_contract_id,
        id AS next_contract_id,
        status AS next_status,
        sent_for_sign_at AS next_sent_for_sign_at,  -- 新增
        signed_at AS next_signed_at,
        created_at AS next_created_at,
        start_date AS next_start_date,
        end_date AS next_end_date
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
    ORDER BY renewed_from_id, created_at DESC
),
-- 第一期付款狀態
first_payments AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        id AS first_payment_id,
        payment_status AS first_payment_status,
        paid_at AS first_payment_paid_at,
        due_date AS first_payment_due_date,
        amount AS first_payment_amount
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
),
-- 第一期發票狀態
first_invoices AS (
    SELECT DISTINCT ON (p.contract_id)
        p.contract_id,
        p.invoice_status AS first_invoice_status,
        p.invoice_number AS first_invoice_number,
        p.invoice_date AS first_invoice_date
    FROM payments p
    WHERE p.payment_type = 'rent'
      AND p.invoice_status IS NOT NULL
    ORDER BY p.contract_id, p.payment_period ASC
)
SELECT
    -- 合約基本資訊
    c.id,
    c.contract_number,
    c.contract_period,
    c.customer_id,
    c.branch_id,
    c.contract_type,
    c.plan_name,
    c.start_date,
    c.end_date,
    c.monthly_rent,
    c.deposit,
    c.payment_cycle,
    c.status,
    c.position_number,
    c.sent_for_sign_at,
    c.signed_at,
    c.created_at,
    c.updated_at,

    -- 客戶資訊
    cust.name AS customer_name,
    c.company_name,
    cust.phone AS customer_phone,
    cust.email AS customer_email,
    cust.line_user_id,

    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,

    -- 續約追蹤欄位（意願管理）
    c.renewal_notified_at,
    c.renewal_confirmed_at,
    c.renewal_notes,

    -- 上一張合約
    pc.prev_contract_id,

    -- 下一張續約合約
    nc.next_contract_id,
    nc.next_status,
    nc.next_sent_for_sign_at,
    nc.next_signed_at,
    nc.next_created_at,
    nc.next_start_date,
    nc.next_end_date,

    -- 第一期付款狀態
    fp.first_payment_id,
    fp.first_payment_status,
    fp.first_payment_paid_at,
    fp.first_payment_due_date,
    fp.first_payment_amount,

    -- 第一期發票狀態
    fi.first_invoice_status,
    fi.first_invoice_number,
    fi.first_invoice_date,

    -- ========== 計算欄位 ==========

    -- 剩餘天數
    c.end_date - CURRENT_DATE AS days_until_expiry,

    -- 送簽後等待天數（基於 sent_for_sign_at）
    CASE
        WHEN nc.next_sent_for_sign_at IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN EXTRACT(DAY FROM NOW() - nc.next_sent_for_sign_at)::INT
        ELSE NULL
    END AS days_pending_sign,

    -- ========== Timeline 節點狀態 ==========

    -- 1. 續約意願
    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL THEN 'done'
        WHEN c.renewal_notified_at IS NOT NULL THEN 'pending'
        ELSE 'not_started'
    END AS timeline_intent_status,

    -- 2. 文件回簽（更精細的狀態判斷）
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN 'done'
        WHEN nc.next_status = 'active' THEN 'done'
        WHEN nc.next_status = 'signed' THEN 'done'
        WHEN nc.next_status = 'pending_sign' THEN 'pending'
        WHEN nc.next_status = 'renewal_draft' AND nc.next_sent_for_sign_at IS NOT NULL THEN 'pending'
        WHEN nc.next_status = 'renewal_draft' THEN 'draft'
        WHEN nc.next_status = 'draft' THEN 'draft'
        WHEN nc.next_contract_id IS NULL THEN 'not_created'
        ELSE 'unknown'
    END AS timeline_signing_status,

    -- 3. 收款（看 next_contract 的第一期）
    CASE
        WHEN fp.first_payment_status = 'paid' THEN 'done'
        WHEN fp.first_payment_status = 'overdue' THEN 'blocked'
        WHEN fp.first_payment_status IS NOT NULL THEN 'pending'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'not_created'
    END AS timeline_payment_status,

    -- 4. 發票
    CASE
        WHEN fi.first_invoice_status = 'issued' THEN 'done'
        WHEN fi.first_invoice_status IS NOT NULL THEN 'pending'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'not_created'
    END AS timeline_invoice_status,

    -- 5. 啟用
    CASE
        WHEN nc.next_status = 'active' THEN 'done'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'pending'
    END AS timeline_activation_status,

    -- ========== Decision（卡點判斷，first-match wins） ==========

    CASE
        -- 優先序 1：已確認但尚未建立續約合約
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN 'need_create_renewal'
        -- 優先序 2：有草稿但未送簽
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_status IN ('renewal_draft', 'draft')
         AND nc.next_sent_for_sign_at IS NULL
        THEN 'need_send_for_sign'
        -- 優先序 3：回簽逾期（送簽後超過 14 天）
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_sent_for_sign_at IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - nc.next_sent_for_sign_at) > 14
        THEN 'signing_overdue'
        -- 優先序 4：待簽中（未逾期）
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_sent_for_sign_at IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN 'waiting_for_sign'
        -- 優先序 5：已簽但未啟用
        WHEN nc.next_status = 'signed'
        THEN 'need_activate'
        -- 優先序 6：已簽/已啟用但款項未入帳
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN 'payment_pending'
        -- 優先序 7：已付款但發票未開
        WHEN fp.first_payment_status = 'paid'
         AND (fi.first_invoice_status IS NULL OR fi.first_invoice_status != 'issued')
        THEN 'invoice_pending'
        -- 優先序 8：完成
        WHEN nc.next_status = 'active'
        THEN 'completed'
        -- 其他
        ELSE NULL
    END AS decision_blocked_by,

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN '建立續約合約草稿'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_status IN ('renewal_draft', 'draft')
         AND nc.next_sent_for_sign_at IS NULL
        THEN '產生 PDF 並送簽'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_sent_for_sign_at IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - nc.next_sent_for_sign_at) > 14
        THEN '發催簽通知'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_sent_for_sign_at IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN '等待客戶回簽'
        WHEN nc.next_status = 'signed'
        THEN '啟用續約合約'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN '催收首期款項'
        WHEN fp.first_payment_status = 'paid'
         AND (fi.first_invoice_status IS NULL OR fi.first_invoice_status != 'issued')
        THEN '開立首期發票'
        WHEN nc.next_status = 'active'
        THEN NULL
        ELSE NULL
    END AS decision_next_action,

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN 'Sales'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_status IN ('renewal_draft', 'draft')
         AND nc.next_sent_for_sign_at IS NULL
        THEN 'Sales'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_sent_for_sign_at IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN 'Sales'
        WHEN nc.next_status = 'signed'
        THEN 'Sales'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN 'Finance'
        WHEN fp.first_payment_status = 'paid'
         AND (fi.first_invoice_status IS NULL OR fi.first_invoice_status != 'issued')
        THEN 'Finance'
        ELSE NULL
    END AS decision_owner

FROM contracts c
JOIN customers cust ON c.customer_id = cust.id
JOIN branches b ON c.branch_id = b.id
LEFT JOIN prev_contracts pc ON pc.contract_id = c.id
LEFT JOIN next_contracts nc ON nc.old_contract_id = c.id
LEFT JOIN first_payments fp ON fp.contract_id = COALESCE(nc.next_contract_id, c.id)
LEFT JOIN first_invoices fi ON fi.contract_id = COALESCE(nc.next_contract_id, c.id);

COMMENT ON VIEW v_contract_workspace IS 'Contract Workspace 視圖 - 以合約為中心的狀態彙總（含完整簽署流程）';

GRANT SELECT ON v_contract_workspace TO anon, authenticated;

-- ============================================================================
-- 2. 更新 get_contract_timeline 函數
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
            'sent_for_sign_at', v_workspace.next_sent_for_sign_at,
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
            'invoice_status', v_workspace.first_invoice_status,
            'invoice_number', v_workspace.first_invoice_number
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
            'contract_period', v_workspace.contract_period,
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
                    'sent_for_sign_at', v_workspace.next_sent_for_sign_at,
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

COMMENT ON FUNCTION get_contract_timeline IS '取得合約的 Timeline 和 Decision（支援完整簽署流程）';

GRANT EXECUTE ON FUNCTION get_contract_timeline TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 051 完成 ===';
    RAISE NOTICE '✅ v_contract_workspace 視圖已更新（支援簽署流程）';
    RAISE NOTICE '✅ get_contract_timeline 函數已更新';
    RAISE NOTICE '';
    RAISE NOTICE '新增的 Decision 狀態：';
    RAISE NOTICE '- need_send_for_sign: 需要送簽';
    RAISE NOTICE '- waiting_for_sign: 等待回簽';
    RAISE NOTICE '- signing_overdue: 回簽逾期';
    RAISE NOTICE '- need_activate: 需要啟用';
END $$;
