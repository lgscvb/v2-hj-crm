-- ============================================================================
-- Migration 100: 修復 COALESCE 邏輯 + 補齊欄位 + 統一發票 SSOT
--
-- 問題：
-- 1. fp/fi JOIN 使用 COALESCE(nc.next_contract_id, c.id)
--    - 沒有續約草稿時，會把「現有合約」的付款灌進續約進度
--    - 這是邏輯污染，續約流程應該只看「續約合約」的狀態
--
-- 2. 缺少欄位：original_price, deposit_status, rental_address
--
-- 3. 發票 SSOT 不一致：
--    - v_contract_workspace 用 invoice_status
--    - v_renewal_reminders 用 payments.invoice_number IS NOT NULL
--    - 應統一用 invoice_number IS NOT NULL（包含外部開立發票）
--
-- 4. LINE 提醒需要新合約條款：next_monthly_rent, next_payment_cycle
--
-- Date: 2026-01-01
-- ============================================================================

-- ============================================================================
-- 1. 重建 v_contract_workspace（核心修正）
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
-- 找出每張合約的「下一張續約合約」（最新一筆，排除已取消）
next_contracts AS (
    SELECT DISTINCT ON (renewed_from_id)
        renewed_from_id AS old_contract_id,
        id AS next_contract_id,
        status AS next_status,
        signed_at AS next_signed_at,
        created_at AS next_created_at,
        start_date AS next_start_date,
        end_date AS next_end_date,
        sent_for_sign_at AS next_sent_for_sign_at,
        contract_period AS next_contract_period,
        -- ★ 100 新增：LINE 提醒用新合約條款
        monthly_rent AS next_monthly_rent,
        payment_cycle AS next_payment_cycle
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
      AND status NOT IN ('cancelled', 'terminated')
    ORDER BY renewed_from_id, created_at DESC
),
-- ★ 100 修正：只 JOIN 續約合約的第一期付款（移除 COALESCE）
first_payments AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        id AS first_payment_id,
        payment_status AS first_payment_status,
        paid_at AS first_payment_paid_at,
        due_date AS first_payment_due_date,
        amount AS first_payment_amount,
        payment_method AS first_payment_method
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
),
-- ★ 100 修正：發票用 invoice_number IS NOT NULL（統一 SSOT）
first_invoices AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        invoice_number AS first_invoice_number,
        invoice_date AS first_invoice_date
    FROM payments
    WHERE payment_type = 'rent'
      AND invoice_number IS NOT NULL
    ORDER BY contract_id, payment_period ASC
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
    c.payment_day,
    c.status,
    c.position_number,
    c.signed_at,
    c.sent_for_sign_at,
    c.renewed_from_id,
    c.created_at,
    c.updated_at,

    -- ★ 100 新增：補齊欄位
    c.original_price,
    c.deposit_status,
    c.rental_address,

    -- 承租人資訊（合約層級）
    c.company_name,
    c.representative_name,
    c.representative_address,
    c.id_number,
    c.company_tax_id,
    c.phone,
    c.email,

    -- 客戶資訊
    cust.name AS customer_name,
    cust.company_name AS customer_company_name,
    cust.phone AS customer_phone,
    cust.email AS customer_email,
    cust.line_user_id,
    cust.status AS customer_status,
    cust.address AS customer_address,
    cust.risk_level AS customer_risk_level,

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
    nc.next_signed_at,
    nc.next_created_at,
    nc.next_start_date,
    nc.next_end_date,
    nc.next_sent_for_sign_at,
    nc.next_contract_period,
    -- ★ 100 新增：LINE 提醒用
    nc.next_monthly_rent,
    nc.next_payment_cycle,

    -- 送簽開始時間
    COALESCE(nc.next_sent_for_sign_at, nc.next_created_at) AS signing_start_at,

    -- 是否有續約草稿
    nc.next_contract_id IS NOT NULL AS has_renewal_draft,
    nc.next_sent_for_sign_at IS NOT NULL AS is_sent_for_sign,

    -- ★ 100 修正：只有續約合約時才有付款/發票資訊
    fp.first_payment_id,
    fp.first_payment_status,
    fp.first_payment_paid_at,
    fp.first_payment_due_date,
    fp.first_payment_amount,
    fp.first_payment_method,

    -- ★ 100 修正：發票改用 invoice_number
    fi.first_invoice_number,
    fi.first_invoice_date,

    -- ========== 計算欄位 ==========

    -- 剩餘天數
    c.end_date - CURRENT_DATE AS days_until_expiry,

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

    -- ========== Timeline 節點狀態 ==========

    -- 1. 續約意願
    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL THEN 'done'
        WHEN c.renewal_notified_at IS NOT NULL THEN 'pending'
        ELSE 'not_started'
    END AS timeline_intent_status,

    -- 2. 文件回簽（看 next_contract）
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN 'done'
        WHEN nc.next_status IN ('active', 'signed') THEN 'done'
        WHEN nc.next_sent_for_sign_at IS NOT NULL THEN 'pending'
        WHEN nc.next_status = 'renewal_draft' THEN 'draft'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'unknown'
    END AS timeline_signing_status,

    -- 3. 收款（★ 100 修正：沒有續約草稿時為 n/a）
    CASE
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        WHEN fp.first_payment_status = 'paid' THEN 'done'
        WHEN fp.first_payment_status = 'overdue' THEN 'blocked'
        WHEN fp.first_payment_status IS NOT NULL THEN 'pending'
        ELSE 'not_created'
    END AS timeline_payment_status,

    -- 4. 發票（★ 100 修正：用 invoice_number IS NOT NULL）
    CASE
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        WHEN fi.first_invoice_number IS NOT NULL THEN 'done'
        ELSE 'not_created'
    END AS timeline_invoice_status,

    -- 5. 啟用
    CASE
        WHEN nc.next_status = 'active' THEN 'done'
        WHEN nc.next_contract_id IS NULL THEN 'n/a'
        ELSE 'pending'
    END AS timeline_activation_status,

    -- ========== 布林 Flags ==========

    c.renewal_notified_at IS NOT NULL AS is_notified,
    c.renewal_confirmed_at IS NOT NULL AS is_confirmed,
    -- ★ 100 修正：沒有續約草稿時為 NULL（前端當成「不適用」）
    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fp.first_payment_status = 'paid' THEN true
        ELSE false
    END AS is_paid,
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_signed,
    -- ★ 100 修正：沒有續約草稿時為 NULL
    CASE
        WHEN nc.next_contract_id IS NULL THEN NULL
        WHEN fi.first_invoice_number IS NOT NULL THEN true
        ELSE false
    END AS is_invoiced,

    -- ========== Decision（卡點判斷，first-match wins） ==========

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN 'need_create_renewal'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - COALESCE(nc.next_sent_for_sign_at, nc.next_created_at)) > 14
        THEN 'signing_overdue'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN 'payment_pending'
        WHEN fp.first_payment_status = 'paid'
         AND fi.first_invoice_number IS NULL
        THEN 'invoice_pending'
        WHEN nc.next_status = 'active'
        THEN 'completed'
        ELSE NULL
    END AS decision_blocked_by,

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN '建立續約合約草稿'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - COALESCE(nc.next_sent_for_sign_at, nc.next_created_at)) > 14
        THEN '發催簽通知'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN '催收首期款項'
        WHEN fp.first_payment_status = 'paid'
         AND fi.first_invoice_number IS NULL
        THEN '開立首期發票'
        WHEN nc.next_status = 'active'
        THEN NULL
        ELSE NULL
    END AS decision_next_action,

    CASE
        WHEN c.renewal_confirmed_at IS NOT NULL AND nc.next_contract_id IS NULL
        THEN 'Sales'
        WHEN nc.next_contract_id IS NOT NULL
         AND nc.next_signed_at IS NULL
         AND nc.next_status NOT IN ('active', 'signed')
         AND EXTRACT(DAY FROM NOW() - COALESCE(nc.next_sent_for_sign_at, nc.next_created_at)) > 14
        THEN 'Sales'
        WHEN nc.next_status IN ('signed', 'active')
         AND fp.first_payment_status IN ('pending', 'overdue')
        THEN 'Finance'
        WHEN fp.first_payment_status = 'paid'
         AND fi.first_invoice_number IS NULL
        THEN 'Finance'
        ELSE NULL
    END AS decision_owner

FROM contracts c
JOIN customers cust ON c.customer_id = cust.id
JOIN branches b ON c.branch_id = b.id
LEFT JOIN prev_contracts pc ON pc.contract_id = c.id
LEFT JOIN next_contracts nc ON nc.old_contract_id = c.id
-- ★ 100 修正：移除 COALESCE，只 JOIN 續約合約
LEFT JOIN first_payments fp ON fp.contract_id = nc.next_contract_id
LEFT JOIN first_invoices fi ON fi.contract_id = nc.next_contract_id;

COMMENT ON VIEW v_contract_workspace IS 'Contract Workspace V4 - 移除 COALESCE、補齊欄位、統一發票 SSOT (100)';

GRANT SELECT ON v_contract_workspace TO anon, authenticated;

-- ============================================================================
-- 2. 重建 v_renewal_queue（依賴 v_contract_workspace）
-- ============================================================================

DROP VIEW IF EXISTS v_renewal_queue CASCADE;

CREATE VIEW v_renewal_queue AS
SELECT
    cw.*,
    'renewal'::TEXT AS process_key,
    cw.id AS entity_id,

    -- 改用公司名稱（合約編號 + 公司名稱）
    CONCAT(
        cw.contract_number, ' ',
        COALESCE(NULLIF(cw.company_name, ''), cw.customer_name)
    ) AS title,

    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN TRUE
        WHEN cw.days_until_expiry < 0 AND cw.next_contract_id IS NULL THEN TRUE
        ELSE FALSE
    END AS is_overdue,

    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN cw.days_pending_sign
        WHEN cw.days_until_expiry < 0 THEN ABS(cw.days_until_expiry)
        ELSE 0
    END AS overdue_days,

    cw.end_date AS decision_due_date,
    CONCAT('/contracts/', cw.id, '/workspace') AS workspace_url,

    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'urgent'
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 'high'
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'medium'
        WHEN cw.decision_blocked_by = 'need_create_renewal' THEN
            CASE
                WHEN cw.days_until_expiry <= 0 THEN 'urgent'
                WHEN cw.days_until_expiry <= 14 THEN 'high'
                WHEN cw.days_until_expiry <= 30 THEN 'medium'
                ELSE 'low'
            END
        WHEN cw.decision_blocked_by IS NOT NULL THEN 'medium'
        ELSE NULL
    END AS decision_priority,

    -- action_key 對齊 ActionDispatcher
    CASE
        WHEN cw.decision_blocked_by = 'need_create_renewal' THEN 'CREATE_DRAFT'
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 'SEND_SIGN_REMINDER'
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 'GO_TO_PAYMENTS'
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 'GO_TO_INVOICES'
        ELSE NULL
    END AS decision_action_key

FROM v_contract_workspace cw
WHERE cw.decision_blocked_by IS NOT NULL
  AND cw.decision_blocked_by != 'completed'
  AND cw.status = 'active'
ORDER BY
    CASE
        WHEN cw.decision_blocked_by = 'signing_overdue' THEN 1
        WHEN cw.decision_blocked_by = 'need_create_renewal' AND cw.days_until_expiry <= 0 THEN 2
        WHEN cw.decision_blocked_by = 'payment_pending' THEN 3
        WHEN cw.decision_blocked_by = 'need_create_renewal' AND cw.days_until_expiry <= 14 THEN 4
        WHEN cw.decision_blocked_by = 'invoice_pending' THEN 5
        ELSE 6
    END,
    cw.days_until_expiry ASC NULLS LAST;

COMMENT ON VIEW v_renewal_queue IS '續約待辦清單 (100)';
GRANT SELECT ON v_renewal_queue TO anon, authenticated;

-- ============================================================================
-- 3. 重建 v_renewal_dashboard_stats（依賴 v_renewal_queue）
-- ============================================================================

DROP VIEW IF EXISTS v_renewal_dashboard_stats CASCADE;

CREATE VIEW v_renewal_dashboard_stats AS
SELECT
    COUNT(*) AS total_action_needed,
    COUNT(*) FILTER (WHERE decision_priority = 'urgent') AS urgent_count,
    COUNT(*) FILTER (WHERE decision_priority = 'high') AS high_count,
    COUNT(*) FILTER (WHERE decision_priority = 'medium') AS medium_count,
    COUNT(*) FILTER (WHERE decision_priority = 'low') AS low_count,
    COUNT(*) FILTER (WHERE is_overdue = TRUE) AS overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'need_create_renewal') AS need_create_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'signing_overdue') AS signing_overdue_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'payment_pending') AS payment_pending_count,
    COUNT(*) FILTER (WHERE decision_blocked_by = 'invoice_pending') AS invoice_pending_count
FROM v_renewal_queue;

COMMENT ON VIEW v_renewal_dashboard_stats IS '續約 Dashboard 統計 (100)';
GRANT SELECT ON v_renewal_dashboard_stats TO anon, authenticated;

-- ============================================================================
-- 4. 驗證
-- ============================================================================

DO $$
DECLARE
    workspace_count INT;
    queue_count INT;
    has_original_price BOOLEAN;
    has_deposit_status BOOLEAN;
    has_rental_address BOOLEAN;
    has_next_monthly_rent BOOLEAN;
BEGIN
    SELECT COUNT(*) INTO workspace_count FROM v_contract_workspace;
    SELECT COUNT(*) INTO queue_count FROM v_renewal_queue;

    -- 檢查新欄位是否存在
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_contract_workspace' AND column_name = 'original_price'
    ) INTO has_original_price;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_contract_workspace' AND column_name = 'deposit_status'
    ) INTO has_deposit_status;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_contract_workspace' AND column_name = 'rental_address'
    ) INTO has_rental_address;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_contract_workspace' AND column_name = 'next_monthly_rent'
    ) INTO has_next_monthly_rent;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 100 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '1. v_contract_workspace 重建完成（筆數: %）', workspace_count;
    RAISE NOTICE '';
    RAISE NOTICE '   核心修正：';
    RAISE NOTICE '   - 移除 COALESCE：fp/fi 只 JOIN nc.next_contract_id';
    RAISE NOTICE '   - 發票 SSOT：改用 invoice_number IS NOT NULL';
    RAISE NOTICE '   - is_paid/is_invoiced：無續約時回傳 NULL';
    RAISE NOTICE '';
    RAISE NOTICE '   新增欄位：';
    IF has_original_price THEN
        RAISE NOTICE '   [OK] original_price';
    ELSE
        RAISE NOTICE '   [NG] original_price';
    END IF;
    IF has_deposit_status THEN
        RAISE NOTICE '   [OK] deposit_status';
    ELSE
        RAISE NOTICE '   [NG] deposit_status';
    END IF;
    IF has_rental_address THEN
        RAISE NOTICE '   [OK] rental_address';
    ELSE
        RAISE NOTICE '   [NG] rental_address';
    END IF;
    IF has_next_monthly_rent THEN
        RAISE NOTICE '   [OK] next_monthly_rent, next_payment_cycle';
    ELSE
        RAISE NOTICE '   [NG] next_monthly_rent, next_payment_cycle';
    END IF;
    RAISE NOTICE '';
    RAISE NOTICE '2. v_renewal_queue 重建完成（筆數: %）', queue_count;
    RAISE NOTICE '';
    RAISE NOTICE '3. v_renewal_dashboard_stats 重建完成';
    RAISE NOTICE '   - 移除未使用的 need_send_sign_count, waiting_sign_count';
    RAISE NOTICE '';
END $$;
