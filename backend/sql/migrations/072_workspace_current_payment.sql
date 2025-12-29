-- 072_workspace_current_payment.sql
-- 修正 v_contract_workspace 付款狀態：改為顯示「當前待處理」付款
--
-- 問題：
-- 原本 first_payments CTE 取最早的付款（ORDER BY payment_period ASC）
-- 這導致合約有多筆付款時，只顯示第一期的狀態
-- 用戶以為已收款，實際上可能有逾期款項
--
-- 解法：
-- 改為「current_payment」邏輯：
-- 1. 優先取最近一筆待處理（pending/overdue）的付款
-- 2. 若全部已付/取消，則取最近已付的付款
-- Date: 2025-12-29

-- ============================================================================
-- 更新 v_contract_workspace 視圖
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
        sent_for_sign_at AS next_sent_for_sign_at,
        signed_at AS next_signed_at,
        created_at AS next_created_at,
        start_date AS next_start_date,
        end_date AS next_end_date
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
    ORDER BY renewed_from_id, created_at DESC
),
-- ★ 改名：current_payment（取代 first_payments）
-- 邏輯：優先取待處理（pending/overdue），若無則取最近已付
pending_payments AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        id AS payment_id,
        payment_status,
        paid_at,
        due_date,
        amount
    FROM payments
    WHERE payment_type = 'rent'
      AND payment_status IN ('pending', 'overdue')
    ORDER BY contract_id, due_date ASC  -- 取最近到期的待處理
),
latest_paid_payments AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        id AS payment_id,
        payment_status,
        paid_at,
        due_date,
        amount
    FROM payments
    WHERE payment_type = 'rent'
      AND payment_status = 'paid'
    ORDER BY contract_id, due_date DESC  -- 取最近已付
),
current_payments AS (
    -- 合併：有待處理就用待處理，否則用最近已付
    SELECT
        COALESCE(pp.contract_id, lp.contract_id) AS contract_id,
        COALESCE(pp.payment_id, lp.payment_id) AS current_payment_id,
        COALESCE(pp.payment_status, lp.payment_status) AS current_payment_status,
        COALESCE(pp.paid_at, lp.paid_at) AS current_payment_paid_at,
        COALESCE(pp.due_date, lp.due_date) AS current_payment_due_date,
        COALESCE(pp.amount, lp.amount) AS current_payment_amount,
        -- 標記是否有待處理
        CASE WHEN pp.payment_id IS NOT NULL THEN TRUE ELSE FALSE END AS has_pending_payment
    FROM latest_paid_payments lp
    FULL OUTER JOIN pending_payments pp ON pp.contract_id = lp.contract_id
),
-- 第一期發票狀態（保持原邏輯）
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

    -- ★ 當前付款狀態（改為 current_payment）
    -- 保留舊欄位名稱以維持向後相容
    cp.current_payment_id AS first_payment_id,
    cp.current_payment_status AS first_payment_status,
    cp.current_payment_paid_at AS first_payment_paid_at,
    cp.current_payment_due_date AS first_payment_due_date,
    cp.current_payment_amount AS first_payment_amount,
    cp.has_pending_payment,  -- ★ 新增：是否有待處理付款

    -- 第一期發票狀態
    fi.first_invoice_status,
    fi.first_invoice_number,
    fi.first_invoice_date,

    -- ========== 計算欄位 ==========

    -- 剩餘天數
    c.end_date - CURRENT_DATE AS days_until_expiry,

    -- ★ 新增：合約有效狀態（動態計算過期）
    CASE
        WHEN c.status = 'active' AND c.end_date < CURRENT_DATE THEN 'expired'
        ELSE c.status
    END AS effective_status,

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
        WHEN nc.next_contract_id IS NOT NULL THEN 'not_started'
        ELSE 'not_started'
    END AS timeline_signing_status,

    -- 3. 款項收取（★ 使用 current_payment_status）
    CASE
        WHEN cp.current_payment_status = 'paid' AND NOT cp.has_pending_payment THEN 'done'
        WHEN cp.current_payment_status = 'overdue' THEN 'blocked'
        WHEN cp.current_payment_status IS NOT NULL THEN 'pending'
        ELSE 'not_started'
    END AS timeline_payment_status,

    -- ========== Decision Table ==========

    -- 卡點判斷
    CASE
        -- 1. 有下一張合約，關注簽約狀態
        WHEN nc.next_contract_id IS NOT NULL THEN
            CASE
                WHEN nc.next_status = 'active' THEN NULL  -- 已完成
                WHEN nc.next_signed_at IS NOT NULL THEN 'pending_activation'
                WHEN nc.next_status = 'pending_sign' THEN 'waiting_signature'
                WHEN nc.next_sent_for_sign_at IS NOT NULL
                     AND cp.current_payment_status IN ('pending', 'overdue')
                     THEN 'waiting_payment_before_sign'
                WHEN nc.next_sent_for_sign_at IS NOT NULL THEN 'waiting_signature'
                WHEN nc.next_status = 'renewal_draft' THEN 'draft_not_sent'
                ELSE 'need_create_draft'
            END
        -- 2. 無下一張合約，關注續約意願
        WHEN c.renewal_confirmed_at IS NOT NULL
             AND cp.current_payment_status = 'paid'
             AND NOT cp.has_pending_payment
             THEN 'ready_for_draft'
        WHEN c.renewal_confirmed_at IS NOT NULL
             AND cp.current_payment_status IN ('pending', 'overdue')
             THEN 'waiting_payment'
        WHEN c.renewal_notified_at IS NOT NULL THEN 'waiting_confirmation'
        ELSE 'need_notify'
    END AS decision_blocked_by,

    -- 下一步行動
    CASE
        WHEN nc.next_contract_id IS NOT NULL THEN
            CASE
                WHEN nc.next_status = 'active' THEN NULL
                WHEN nc.next_signed_at IS NOT NULL THEN '啟用續約合約'
                WHEN nc.next_status = 'pending_sign' THEN '等待客戶回簽'
                WHEN nc.next_sent_for_sign_at IS NOT NULL
                     AND cp.current_payment_status IN ('pending', 'overdue')
                     THEN '催繳款項並等待簽約'
                WHEN nc.next_sent_for_sign_at IS NOT NULL THEN '追蹤簽約進度'
                WHEN nc.next_status = 'renewal_draft' THEN '送出簽署'
                ELSE '建立續約草稿'
            END
        WHEN c.renewal_confirmed_at IS NOT NULL
             AND cp.current_payment_status = 'paid'
             AND NOT cp.has_pending_payment
             THEN '建立續約草稿'
        WHEN c.renewal_confirmed_at IS NOT NULL
             AND cp.current_payment_status IN ('pending', 'overdue')
             THEN '催收待繳款項'
        WHEN c.renewal_notified_at IS NOT NULL THEN '確認續約意願'
        ELSE '通知客戶續約'
    END AS decision_next_action

FROM contracts c
LEFT JOIN customers cust ON cust.id = c.customer_id
LEFT JOIN branches b ON b.id = c.branch_id
LEFT JOIN prev_contracts pc ON pc.contract_id = c.id
LEFT JOIN next_contracts nc ON nc.old_contract_id = c.id
LEFT JOIN current_payments cp ON cp.contract_id = COALESCE(nc.next_contract_id, c.id)
LEFT JOIN first_invoices fi ON fi.contract_id = COALESCE(nc.next_contract_id, c.id)
WHERE c.status IN ('active', 'pending', 'pending_sign', 'renewal_draft', 'signed');

-- 授權
GRANT SELECT ON v_contract_workspace TO anon, authenticated;

COMMENT ON VIEW v_contract_workspace IS '合約工作區視圖 - 付款狀態改為顯示當前待處理（非第一期）';

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 072 完成 ===';
    RAISE NOTICE '✅ v_contract_workspace 視圖已更新';
    RAISE NOTICE '變更說明：';
    RAISE NOTICE '- first_payment_* 欄位現在顯示「當前待處理」付款（非第一期）';
    RAISE NOTICE '- 新增 has_pending_payment 欄位';
    RAISE NOTICE '- 新增 effective_status 欄位（動態計算過期狀態）';
END $$;
