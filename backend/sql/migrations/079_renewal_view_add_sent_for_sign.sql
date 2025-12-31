-- 079_renewal_view_add_sent_for_sign.sql
-- 補充 v_renewal_reminders 缺少的 next_sent_for_sign_at 欄位
--
-- 修改項目：
-- 1. 新增 next_sent_for_sign_at（續約草稿的送簽時間）
-- 2. 優化 signing_start_at（優先使用 sent_for_sign_at）
--
-- Date: 2025-12-31

-- ============================================================================
-- 1. 重建 v_renewal_reminders 視圖
-- ============================================================================

DROP VIEW IF EXISTS v_monthly_reminders_summary CASCADE;
DROP VIEW IF EXISTS v_renewal_reminders CASCADE;

CREATE VIEW v_renewal_reminders AS
WITH next_contracts AS (
    -- 找出每張合約的「下一張續約合約」（最新一筆）
    SELECT DISTINCT ON (renewed_from_id)
        renewed_from_id AS old_contract_id,
        id AS next_contract_id,
        status AS next_status,
        signed_at AS next_signed_at,
        created_at AS next_created_at,
        sent_for_sign_at AS next_sent_for_sign_at,  -- ★ 新增
        contract_period AS next_contract_period      -- ★ 新增
    FROM contracts
    WHERE renewed_from_id IS NOT NULL
    ORDER BY renewed_from_id, created_at DESC
),
first_payments AS (
    -- 找出每張續約合約的第一期付款狀態
    SELECT DISTINCT ON (contract_id)
        contract_id,
        payment_status,
        paid_at,
        payment_method                                -- ★ 新增
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
),
first_invoices AS (
    -- 找出每張續約合約的第一張發票
    SELECT DISTINCT ON (contract_id)
        contract_id,
        invoice_number,
        invoice_date,
        carrier_type
    FROM invoices
    ORDER BY contract_id, invoice_date ASC
)
SELECT
    ct.id,
    ct.contract_number,
    ct.contract_period,                              -- ★ 新增
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
    ct.metadata,                                     -- ★ 新增（階梯式收費）

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

    -- ========== Next Contract 資訊（SSOT） ==========

    nc.next_contract_id,
    nc.next_status,
    nc.next_signed_at,
    nc.next_created_at,
    nc.next_sent_for_sign_at,                        -- ★ 新增
    nc.next_contract_period,                         -- ★ 新增

    -- 送簽開始時間（優先使用 sent_for_sign_at，否則用 created_at）
    COALESCE(nc.next_sent_for_sign_at, nc.next_created_at) AS signing_start_at,

    -- 是否有續約草稿（向後相容）
    nc.next_contract_id IS NOT NULL AS has_renewal_draft,

    -- ★ 新增：是否已送出簽署
    nc.next_sent_for_sign_at IS NOT NULL AS is_sent_for_sign,

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
    fp.paid_at AS first_payment_paid_at,             -- ★ 新增
    fp.payment_method AS first_payment_method,       -- ★ 新增

    -- 發票狀態（從 invoice 計算，SSOT）
    fi.invoice_number AS next_invoice_number,        -- ★ 新增
    fi.invoice_date AS next_invoice_date,            -- ★ 新增
    fi.carrier_type AS next_invoice_carrier_type,    -- ★ 新增
    fi.invoice_number IS NOT NULL AS is_next_invoiced, -- ★ 新增

    -- 回簽狀態（從 next_contract 計算，SSOT）
    CASE
        WHEN nc.next_signed_at IS NOT NULL THEN true
        WHEN nc.next_status IN ('active', 'signed') THEN true
        ELSE false
    END AS is_next_signed,

    -- 回簽等待天數（基於 sent_for_sign_at）
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
    END AS days_pending_sign

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

COMMENT ON VIEW v_renewal_reminders IS '續約提醒視圖（V3.1）- 新增 V3 流程欄位：next_sent_for_sign_at, is_next_invoiced';

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
    COUNT(*) FILTER (WHERE renewal_stage = 'handoff') AS handoff_count
FROM v_renewal_reminders
GROUP BY branch_id, branch_name;

GRANT SELECT ON v_monthly_reminders_summary TO anon, authenticated;

-- ============================================================================
-- 3. 驗證
-- ============================================================================

DO $$
DECLARE
    v_view_columns TEXT[];
BEGIN
    SELECT array_agg(column_name::TEXT ORDER BY ordinal_position)
    INTO v_view_columns
    FROM information_schema.columns
    WHERE table_name = 'v_renewal_reminders';

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 079 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '新增欄位：';
    RAISE NOTICE '✅ next_sent_for_sign_at - 續約草稿送簽時間';
    RAISE NOTICE '✅ is_sent_for_sign - 是否已送出簽署';
    RAISE NOTICE '✅ next_contract_period - 續約合約期數';
    RAISE NOTICE '✅ first_payment_paid_at - 首期付款時間';
    RAISE NOTICE '✅ first_payment_method - 首期付款方式';
    RAISE NOTICE '✅ next_invoice_number - 續約發票號碼';
    RAISE NOTICE '✅ is_next_invoiced - 是否已開票';
    RAISE NOTICE '';
    RAISE NOTICE '視圖欄位數量: %', array_length(v_view_columns, 1);
END $$;
