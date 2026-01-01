-- ============================================================================
-- Migration 101: v_renewal_reminders 同步 SSOT 語意
--
-- 修正項目：
-- 1. 補欄位：next_monthly_rent, next_payment_cycle（LINE 提醒用）
-- 2. 補欄位：customer_company_tax_id（發票狀態判斷用）
-- 3. 同步 NULL 語意：is_paid/is_invoiced 無續約草稿時為 NULL
--
-- Date: 2026-01-01
-- ============================================================================

-- ============================================================================
-- 1. 重建 v_renewal_reminders
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
        -- ★ 101 新增：LINE 提醒用新合約條款
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
        payment_status,
        paid_at,
        payment_method
    FROM payments
    WHERE payment_type = 'rent'
    ORDER BY contract_id, payment_period ASC
),
first_invoices AS (
    SELECT DISTINCT ON (contract_id)
        contract_id,
        invoice_number,
        invoice_date
    FROM payments
    WHERE payment_type = 'rent'
      AND invoice_number IS NOT NULL
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

    -- 剩餘天數
    ct.end_date - CURRENT_DATE AS days_until_expiry,
    ct.end_date - CURRENT_DATE AS days_remaining,

    -- 客戶資訊
    c.name AS customer_name,
    c.company_name,
    c.phone AS customer_phone,
    c.email AS customer_email,
    c.line_user_id,
    c.status AS customer_status,
    -- ★ 101 新增：發票狀態判斷用
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
    -- ★ 101 新增：LINE 提醒用
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

    -- ========== SSOT 計算欄位 ==========

    -- 收款狀態（原始資料）
    fp.payment_status AS first_payment_status,
    fp.paid_at AS first_payment_paid_at,
    fp.payment_method AS first_payment_method,

    -- 發票狀態（原始資料）
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

    -- ========== 前端用計算欄位（★ 101 同步 NULL 語意） ==========

    -- 意願 flags（布林）
    ct.renewal_notified_at IS NOT NULL AS is_notified,
    ct.renewal_confirmed_at IS NOT NULL AS is_confirmed,

    -- ★ 101 修正：無續約草稿時為 NULL（不適用）
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
    -- ★ 101 修正：無續約草稿時，收款/發票步驟不計入
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

COMMENT ON VIEW v_renewal_reminders IS '續約提醒視圖 - 同步 NULL 語意 + LINE 提醒欄位 (101)';
GRANT SELECT ON v_renewal_reminders TO anon, authenticated;

-- ============================================================================
-- 2. 重建 v_monthly_reminders_summary（依賴 v_renewal_reminders）
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

GRANT SELECT ON v_monthly_reminders_summary TO anon, authenticated;

-- ============================================================================
-- 3. 驗證
-- ============================================================================

DO $$
DECLARE
    reminders_count INT;
    has_next_monthly_rent BOOLEAN;
    has_customer_tax_id BOOLEAN;
BEGIN
    SELECT COUNT(*) INTO reminders_count FROM v_renewal_reminders;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_renewal_reminders' AND column_name = 'next_monthly_rent'
    ) INTO has_next_monthly_rent;

    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'v_renewal_reminders' AND column_name = 'customer_company_tax_id'
    ) INTO has_customer_tax_id;

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration 101 完成 ===';
    RAISE NOTICE '';
    RAISE NOTICE '1. v_renewal_reminders 重建完成（筆數: %）', reminders_count;
    RAISE NOTICE '';
    RAISE NOTICE '   新增欄位：';
    IF has_next_monthly_rent THEN
        RAISE NOTICE '   [OK] next_monthly_rent, next_payment_cycle（LINE 提醒用）';
    ELSE
        RAISE NOTICE '   [NG] next_monthly_rent, next_payment_cycle';
    END IF;
    IF has_customer_tax_id THEN
        RAISE NOTICE '   [OK] customer_company_tax_id（發票狀態判斷用）';
    ELSE
        RAISE NOTICE '   [NG] customer_company_tax_id';
    END IF;
    RAISE NOTICE '';
    RAISE NOTICE '   NULL 語意同步：';
    RAISE NOTICE '   - is_paid：無續約草稿時回傳 NULL';
    RAISE NOTICE '   - is_invoiced：無續約草稿時回傳 NULL';
    RAISE NOTICE '';
    RAISE NOTICE '2. v_monthly_reminders_summary 重建完成';
    RAISE NOTICE '';
END $$;
