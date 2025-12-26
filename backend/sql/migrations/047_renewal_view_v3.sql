-- ============================================================================
-- Migration 047: 續約視圖 V3 - 三段式過濾 + SSOT 設計
--
-- 變更內容：
-- [CHG-001] 移除 renewal_signed_at IS NULL 過濾（deprecated）
-- [CHG-002] 加入 next_contract 關聯，實現三段視圖
-- [CHG-003] 加入 renewal_stage 欄位區分狀態
-- [CHG-004] 收款/開票狀態從 payment/invoice 計算（SSOT）
--
-- 三段視圖：
-- - pending: 待續約（尚未建立 next_contract）
-- - handoff: 已移交（已建立 next_contract，但未 active）
-- - completed: 完成（next_contract.status = active）
-- ============================================================================

-- ============================================================================
-- 0. 先新增欄位（視圖會用到）
-- ============================================================================

-- 新增 sent_for_sign_at 欄位
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'contracts' AND column_name = 'sent_for_sign_at'
    ) THEN
        ALTER TABLE contracts ADD COLUMN sent_for_sign_at TIMESTAMPTZ;
        COMMENT ON COLUMN contracts.sent_for_sign_at IS '送簽時間（業務送出合約給客戶簽署）';
    END IF;
END $$;

-- 標記 deprecated 欄位
COMMENT ON COLUMN contracts.renewal_signed_at IS '[DEPRECATED] 續約簽約時間 - 請改用 next_contract.signed_at';
COMMENT ON COLUMN contracts.renewal_paid_at IS '[DEPRECATED] 續約已收款時間 - 請改用 payments.payment_status 計算';
COMMENT ON COLUMN contracts.renewal_invoiced_at IS '[DEPRECATED] 續約已開票時間 - 請改用 invoices.status 計算';

-- ============================================================================
-- 1. 刪除依賴的視圖
-- ============================================================================

DROP VIEW IF EXISTS v_monthly_reminders_summary CASCADE;
DROP VIEW IF EXISTS v_renewal_reminders CASCADE;
DROP VIEW IF EXISTS v_pending_sign_contracts CASCADE;

-- ============================================================================
-- 2. 重建 v_renewal_reminders 視圖
-- ============================================================================

CREATE VIEW v_renewal_reminders AS
WITH next_contracts AS (
    -- 找出每張合約的「下一張續約合約」（最新一筆）
    SELECT DISTINCT ON (renewed_from_id)
        renewed_from_id AS old_contract_id,
        id AS next_contract_id,
        status AS next_status,
        signed_at AS next_signed_at,
        created_at AS next_created_at
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
    ORDER BY renewed_from_id, created_at DESC
),
first_payments AS (
    -- 找出每張續約合約的第一期付款狀態
    SELECT DISTINCT ON (contract_id)
        contract_id,
        payment_status,
        paid_at
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
)
SELECT
    ct.id,
    ct.contract_number,
    ct.customer_id,
    ct.branch_id,
    ct.contract_type,
    ct.plan_name,
    ct.start_date,
    ct.end_date,
    ct.monthly_rent,
    ct.deposit,
    ct.payment_cycle,
    ct.status AS contract_status,
    ct.position_number,

    -- 續約追蹤欄位（意願管理，可手動更新）
    ct.renewal_status,
    ct.renewal_notified_at,
    ct.renewal_confirmed_at,
    ct.renewal_notes,

    -- [DEPRECATED] 這些欄位保留讀取，不再寫入
    ct.renewal_paid_at,      -- deprecated: 改用 payment 計算
    ct.renewal_invoiced_at,  -- deprecated: 改用 invoice 計算
    ct.renewal_signed_at,    -- deprecated: 改用 next_contract.signed_at
    ct.invoice_status,       -- deprecated: 改用 invoice 計算

    -- 剩餘天數
    ct.end_date - CURRENT_DATE AS days_until_expiry,
    ct.end_date - CURRENT_DATE AS days_remaining,  -- 前端相容

    -- 客戶資訊
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.email AS customer_email,
    c.line_user_id,
    c.status AS customer_status,

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

    -- ========== 新增欄位 ==========

    -- Next Contract 資訊（SSOT）
    nc.next_contract_id,
    nc.next_status,
    nc.next_signed_at,
    nc.next_created_at,
    COALESCE(nc.next_created_at, NULL) AS signing_start_at,  -- 送簽開始時間

    -- 是否有續約草稿（向後相容）
    nc.next_contract_id IS NOT NULL AS has_renewal_draft,

    -- 三段視圖狀態
    CASE
        WHEN nc.next_contract_id IS NULL THEN 'pending'           -- 待續約
        WHEN nc.next_status = 'active' THEN 'completed'           -- 完成
        ELSE 'handoff'                                             -- 已移交
    END AS renewal_stage,

    -- 收款狀態（從 payment 計算，SSOT）
    CASE
        WHEN fp.payment_status = 'paid' THEN true
        ELSE false
    END AS is_first_payment_paid,
    fp.payment_status AS first_payment_status,

    -- 回簽狀態（從 next_contract 計算，SSOT）
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_next_signed,

    -- 回簽等待天數
    CASE
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
        THEN EXTRACT(DAY FROM NOW() - nc.next_created_at)::INT
        ELSE NULL
    END AS days_pending_sign

FROM contracts ct
JOIN customers c ON ct.customer_id = c.id
JOIN branches b ON ct.branch_id = b.id
LEFT JOIN next_contracts nc ON nc.old_contract_id = ct.id
LEFT JOIN first_payments fp ON fp.contract_id = nc.next_contract_id

WHERE ct.status = 'active'
  AND ct.end_date <= CURRENT_DATE + INTERVAL '90 days'
  AND ct.end_date >= CURRENT_DATE - INTERVAL '30 days'
  -- ★ 移除舊條件：AND ct.renewal_signed_at IS NULL
  -- ★ 新條件：只有 next_contract 已 active 時才排除（completed）
  AND (nc.next_status IS NULL OR nc.next_status != 'active')

ORDER BY ct.end_date ASC;

COMMENT ON VIEW v_renewal_reminders IS '續約提醒視圖（V3）- 三段式狀態：pending/handoff/completed，SSOT 設計';

-- 授權
GRANT SELECT ON v_renewal_reminders TO anon, authenticated;

-- ============================================================================
-- 3. 重建 v_monthly_reminders_summary
-- ============================================================================

CREATE VIEW v_monthly_reminders_summary AS
SELECT
    branch_id,
    branch_name,
    COUNT(*) AS total_reminders,
    COUNT(*) FILTER (WHERE priority = 'urgent') AS urgent_count,
    COUNT(*) FILTER (WHERE priority = 'high') AS high_count,
    -- 新增：按 renewal_stage 統計
    COUNT(*) FILTER (WHERE renewal_stage = 'pending') AS pending_count,
    COUNT(*) FILTER (WHERE renewal_stage = 'handoff') AS handoff_count
FROM v_renewal_reminders
GROUP BY branch_id, branch_name;

GRANT SELECT ON v_monthly_reminders_summary TO anon, authenticated;

-- ============================================================================
-- 4. 建立待簽列表視圖
-- ============================================================================

CREATE VIEW v_pending_sign_contracts AS
SELECT
    c.id,
    c.contract_number,
    c.customer_id,
    c.branch_id,
    c.contract_type,
    c.plan_name,
    c.start_date,
    c.end_date,
    c.monthly_rent,
    c.status,
    c.renewed_from_id,
    c.signed_at,
    -- 送簽開始時間（暫用 created_at，之後可加 sent_for_sign_at）
    COALESCE(c.sent_for_sign_at, c.created_at) AS signing_start_at,
    -- 等待天數
    EXTRACT(DAY FROM NOW() - COALESCE(c.sent_for_sign_at, c.created_at))::INT AS days_pending,
    -- 客戶資訊
    cust.name AS customer_name,
    cust.company_name,
    cust.phone AS customer_phone,
    cust.email AS customer_email,
    -- 場館資訊
    b.code AS branch_code,
    b.name AS branch_name,
    -- 是否已付款但沒簽（需要優先處理）
    EXISTS(
        SELECT 1 FROM payments p
        WHERE p.contract_id = c.id
        AND p.payment_status = 'paid'
    ) AS has_paid_but_not_signed,
    -- 催簽次數（從 notification_logs 計算，如果有的話）
    COALESCE(
        (SELECT COUNT(*) FROM notification_logs nl
         WHERE nl.contract_id = c.id
         AND nl.notification_type = 'sign_reminder'),
        0
    )::INT AS sign_reminder_count
FROM contracts c
JOIN customers cust ON c.customer_id = cust.id
JOIN branches b ON c.branch_id = b.id
WHERE c.status IN ('pending_sign', 'renewal_draft')  -- 包含續約草稿
  AND c.signed_at IS NULL
ORDER BY
    -- 已付款但沒簽的排最前
    has_paid_but_not_signed DESC,
    -- 等最久的排前面
    signing_start_at ASC;

COMMENT ON VIEW v_pending_sign_contracts IS '待簽合約列表 - 追蹤等待客戶回簽的合約';

GRANT SELECT ON v_pending_sign_contracts TO anon, authenticated;

-- ============================================================================
-- 完成
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '=== Migration 047 完成 ===';
    RAISE NOTICE '✅ v_renewal_reminders 視圖已更新（三段式狀態）';
    RAISE NOTICE '✅ v_pending_sign_contracts 視圖已建立（待簽列表）';
    RAISE NOTICE '✅ sent_for_sign_at 欄位已新增';
    RAISE NOTICE '✅ deprecated 欄位已標記';
    RAISE NOTICE '';
    RAISE NOTICE '變更說明：';
    RAISE NOTICE '- 移除 renewal_signed_at IS NULL 過濾條件';
    RAISE NOTICE '- 新增 renewal_stage 欄位：pending/handoff/completed';
    RAISE NOTICE '- 新增 next_contract 相關欄位';
    RAISE NOTICE '- 收款/開票狀態改為從 payment/invoice 計算';
END $$;
